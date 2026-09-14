"""lib/mcp_server.py — MCP (Model Context Protocol) server wrapping lib/api.py.

Implements the MCP protocol (JSON-RPC 2.0 over stdio) so agents can call
the issue tracker and doc operations as native MCP tools instead of going
through HTTP.  Every tool delegates to the same handler functions that
lib/api.py's REST dispatch() uses — no logic is reimplemented here.

Entry point: run(root) — reads JSON-RPC from stdin, writes responses to
stdout.  bin/mcp-serve is the shell wrapper that resolves the project root
and calls this.

Stdlib only — no external dependencies.
"""
from __future__ import annotations

import json
import sys

from api import (
    ApiError,
    add_issue_event,
    connect,
    create_doc,
    create_issue,
    db_path,
    get_doc,
    get_issue,
    list_docs,
    list_issue_events,
    list_issues,
    now,
    update_doc,
    update_issue,
)

# ---------------------------------------------------------------------------
# tool definitions — the schema each tool advertises via tools/list
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "list_issues",
        "description": "List all issues, optionally filtered by status.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "description": "Filter by status (e.g. open, progress, done).",
                },
            },
        },
    },
    {
        "name": "get_issue",
        "description": "Get a single issue by its id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {
                    "type": "string",
                    "description": "The issue id.",
                },
            },
            "required": ["issue_id"],
        },
    },
    {
        "name": "create_issue",
        "description": "Create a new issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Unique issue id."},
                "title": {"type": "string", "description": "Issue title."},
                "description": {"type": "string", "description": "Issue description."},
                "status": {"type": "string", "description": "Initial status (default: notstarted)."},
                "effort": {"type": "string", "description": "T-shirt size: S, M, L (default: S)."},
                "source_doc": {"type": "string", "description": "Source document id."},
                "blocked_by": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Issue ids this issue is blocked by.",
                },
                "held_why": {"type": "string", "description": "Free-text reason the issue is held."},
                "held_at": {"type": "string", "description": "ISO timestamp when held."},
                "gate": {"type": "string", "description": "What this issue is gating on."},
                "gated_at": {"type": "string", "description": "ISO timestamp when gated."},
                "claimed_by": {"type": "string", "description": "Who claimed this issue."},
                "claimed_at": {"type": "string", "description": "When the issue was claimed (ISO timestamp)."},
            },
            "required": ["id", "title", "description"],
        },
    },
    {
        "name": "update_issue",
        "description": "Update fields on an existing issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {"type": "string", "description": "The issue id to update."},
                "title": {"type": "string", "description": "New title."},
                "description": {"type": "string", "description": "New description."},
                "status": {"type": "string", "description": "New status."},
                "effort": {"type": "string", "description": "T-shirt size: S, M, L."},
                "source_doc": {"type": "string", "description": "New source document id."},
                "blocked_by": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "New blocked-by list.",
                },
                "held_why": {"type": "string", "description": "Free-text reason the issue is held."},
                "held_at": {"type": "string", "description": "ISO timestamp when held."},
                "gate": {"type": "string", "description": "What this issue is gating on."},
                "gated_at": {"type": "string", "description": "ISO timestamp when gated."},
                "claimed_by": {"type": "string", "description": "New claimant."},
                "claimed_at": {"type": "string", "description": "New claim timestamp."},
            },
            "required": ["issue_id"],
        },
    },
    {
        "name": "list_issue_events",
        "description": "List all events (notes) for an issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {
                    "type": "string",
                    "description": "The issue id.",
                },
            },
            "required": ["issue_id"],
        },
    },
    {
        "name": "add_issue_event",
        "description": "Add an event (note) to an issue.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {"type": "string", "description": "The issue id."},
                "content": {"type": "string", "description": "Event content text."},
                "type": {"type": "string", "description": "Event type (default: comment)."},
                "author": {"type": "string", "description": "Author of the event."},
            },
            "required": ["issue_id", "content"],
        },
    },
    {
        "name": "list_docs",
        "description": "List all documents with their response counts.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "get_doc",
        "description": "Get a single document by id, including its pages and responses.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "doc_id": {
                    "type": "string",
                    "description": "The document id.",
                },
            },
            "required": ["doc_id"],
        },
    },
    {
        "name": "create_doc",
        "description": "Create a new document (PRD, report, or doc) with its pages and response boxes.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Unique document id (e.g. 'prd-008-my-topic')."},
                "title": {"type": "string", "description": "Document title."},
                "short_name": {"type": "string", "description": "Short display name (e.g. 'PRD-008')."},
                "type": {"type": "string", "description": "Document type: 'prd', 'report', or 'doc'."},
                "status": {"type": "string", "description": "Initial status (default: open)."},
                "foot": {"type": "string", "description": "Footer guidance text."},
                "pages": {
                    "type": "array",
                    "description": "Array of page objects.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "id": {"type": "string", "description": "Page id (e.g. 'p0')."},
                            "position": {"type": "integer", "description": "Page ordering position."},
                            "nav_group": {"type": "string", "description": "Navigation group label."},
                            "nav_title": {"type": "string", "description": "Navigation title."},
                            "heading": {"type": "string", "description": "Page heading."},
                            "subtitle": {"type": "string", "description": "Page subtitle."},
                            "content": {"type": "string", "description": "HTML body of the page."},
                        },
                        "required": ["id", "content"],
                    },
                },
                "responses": {
                    "type": "array",
                    "description": "Array of response box objects.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "page_id": {"type": "string", "description": "Page id this response belongs to."},
                            "resp_key": {"type": "string", "description": "Stable response key."},
                            "label": {"type": "string", "description": "Response label."},
                            "discuss": {"type": "string", "description": "Discussion prompt HTML."},
                        },
                        "required": ["resp_key"],
                    },
                },
            },
            "required": ["id", "title", "type", "pages"],
        },
    },
    {
        "name": "update_doc_status",
        "description": "Update a document's status or other metadata (title, short_name, foot).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "doc_id": {"type": "string", "description": "The document id to update."},
                "status": {"type": "string", "description": "New status."},
                "title": {"type": "string", "description": "New title."},
                "short_name": {"type": "string", "description": "New short name."},
                "foot": {"type": "string", "description": "New footer text."},
            },
            "required": ["doc_id"],
        },
    },
    # --- dispatch / handoff tools ---
    {
        "name": "dispatch_issue",
        "description": (
            "Record that an issue is being dispatched to an agent. "
            "Sets claimed_by/claimed_at and adds a 'dispatch' event with the brief and file scope."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {"type": "string", "description": "The issue id to dispatch."},
                "brief": {"type": "string", "description": "One-line task description for the agent."},
                "files": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "File paths the agent expects to touch (advisory).",
                },
                "agent_id": {"type": "string", "description": "Identifier for the dispatched agent."},
            },
            "required": ["issue_id", "brief"],
        },
    },
    {
        "name": "handoff_issue",
        "description": (
            "Record that dispatched work on an issue is complete. "
            "Adds a 'handoff' event with structured data, updates status, and clears the claim."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue_id": {"type": "string", "description": "The issue id to hand off."},
                "changed": {"type": "string", "description": "What actually landed."},
                "verified": {"type": "string", "description": "How the work was re-checked."},
                "found": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Things seen but not fixed.",
                },
                "assumed": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Assumptions the work rests on.",
                },
                "next": {"type": "string", "description": "What the next agent needs to know."},
                "status": {"type": "string", "description": "New issue status (default: done)."},
            },
            "required": ["issue_id", "changed", "verified"],
        },
    },
    {
        "name": "get_ready_issues",
        "description": (
            "List issues ready for dispatch: status is 'notstarted', not held, "
            "and not blocked by any undone issue."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of issues to return.",
                },
            },
        },
    },
    {
        "name": "get_active_claims",
        "description": "List issues currently claimed by an agent (claimed_by is not null).",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


# ---------------------------------------------------------------------------
# tool dispatch — call the right api.py handler for each tool name
# ---------------------------------------------------------------------------

def _call_tool(root: str, name: str, arguments: dict) -> object:
    """Call an api.py handler and return its result object.

    Raises ApiError on validation / not-found failures (the caller maps
    those to MCP error responses).  Opens and closes its own DB connection
    — same per-call pattern as api.py's dispatch().
    """
    import os
    if not os.path.isfile(db_path(root)):
        raise ApiError(503, "no database — run bin/migrate-db first")

    conn = connect(root)
    try:
        # The api.py handlers all take (conn, args, query, body).
        # args is a tuple of positional URL captures; query is a dict of
        # query-string lists; body is the parsed JSON body.  We map each
        # tool's flat argument dict into those shapes.

        if name == "list_issues":
            query = {}
            if arguments.get("status"):
                query["status"] = [arguments["status"]]
            return list_issues(conn, (), query, None)

        if name == "get_issue":
            return get_issue(conn, (arguments["issue_id"],), {}, None)

        if name == "create_issue":
            body = dict(arguments)
            return create_issue(conn, (), {}, body)

        if name == "update_issue":
            issue_id = arguments["issue_id"]
            body = {k: v for k, v in arguments.items() if k != "issue_id"}
            return update_issue(conn, (issue_id,), {}, body)

        if name == "list_issue_events":
            return list_issue_events(conn, (arguments["issue_id"],), {}, None)

        if name == "add_issue_event":
            issue_id = arguments["issue_id"]
            body = {k: v for k, v in arguments.items() if k != "issue_id"}
            return add_issue_event(conn, (issue_id,), {}, body)

        if name == "list_docs":
            return list_docs(conn, (), {}, None)

        if name == "get_doc":
            return get_doc(conn, (arguments["doc_id"],), {}, None)

        if name == "create_doc":
            body = dict(arguments)
            return create_doc(conn, (), {}, body)

        if name == "update_doc_status":
            doc_id = arguments["doc_id"]
            body = {k: v for k, v in arguments.items() if k != "doc_id"}
            return update_doc(conn, (doc_id,), {}, body)

        if name == "dispatch_issue":
            issue_id = arguments["issue_id"]
            brief = arguments["brief"]
            files = arguments.get("files", [])
            agent_id = arguments.get("agent_id")
            # Claim the issue
            ts = now()
            claim_body = {"status": "progress", "claimed_by": agent_id or "agent", "claimed_at": ts}
            update_issue(conn, (issue_id,), {}, claim_body)
            # Record the dispatch event
            event_content = json.dumps({
                "brief": brief,
                "files": files,
                "agent_id": agent_id,
            })
            add_issue_event(conn, (issue_id,), {}, {
                "content": event_content,
                "type": "dispatch",
                "author": agent_id or "agent",
            })
            return get_issue(conn, (issue_id,), {}, None)

        if name == "handoff_issue":
            issue_id = arguments["issue_id"]
            new_status = arguments.get("status", "done")
            # Build the handoff event content
            handoff_data = {
                "changed": arguments["changed"],
                "verified": arguments["verified"],
            }
            if "found" in arguments:
                handoff_data["found"] = arguments["found"]
            if "assumed" in arguments:
                handoff_data["assumed"] = arguments["assumed"]
            if "next" in arguments:
                handoff_data["next"] = arguments["next"]
            event_content = json.dumps(handoff_data)
            add_issue_event(conn, (issue_id,), {}, {
                "content": event_content,
                "type": "handoff",
            })
            # Update status and clear the claim
            update_issue(conn, (issue_id,), {}, {
                "status": new_status,
                "claimed_by": None,
                "claimed_at": None,
            })
            return get_issue(conn, (issue_id,), {}, None)

        if name == "get_ready_issues":
            limit = arguments.get("limit")
            # Get all issues via the api.py handler, then filter
            all_issues = list_issues(conn, (), {}, None)
            # Collect done ids for blocked_by filtering
            done_ids = {i["id"] for i in all_issues if i.get("status") == "done"}
            ready = []
            for issue in all_issues:
                if issue.get("status") != "notstarted":
                    continue
                if issue.get("held_why"):
                    continue
                blocked_by = issue.get("blocked_by", [])
                if not all(bid in done_ids for bid in blocked_by):
                    continue
                ready.append(issue)
                if limit and len(ready) >= limit:
                    break
            return ready

        if name == "get_active_claims":
            all_issues = list_issues(conn, (), {}, None)
            return [i for i in all_issues
                    if i.get("claimed_by") and i.get("status") != "done"]

        raise ApiError(404, "unknown tool: %s" % name)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# JSON-RPC 2.0 helpers
# ---------------------------------------------------------------------------

def _ok(id, result):
    return {"jsonrpc": "2.0", "id": id, "result": result}


def _error(id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": id, "error": err}


# Standard JSON-RPC error codes
_PARSE_ERROR = -32700
_INVALID_REQUEST = -32600
_METHOD_NOT_FOUND = -32601
_INVALID_PARAMS = -32602
_INTERNAL_ERROR = -32603


# ---------------------------------------------------------------------------
# protocol handlers
# ---------------------------------------------------------------------------

SERVER_INFO = {
    "name": "entropy-machines",
    "version": "0.1.0",
}

SERVER_CAPABILITIES = {
    "tools": {},
}


def _handle_request(root: str, msg: dict) -> dict | None:
    """Process one JSON-RPC message.  Returns a response dict, or None for
    notifications (messages with no 'id')."""
    msg_id = msg.get("id")
    method = msg.get("method", "")
    params = msg.get("params", {})

    # notifications (no id) — the only one we care about is 'initialized'
    if msg_id is None:
        return None

    if method == "initialize":
        return _ok(msg_id, {
            "protocolVersion": "2024-11-05",
            "serverInfo": SERVER_INFO,
            "capabilities": SERVER_CAPABILITIES,
        })

    if method == "tools/list":
        return _ok(msg_id, {"tools": TOOLS})

    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        try:
            result = _call_tool(root, tool_name, arguments)
            return _ok(msg_id, {
                "content": [
                    {"type": "text", "text": json.dumps(result, indent=2)},
                ],
            })
        except ApiError as exc:
            return _ok(msg_id, {
                "content": [
                    {"type": "text", "text": json.dumps({"error": exc.message})},
                ],
                "isError": True,
            })
        except Exception as exc:
            return _ok(msg_id, {
                "content": [
                    {"type": "text", "text": json.dumps({"error": str(exc)})},
                ],
                "isError": True,
            })

    if method == "ping":
        return _ok(msg_id, {})

    return _error(msg_id, _METHOD_NOT_FOUND, "method not found: %s" % method)


# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------

def run(root: str) -> None:
    """Read JSON-RPC messages from stdin, write responses to stdout.

    Each line of stdin is one complete JSON-RPC message.  Responses are
    written as one JSON object per line.  The loop exits when stdin is
    closed (EOF).
    """
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            resp = _error(None, _PARSE_ERROR, "parse error: %s" % exc)
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
            continue

        if not isinstance(msg, dict):
            resp = _error(None, _INVALID_REQUEST, "request must be a JSON object")
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
            continue

        resp = _handle_request(root, msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
