"""lib/api.py — /api/* REST endpoints backing the React SPA (ui/).

Reads and writes .entropy-machines/entropy-machines.db per lib/schema.sql.
See entropy-machines-docs/PRD-006-react-migration.html page p4 ("Agent
API") for the endpoint table this implements:

    GET  /api/docs
    GET  /api/docs/:id
    GET  /api/docs/:id/responses
    GET  /api/docs/:id/responses/:key
    PUT  /api/docs/:id/responses/:key
    POST /api/docs/:id/responses/:key/reply
    GET  /api/issues
    POST /api/issues
    GET  /api/issues/:id
    PATCH /api/issues/:id
    GET  /api/issues/:id/events
    POST /api/issues/:id/events
    GET  /api/settings/:key
    PUT  /api/settings/:key

(/api/events, the phase-2 SSE stream on the same PRD page, is out of scope
here — nothing below serves it.)

Wired into bin/serve: dispatch() is the single entry point. bin/serve's
HTTP handler calls it for any path starting with "/api/" and sends back
whatever (status, obj) it returns as JSON — this module knows nothing
about HTTP, sockets or headers, only about the DB and the URL shape.

DB CONNECTION PER CALL. This is a low-traffic local dev server (see
bin/serve's own docstring) — a connection pool would be solving a load
problem this process does not have. Opening/closing per call also means a
request on one ThreadingHTTPServer thread can never leave a transaction
open that blocks a request on another.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import datetime, timezone
from urllib.parse import unquote

DB_RELATIVE_PATH = os.path.join(".entropy-machines", "entropy-machines.db")


def db_path(root: str) -> str:
    return os.path.join(root, DB_RELATIVE_PATH)


def connect(root: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path(root))
    conn.execute("PRAGMA foreign_keys = ON")
    conn.row_factory = sqlite3.Row
    return conn


def now() -> str:
    """Same shape as lib/notes.py's timestamps: UTC, second precision, Z
    suffix — one clock format across the harness, not a second one here."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def row_to_dict(row: sqlite3.Row) -> dict:
    return {k: row[k] for k in row.keys()}


class ApiError(Exception):
    """Raised by a handler below to short-circuit dispatch() with a specific
    HTTP status — the alternative is every handler returning (status, obj)
    itself and every caller re-checking which shape it got back."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------------------------------------------------------------------------
# docs
# ---------------------------------------------------------------------------

def _doc_counts(conn, doc_id):
    row = conn.execute(
        "SELECT COUNT(*) AS total, "
        "SUM(CASE WHEN TRIM(COALESCE(value,'')) != '' THEN 1 ELSE 0 END) AS answered "
        "FROM responses WHERE doc_id = ?",
        (doc_id,),
    ).fetchone()
    return {"total": row["total"] or 0, "answered": row["answered"] or 0}


def _require_doc(conn, doc_id):
    if conn.execute("SELECT 1 FROM docs WHERE id = ?", (doc_id,)).fetchone() is None:
        raise ApiError(404, "no such doc: %r" % doc_id)


def list_docs(conn, args, query, body):
    docs = [row_to_dict(r) for r in conn.execute("SELECT * FROM docs ORDER BY id")]
    for d in docs:
        d["counts"] = _doc_counts(conn, d["id"])
    return docs


def get_doc(conn, args, query, body):
    (doc_id,) = args
    row = conn.execute("SELECT * FROM docs WHERE id = ?", (doc_id,)).fetchone()
    if row is None:
        raise ApiError(404, "no such doc: %r" % doc_id)
    doc = row_to_dict(row)
    doc["counts"] = _doc_counts(conn, doc_id)
    pages = [row_to_dict(r) for r in conn.execute(
        "SELECT * FROM pages WHERE doc_id = ? ORDER BY position", (doc_id,))]
    return {"doc": doc, "pages": pages, "responses": _responses_for_doc(conn, doc_id)}


def _replies_for_response(conn, response_id):
    return [row_to_dict(r) for r in conn.execute(
        "SELECT * FROM replies WHERE response_id = ? ORDER BY id", (response_id,))]


def _responses_for_doc(conn, doc_id):
    out = []
    for r in conn.execute("SELECT * FROM responses WHERE doc_id = ? ORDER BY id", (doc_id,)):
        resp = row_to_dict(r)
        resp["replies"] = _replies_for_response(conn, resp["id"])
        out.append(resp)
    return out


def list_responses(conn, args, query, body):
    (doc_id,) = args
    _require_doc(conn, doc_id)
    return _responses_for_doc(conn, doc_id)


def _get_response_row(conn, doc_id, key):
    row = conn.execute(
        "SELECT * FROM responses WHERE doc_id = ? AND resp_key = ?", (doc_id, key)
    ).fetchone()
    if row is None:
        raise ApiError(404, "no such response: %s/%s" % (doc_id, key))
    return row


def get_response(conn, args, query, body):
    doc_id, key = args
    row = _get_response_row(conn, doc_id, key)
    resp = row_to_dict(row)
    resp["replies"] = _replies_for_response(conn, resp["id"])
    return resp


def update_response(conn, args, query, body):
    doc_id, key = args
    if not isinstance(body, dict) or "value" not in body:
        raise ApiError(400, 'expected a JSON body: {"value": "..."}')
    value = body["value"]
    if not isinstance(value, str):
        raise ApiError(400, '"value" must be a string')
    row = _get_response_row(conn, doc_id, key)
    conn.execute(
        "UPDATE responses SET value = ?, updated_at = ? WHERE id = ?",
        (value, now(), row["id"]),
    )
    conn.commit()
    return get_response(conn, (doc_id, key), query, body)


def add_reply(conn, args, query, body):
    doc_id, key = args
    if not isinstance(body, dict) or not isinstance(body.get("content"), str) or not body["content"].strip():
        raise ApiError(400, 'expected a JSON body: {"content": "...", "author": "agent"|"owner"}')
    author = body.get("author", "agent")
    if not isinstance(author, str) or not author:
        raise ApiError(400, '"author" must be a non-empty string')
    row = _get_response_row(conn, doc_id, key)
    cur = conn.execute(
        "INSERT INTO replies (response_id, author, content, created_at) VALUES (?, ?, ?, ?)",
        (row["id"], author, body["content"], now()),
    )
    conn.commit()
    return row_to_dict(conn.execute("SELECT * FROM replies WHERE id = ?", (cur.lastrowid,)).fetchone())


# ---------------------------------------------------------------------------
# issues
# ---------------------------------------------------------------------------

def _issue_out(row):
    d = row_to_dict(row)
    try:
        d["blocked_by"] = json.loads(d["blocked_by"]) if d["blocked_by"] else []
    except (TypeError, ValueError):
        d["blocked_by"] = []
    return d


_ISSUES_SELECT = (
    "SELECT issues.*, docs.type AS source_doc_type, docs.short_name AS source_doc_name "
    "FROM issues LEFT JOIN docs ON issues.source_doc = docs.id"
)


def list_issues(conn, args, query, body):
    status = (query.get("status") or [None])[0]
    if status:
        rows = conn.execute(_ISSUES_SELECT + " WHERE issues.status = ? ORDER BY issues.id", (status,))
    else:
        rows = conn.execute(_ISSUES_SELECT + " ORDER BY issues.id")
    return [_issue_out(r) for r in rows]


def get_issue(conn, args, query, body):
    (issue_id,) = args
    row = conn.execute(_ISSUES_SELECT + " WHERE issues.id = ?", (issue_id,)).fetchone()
    if row is None:
        raise ApiError(404, "no such issue: %r" % issue_id)
    return _issue_out(row)


def create_issue(conn, args, query, body):
    if not isinstance(body, dict) or not body.get("id") or not body.get("title"):
        raise ApiError(400, 'expected a JSON body: {"id": "...", "title": "...", "description": "..."}')
    description = body.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ApiError(400, '"description" is required when creating an issue and must be a non-empty string')
    issue_id = body["id"]
    if conn.execute("SELECT 1 FROM issues WHERE id = ?", (issue_id,)).fetchone():
        raise ApiError(409, "issue already exists: %r" % issue_id)
    blocked_by = body.get("blocked_by", body.get("blockedBy", []))
    if not isinstance(blocked_by, list):
        raise ApiError(400, '"blocked_by" must be an array of issue ids')
    ts = now()
    conn.execute(
        "INSERT INTO issues (id, title, description, status, source_doc, blocked_by, claimed_by, claimed_at, "
        "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            issue_id,
            body["title"],
            body.get("description"),
            body.get("status", "open"),
            body.get("source_doc"),
            json.dumps(blocked_by),
            body.get("claimed_by"),
            body.get("claimed_at"),
            ts,
            ts,
        ),
    )
    conn.commit()
    return get_issue(conn, (issue_id,), query, body)


def update_issue(conn, args, query, body):
    (issue_id,) = args
    if not isinstance(body, dict):
        raise ApiError(400, "expected a JSON object body")
    get_issue(conn, (issue_id,), query, body)  # 404s if missing
    fields, values = [], []
    for key in ("title", "description", "status", "source_doc", "claimed_by", "claimed_at"):
        if key in body:
            fields.append(key)
            values.append(body[key])
    if "blocked_by" in body or "blockedBy" in body:
        blocked_by = body.get("blocked_by", body.get("blockedBy"))
        if not isinstance(blocked_by, list):
            raise ApiError(400, '"blocked_by" must be an array of issue ids')
        fields.append("blocked_by")
        values.append(json.dumps(blocked_by))
    if not fields:
        raise ApiError(400, "no recognized fields in body — one of title, description, status, source_doc, "
                             "blocked_by, claimed_by, claimed_at")
    fields.append("updated_at")
    values.append(now())
    values.append(issue_id)
    conn.execute(
        "UPDATE issues SET %s WHERE id = ?" % ", ".join("%s = ?" % f for f in fields),
        values,
    )
    conn.commit()
    return get_issue(conn, (issue_id,), query, body)


def list_issue_events(conn, args, query, body):
    (issue_id,) = args
    get_issue(conn, (issue_id,), query, body)
    rows = conn.execute("SELECT * FROM issue_events WHERE issue_id = ? ORDER BY id", (issue_id,))
    return [row_to_dict(r) for r in rows]


def add_issue_event(conn, args, query, body):
    (issue_id,) = args
    get_issue(conn, (issue_id,), query, body)
    if not isinstance(body, dict) or not isinstance(body.get("content"), str) or not body["content"].strip():
        raise ApiError(400, 'expected a JSON body: {"content": "..."}')
    cur = conn.execute(
        "INSERT INTO issue_events (issue_id, type, author, content, created_at) VALUES (?, ?, ?, ?, ?)",
        (issue_id, body.get("type", "comment"), body.get("author"), body["content"], now()),
    )
    conn.commit()
    return row_to_dict(conn.execute("SELECT * FROM issue_events WHERE id = ?", (cur.lastrowid,)).fetchone())


# ---------------------------------------------------------------------------
# settings
# ---------------------------------------------------------------------------

def get_setting(conn, args, query, body):
    (key,) = args
    row = conn.execute("SELECT * FROM settings WHERE key = ?", (key,)).fetchone()
    if row is None:
        raise ApiError(404, "no such setting: %r" % key)
    return row_to_dict(row)


def put_setting(conn, args, query, body):
    (key,) = args
    if not isinstance(body, dict) or "value" not in body:
        raise ApiError(400, 'expected a JSON body: {"value": "..."}')
    value = body["value"]
    if value is not None and not isinstance(value, str):
        raise ApiError(400, '"value" must be a string or null')
    conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))
    conn.commit()
    return {"key": key, "value": value}


# ---------------------------------------------------------------------------
# routing
# ---------------------------------------------------------------------------
# (method, path-regex, handler) — handler(conn, args, query, body), args is
# the tuple of unquoted path captures. Order does not matter for correctness
# (paths are disjoint enough not to collide) but follows the PRD table.
ROUTES = [
    ("GET", re.compile(r"^/api/docs$"), list_docs),
    ("GET", re.compile(r"^/api/docs/([^/]+)$"), get_doc),
    ("GET", re.compile(r"^/api/docs/([^/]+)/responses$"), list_responses),
    ("GET", re.compile(r"^/api/docs/([^/]+)/responses/([^/]+)$"), get_response),
    ("PUT", re.compile(r"^/api/docs/([^/]+)/responses/([^/]+)$"), update_response),
    ("POST", re.compile(r"^/api/docs/([^/]+)/responses/([^/]+)/reply$"), add_reply),
    ("GET", re.compile(r"^/api/issues$"), list_issues),
    ("POST", re.compile(r"^/api/issues$"), create_issue),
    ("GET", re.compile(r"^/api/issues/([^/]+)$"), get_issue),
    ("PATCH", re.compile(r"^/api/issues/([^/]+)$"), update_issue),
    ("GET", re.compile(r"^/api/issues/([^/]+)/events$"), list_issue_events),
    ("POST", re.compile(r"^/api/issues/([^/]+)/events$"), add_issue_event),
    ("GET", re.compile(r"^/api/settings/([^/]+)$"), get_setting),
    ("PUT", re.compile(r"^/api/settings/([^/]+)$"), put_setting),
]


def dispatch(root: str, method: str, path: str, query: dict, body):
    """Route one /api/* request. Returns (status, obj) — obj is JSON-able.

    Caller (bin/serve) is expected to have already checked path.startswith
    ("/api/") before calling this; that check is what decides "is this
    request ours at all", so it stays in the HTTP layer, not here.
    """
    matched_path = False
    for m_method, rx, fn in ROUTES:
        mo = rx.match(path)
        if not mo:
            continue
        matched_path = True
        if m_method != method:
            continue
        db_file = db_path(root)
        if not os.path.isfile(db_file):
            return 503, {"error": "no database at %s — run bin/migrate-db first" % db_file}
        args = tuple(unquote(g) for g in mo.groups())
        conn = connect(root)
        try:
            result = fn(conn, args, query, body)
            return (201 if method == "POST" else 200), result
        except ApiError as exc:
            return exc.status, {"error": exc.message}
        except sqlite3.IntegrityError as exc:
            return 400, {"error": "constraint violation: %s" % exc}
        except sqlite3.Error as exc:
            return 500, {"error": "database error: %s" % exc}
        finally:
            conn.close()
    if matched_path:
        return 405, {"error": "method not allowed"}
    return 404, {"error": "no such endpoint: %s %s" % (method, path)}
