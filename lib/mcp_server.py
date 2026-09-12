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
    create_issue,
    db_path,
    get_doc,
    get_issue,
    list_docs,
    list_issue_events,
    list_issues,
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
                "status": {"type": "string", "description": "Initial status (default: open)."},
                "source_doc": {"type": "string", "description": "Source document id."},
                "blocked_by": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Issue ids this issue is blocked by.",
                },
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
                "source_doc": {"type": "string", "description": "New source document id."},
                "blocked_by": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "New blocked-by list.",
                },
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
