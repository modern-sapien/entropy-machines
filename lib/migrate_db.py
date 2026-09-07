#!/usr/bin/env python3
"""migrate_db.py — one-time migration into the SQLite schema (lib/schema.sql)
that backs the React rewrite (see entropy-machines-docs/PRD-006-react-migration.html,
page p3, "Database design").

Reads three pre-React sources and writes one file:

  entropy-machines-docs/manifest.json    doc registry (status, version, timestamps)
  entropy-machines-docs/<file>.html      the dialogue docs manifest.json points at
  .entropy-machines/issues.json          {"issues": {...}, "notes": [...]}
  ->  .entropy-machines/entropy-machines.db

manifest.json is the list of docs to migrate — not every HTML file under
entropy-machines-docs/ is a dialogue doc; TRACKER.html, INDEX.html, DOCS.html,
PRDS.html, REPORTS.html and CONFERENCE-LIST.html are GENERATED views
(doctracker.py / docstate.write_index), not source docs, and are correctly
left out because manifest.json never lists them. A doc file manifest.json
points at that is missing on disk is skipped, not fatal, and named in the
report.

PARSING CONTRACT (see the comment header any dialogue doc carries): a
`<section class="page" id="pN">` per page, `<nav>` anchors carrying the same
id in `data-page`, `.response[data-resp]` boxes with a label/discuss/textarea,
`<aside class="review" data-review="KEY">` for an agent's reply, and a
`<script type="application/json" id="responses-data">` mirror of saved
answers. All of this is read with regexes, matching this codebase's own
convention (see lib/reply.py, lib/docstate.py) rather than adding an HTML
parsing dependency this harness otherwise has none of.

MANUAL EXPORT FALLBACK. Not every doc uses the multi-page template —
SPRINT-REPORT-PRD-002.html is one long single page with no
`<section class="page">` wrapper at all. When a doc has zero such sections,
parse_dialogue_doc() does NOT drop it: it takes the doc's `<main>` (or
`<body>` if there is no `<main>`) as ONE synthetic page ("p0"), and the same
response/reply regexes still run over that content, so nothing in it is
lost — just not split across logical pages the way the multi-page docs are.
This is the "manual export" the brief asks for: automated structure-finding
degrades to "keep the whole doc as one page" rather than raising, and every
doc this ran against (see VERIFICATION below) hit one of these two paths,
never neither.

VERIFICATION. --verify (default on) re-reads the three source files AGAIN,
independently of the counters the insert loop kept, and compares row counts:
  issues            len(issues.json["issues"])
  issue_notes       len(issues.json["notes"])   (migration-extra rows, for
                                                  issue fields the p3 schema
                                                  has no column for, are
                                                  reported separately)
  docs              manifest.json entries whose file exists on disk
  pages             count of <section class="page"> per doc, or 1 for a
                     fallback (single-page) doc
  responses         count of data-resp="..." response boxes per doc
A mismatch is reported, not silently swallowed; the script's exit code
reflects it (see main()).
"""
from __future__ import annotations

import argparse
import html as html_mod
import json
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import docstate  # noqa: E402  (path must be set up first)
import notes as notes_mod  # noqa: E402


# --------------------------------------------------------------------------
# regexes — one place, matching the contract every dialogue doc documents in
# its own header comment.
# --------------------------------------------------------------------------

_TAG_RX = re.compile(r"<[^>]+>")

SECTION_OPEN_RX = re.compile(
    r'<section(?=[^>]*\bclass="[^"]*\bpage\b[^"]*")(?=[^>]*\bid="(p[\w-]*)")[^>]*>'
)
MAIN_RX = re.compile(r"<main[^>]*>(.*?)</main>", re.S)
BODY_RX = re.compile(r"<body[^>]*>(.*?)</body>", re.S)
TITLE_TAG_RX = re.compile(r"<title>(.*?)</title>", re.S)
H1_RX = re.compile(r"<h1[^>]*>(.*?)</h1>", re.S)
SUB_RX = re.compile(r'<p class="sub">(.*?)</p>', re.S)

NAV_BLOCK_RX = re.compile(r"<nav[^>]*>(.*?)</nav>", re.S)
NAV_ITEM_RX = re.compile(
    r'<div class="grp">(?P<grp>.*?)</div>'
    r'|<a[^>]*\bdata-page="(?P<pid>[^"]+)"[^>]*>(?P<title>.*?)</a>',
    re.S,
)
NAV_FOOT_RX = re.compile(r'<div class="foot">(.*?)</div>', re.S)
NAV_NUM_PREFIX_RX = re.compile(r"^\s*\d+\s*·\s*")

RDATA_RX = re.compile(
    r'<script type="application/json" id="responses-data">(.*?)</script>', re.S
)

# Class matched loosely (not an exact "response") because per-row boxes are
# `class="response mini"` and carry no label/discuss — see lib/reply.py's
# own rx_resp for the same convention. label/discuss are therefore optional.
RESP_RX = re.compile(
    r'<div class="response[^"]*" data-resp="([^"]+)">'
    r"(?:\s*<label>(.*?)</label>)?"
    r'(?:\s*<div class="discuss">(.*?)</div>)?'
    r"\s*<textarea[^>]*>(.*?)</textarea>\s*</div>",
    re.S,
)

ASIDE_OPEN_RX = re.compile(r'<aside class="review" data-review="([^"]+)">')
_ASIDE_TAG_RX = re.compile(r"<aside\b[^>]*>|</aside>")
_RESP_DIV_RX = re.compile(
    r'<div class="response[^"]*" data-resp="[^"]+">.*?</textarea>\s*</div>', re.S
)
_WHO_RX = re.compile(r'^\s*<span class="who">(.*?)</span>\s*', re.S)


def _clean_text(s):
    return html_mod.unescape(_TAG_RX.sub("", s or "")).strip()


def _balanced_asides(text):
    """Top-level <aside class="review" data-review=KEY>...</aside> spans in
    `text`: (open_start, close_end, key, inner_html).

    Reply threads NEST — a follow-up's own reply lands inside its parent's
    aside (see lib/reply.py's block()/prior_boxes() docstrings for why). A
    plain non-greedy `.*?</aside>` truncates the parent at the CHILD's
    closing tag; this instead walks every <aside>/</aside> boundary in order
    and tracks nesting depth, so the parent's true close is the one where
    depth returns to zero.
    """
    spans = []
    pos = 0
    while True:
        m = ASIDE_OPEN_RX.search(text, pos)
        if not m:
            break
        depth = 1
        close_start = close_end = None
        for tm in _ASIDE_TAG_RX.finditer(text, m.end()):
            if tm.group(0) == "</aside>":
                depth -= 1
                if depth == 0:
                    close_start, close_end = tm.start(), tm.end()
                    break
            else:
                depth += 1
        if close_start is None:  # unbalanced markup — take the rest, don't raise
            close_start = close_end = len(text)
        spans.append((m.start(), close_end, m.group(1), text[m.end() : close_start]))
        pos = close_end
    return spans


def extract_replies(text):
    """Every reply (data-review key, author, own content) at any nesting
    depth, parent before child, document order. `content` has any nested
    follow-up reply/response blocks stripped out — those become their own
    rows (a `responses` row for the follow-up box, a `replies` row via the
    recursive call below), not a substring of the parent's content."""
    out = []
    for _start, _end, key, inner in _balanced_asides(text):
        who_m = _WHO_RX.match(inner)
        author_text = who_m.group(1) if who_m else ""
        author = "agent" if "agent" in author_text.lower() else "owner"
        body = inner[who_m.end() :] if who_m else inner
        own = body
        for s2, e2, _k2, _i2 in reversed(_balanced_asides(body)):
            own = own[:s2] + own[e2:]
        own = _RESP_DIV_RX.sub("", own).strip()
        out.append((key, author, own))
        out.extend(extract_replies(inner))
    return out


def extract_responses(text):
    out = []
    for m in RESP_RX.finditer(text):
        key, label, discuss, answer = m.groups()
        out.append(
            {
                "start": m.start(),
                "key": key,
                "label": _clean_text(label) if label else None,
                "discuss": discuss,  # kept as raw HTML — schema comment: "the discussion prompt HTML"
                "textarea": html_mod.unescape(answer).strip() if answer else "",
            }
        )
    return out


def extract_pages(src):
    """[{id, position, start, end, content}], sequential sibling
    <section class="page" id="pN"> blocks in document order. Sections are
    siblings, never nested, so each one's own </section> — the first literal
    </section> after its content starts — is its true close."""
    pages = []
    pos = 0
    position = 0
    while True:
        m = SECTION_OPEN_RX.search(src, pos)
        if not m:
            break
        content_start = m.end()
        close_m = re.search(r"</section>", src[content_start:])
        if close_m:
            content_end = content_start + close_m.start()
            next_pos = content_start + close_m.end()
        else:
            content_end = len(src)
            next_pos = len(src)
        pages.append(
            {
                "id": m.group(1),
                "position": position,
                "start": m.start(),
                "end": content_end,
                "content": src[content_start:content_end],
            }
        )
        position += 1
        pos = next_pos
    return pages


def extract_nav(src):
    """({page_id: (nav_group, nav_title)}, foot_text). Only anchors carrying
    `data-page` count as page links — the cross-doc `Categories` group added
    for sidebar navigation links to TRACKER.html/PRDS.html/etc, not to a
    `data-page` id, and is skipped by construction."""
    m = NAV_BLOCK_RX.search(src)
    if not m:
        return {}, None
    block = m.group(1)
    groups_by_pid = {}
    cur_group = None
    for im in NAV_ITEM_RX.finditer(block):
        if im.group("grp") is not None:
            cur_group = _clean_text(im.group("grp"))
        elif im.group("pid") is not None:
            title = NAV_NUM_PREFIX_RX.sub("", _clean_text(im.group("title")))
            groups_by_pid[im.group("pid")] = (cur_group, title)
    foot_m = NAV_FOOT_RX.search(block)
    foot = _clean_text(foot_m.group(1)) if foot_m else None
    return groups_by_pid, foot


def extract_responses_data(src):
    m = RDATA_RX.search(src)
    if not m:
        return {}
    try:
        data = json.loads(m.group(1))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def parse_dialogue_doc(doc_id, src, manifest_title):
    """One doc's HTML -> {title, foot, pages, responses, replies, fallback,
    warnings}. Never raises on a doc's OWN structure — a doc with no
    <section class="page"> blocks falls back to a single synthetic page
    rather than being skipped (see module docstring, MANUAL EXPORT FALLBACK).
    """
    warnings = []
    pages_raw = extract_pages(src)
    fallback = False
    if not pages_raw:
        fallback = True
        warnings.append(
            f'{doc_id}: no <section class="page"> blocks found — '
            "manual-export fallback: whole doc kept as one synthetic page"
        )
        m = MAIN_RX.search(src) or BODY_RX.search(src)
        if m:
            body, body_start = m.group(1), m.start(1)
        else:
            body, body_start = src, 0
        pages_raw = [
            {
                "id": "p0",
                "position": 0,
                "start": body_start,
                "end": body_start + len(body),
                "content": body,
            }
        ]

    nav_map, foot = extract_nav(src)
    pages = []
    for p in pages_raw:
        grp, nav_title = nav_map.get(p["id"], (None, None))
        heading = _clean_text(H1_RX.search(p["content"]).group(1)) if H1_RX.search(p["content"]) else None
        sub_m = SUB_RX.search(p["content"])
        pages.append(
            {
                "id": p["id"],
                "position": p["position"],
                "start": p["start"],
                "end": p["end"],
                "nav_group": grp,
                "nav_title": nav_title or heading or p["id"],
                "heading": heading or nav_title or p["id"],
                "subtitle": _clean_text(sub_m.group(1)) if sub_m else None,
                "content": p["content"],
            }
        )

    title = (pages[0]["heading"] if pages else None) or manifest_title
    if not title:
        tm = TITLE_TAG_RX.search(src)
        title = _clean_text(tm.group(1)) if tm else doc_id

    responses_data = extract_responses_data(src)
    responses = []
    for rm in extract_responses(src):
        page_id = None
        for p in pages:
            if p["start"] <= rm["start"] < p["end"]:
                page_id = p["id"]
                break
        from_textarea = rm["key"] not in responses_data
        value = rm["textarea"] if from_textarea else responses_data[rm["key"]]
        responses.append(
            {
                "page_id": page_id,
                "resp_key": rm["key"],
                "label": rm["label"],
                "discuss": rm["discuss"],
                "value": value,
                "from_textarea_fallback": from_textarea,
            }
        )

    replies = extract_replies(src)

    return {
        "title": title,
        "foot": foot,
        "pages": pages,
        "responses": responses,
        "replies": replies,
        "fallback": fallback,
        "warnings": warnings,
    }


# --------------------------------------------------------------------------
# migration
# --------------------------------------------------------------------------

DOC_ID_TYPE_RX = re.compile(r"^(PRD-\d+)")

# issue fields lib/tracker-file recognizes (docs/TRACKER-ADAPTER.md's file
# backend) that the p3 issues table has no column for. Nothing here is
# dropped — each issue carrying any of them gets one `issue_notes` row typed
# "migration-extra" holding the leftover fields as JSON, so the migration
# never silently loses data the schema simply wasn't shaped to carry.
ISSUE_EXTRA_FIELDS = ("effort", "gate", "gatedAt", "heldWhy", "heldAt")

NOTE_TYPE_MAP = {
    "DISPATCH": "dispatch",
    "HANDOFF": "handoff",
    "INTERROGATION": "interrogation",
    "NOTE": "comment",
}


def build_schema(conn, schema_path):
    with open(schema_path, encoding="utf-8") as f:
        conn.executescript(f.read())


def doc_id_for(manifest_key, entry):
    file_name = entry.get("file", "")
    return os.path.splitext(file_name)[0] if file_name else manifest_key


def doc_type_for(doc_id):
    up = doc_id.upper()
    if up.startswith("SPRINT-REPORT"):
        return "report"
    if up.startswith("PRD"):
        return "prd"
    return "doc"


def migrate(root, docs_dir, tracker_path, out_path, schema_path, force):
    if os.path.exists(out_path):
        if not force:
            sys.exit(f"migrate_db: refusing to overwrite existing {out_path} (pass --force)")
        os.remove(out_path)

    docstate.init(docs_dir)
    manifest = docstate.load()
    manifest_docs = manifest.get("docs", {})

    tracker_raw = ""
    if os.path.isfile(tracker_path):
        with open(tracker_path, encoding="utf-8") as f:
            tracker_raw = f.read()
    try:
        tracker_doc = json.loads(tracker_raw) if tracker_raw else {}
    except json.JSONDecodeError as e:
        sys.exit(f"migrate_db: {tracker_path} is not valid JSON: {e}")
    issues_src = tracker_doc.get("issues", {}) if isinstance(tracker_doc, dict) else {}
    notes_src = notes_mod.load_records(tracker_raw)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    conn = sqlite3.connect(out_path)
    conn.execute("PRAGMA foreign_keys = ON")
    build_schema(conn, schema_path)

    report = {
        "docs_migrated": 0,
        "docs_skipped": [],
        "fallback_docs": [],
        "pages_inserted": 0,
        "responses_inserted": 0,
        "responses_value_from_textarea": 0,
        "replies_inserted": 0,
        "issues_inserted": 0,
        "issue_notes_from_log": 0,
        "issue_notes_extra": 0,
        "settings_inserted": 0,
        "warnings": [],
    }

    manifest_key_to_doc_id = {}
    doc_ids_inserted = set()

    for mkey, entry in manifest_docs.items():
        doc_id = doc_id_for(mkey, entry)
        manifest_key_to_doc_id[mkey] = doc_id
        file_name = entry.get("file", "")
        doc_path = os.path.join(docs_dir, file_name) if file_name else None
        if not doc_path or not os.path.isfile(doc_path):
            report["docs_skipped"].append(mkey)
            report["warnings"].append(
                f"{mkey}: file {file_name!r} not found under {docs_dir} — doc skipped, not migrated"
            )
            continue

        with open(doc_path, encoding="utf-8") as f:
            src = f.read()
        parsed = parse_dialogue_doc(doc_id, src, entry.get("title"))
        report["warnings"].extend(parsed["warnings"])
        if parsed["fallback"]:
            report["fallback_docs"].append(doc_id)

        tm = DOC_ID_TYPE_RX.match(doc_id)
        short_name = tm.group(1) if tm else doc_id

        conn.execute(
            "INSERT INTO docs (id, title, short_name, type, status, foot, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                doc_id,
                parsed["title"],
                short_name,
                doc_type_for(doc_id),
                entry.get("status", "open"),
                parsed["foot"],
                None,  # no created_at in any source — see HANDOFF assumed:
                entry.get("updatedAt"),
            ),
        )
        doc_ids_inserted.add(doc_id)
        report["docs_migrated"] += 1

        for pg in parsed["pages"]:
            conn.execute(
                "INSERT INTO pages (id, doc_id, position, nav_group, nav_title, heading, subtitle, content) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    pg["id"],
                    doc_id,
                    pg["position"],
                    pg["nav_group"],
                    pg["nav_title"],
                    pg["heading"],
                    pg["subtitle"],
                    pg["content"],
                ),
            )
            report["pages_inserted"] += 1

        resp_id_by_key = {}
        for r in parsed["responses"]:
            cur = conn.execute(
                "INSERT INTO responses (doc_id, page_id, resp_key, label, discuss, value, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (doc_id, r["page_id"], r["resp_key"], r["label"], r["discuss"], r["value"], None),
            )
            resp_id_by_key[r["resp_key"]] = cur.lastrowid
            report["responses_inserted"] += 1
            if r["from_textarea_fallback"]:
                report["responses_value_from_textarea"] += 1

        for key, author, content in parsed["replies"]:
            rid = resp_id_by_key.get(key)
            if rid is None:
                report["warnings"].append(
                    f"{doc_id}: reply data-review={key!r} has no matching response box — replies.response_id left NULL"
                )
            conn.execute(
                "INSERT INTO replies (response_id, author, content, created_at) VALUES (?, ?, ?, ?)",
                (rid, author, content, None),
            )
            report["replies_inserted"] += 1

        settings_pairs = [(f"doc:{doc_id}:version", str(entry.get("version", 0)))]
        if entry.get("updatedAt"):
            settings_pairs.append((f"doc:{doc_id}:updatedAt", entry["updatedAt"]))
        if entry.get("reviewedAt"):
            settings_pairs.append((f"doc:{doc_id}:reviewedAt", entry["reviewedAt"]))
        for k, v in settings_pairs:
            conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (k, v))
            report["settings_inserted"] += 1

    for iid, issue in issues_src.items():
        source_doc = None
        prd_key = issue.get("prd")
        if prd_key:
            candidate = manifest_key_to_doc_id.get(prd_key)
            if candidate and candidate in doc_ids_inserted:
                source_doc = candidate
            else:
                report["warnings"].append(
                    f"issue {iid}: prd={prd_key!r} does not resolve to a migrated doc — source_doc left NULL"
                )
        conn.execute(
            "INSERT INTO issues (id, title, status, source_doc, blocked_by, claimed_by, claimed_at, "
            "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                iid,
                issue.get("title", ""),
                issue.get("status", "open"),
                source_doc,
                json.dumps(issue.get("blockedBy") or []),
                issue.get("claimedBy"),
                issue.get("claimedAt"),
                None,
                None,
            ),
        )
        report["issues_inserted"] += 1

        extras = {k: issue[k] for k in ISSUE_EXTRA_FIELDS if k in issue}
        if extras:
            conn.execute(
                "INSERT INTO issue_notes (issue_id, type, author, content, created_at) VALUES (?, ?, ?, ?, ?)",
                (iid, "migration-extra", "migrate_db", json.dumps(extras, ensure_ascii=False, sort_keys=True), None),
            )
            report["issue_notes_extra"] += 1

    for rec in notes_src:
        iid = rec.get("issue")
        if not iid:
            report["warnings"].append("a note record with no issue id was skipped")
            continue
        if iid not in issues_src:
            report["warnings"].append(
                f"note for {iid!r}: no matching issue in issues.json — would dangle issue_notes.issue_id, skipped"
            )
            continue
        verb = rec.get("verb") or "NOTE"
        note_type = NOTE_TYPE_MAP.get(verb, verb.lower())
        fields = rec.get("fields") if isinstance(rec.get("fields"), dict) else {}
        conn.execute(
            "INSERT INTO issue_notes (issue_id, type, author, content, created_at) VALUES (?, ?, ?, ?, ?)",
            (iid, note_type, rec.get("actor"), json.dumps(fields, ensure_ascii=False, sort_keys=True), rec.get("ts")),
        )
        report["issue_notes_from_log"] += 1

    conn.commit()
    return conn, report, manifest_docs, issues_src, notes_src


# --------------------------------------------------------------------------
# verification — independent of the insert-loop counters above: re-reads the
# source files fresh and recomputes expected counts from scratch.
# --------------------------------------------------------------------------


def independent_verify(conn, docs_dir, manifest_docs, tracker_raw):
    cur = conn.cursor()
    checks = []

    src_doc = json.loads(tracker_raw) if tracker_raw else {}
    expected_issues = len(src_doc.get("issues", {}))
    actual_issues = cur.execute("SELECT COUNT(*) FROM issues").fetchone()[0]
    checks.append(("issues", expected_issues, actual_issues))

    expected_notes = len(src_doc.get("notes", []))
    actual_notes = cur.execute(
        "SELECT COUNT(*) FROM issue_notes WHERE type != 'migration-extra'"
    ).fetchone()[0]
    checks.append(("issue_notes (from tracker log)", expected_notes, actual_notes))

    expected_docs = expected_pages = expected_responses = 0
    for entry in manifest_docs.values():
        file_name = entry.get("file", "")
        path = os.path.join(docs_dir, file_name) if file_name else None
        if not path or not os.path.isfile(path):
            continue
        expected_docs += 1
        raw_html = open(path, encoding="utf-8").read()
        n_pages = len(SECTION_OPEN_RX.findall(raw_html))
        expected_pages += n_pages if n_pages else 1  # a page-less doc -> one synthetic page
        expected_responses += len(RESP_RX.findall(raw_html))

    checks.append(("docs", expected_docs, cur.execute("SELECT COUNT(*) FROM docs").fetchone()[0]))
    checks.append(("pages", expected_pages, cur.execute("SELECT COUNT(*) FROM pages").fetchone()[0]))
    checks.append(
        ("responses", expected_responses, cur.execute("SELECT COUNT(*) FROM responses").fetchone()[0])
    )
    return checks


def _resolve_paths(args):
    root = args.root or docstate_root_guess()
    docs_dir = args.docs_dir or os.path.join(root, "entropy-machines-docs")
    tracker_path = args.tracker or os.path.join(root, ".entropy-machines", "issues.json")
    out_path = args.out or os.path.join(root, ".entropy-machines", "entropy-machines.db")
    schema_path = args.schema or os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")
    return root, docs_dir, tracker_path, out_path, schema_path


def docstate_root_guess():
    """Best-effort project root when --root isn't given: the git common dir's
    parent (mirrors lib/roots.sh / lib/config.py), else cwd."""
    import subprocess

    try:
        out = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0 and out.stdout.strip():
            common = out.stdout.strip()
            if not os.path.isabs(common):
                common = os.path.join(os.getcwd(), common)
            return os.path.realpath(os.path.join(common, os.pardir))
    except (OSError, ValueError):
        pass
    return os.getcwd()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", help="project root (default: git common dir's parent, else cwd)")
    ap.add_argument("--docs-dir", help="dialogue-docs directory (default: <root>/entropy-machines-docs)")
    ap.add_argument("--tracker", help="issues.json path (default: <root>/.entropy-machines/issues.json)")
    ap.add_argument("--out", help="output db path (default: <root>/.entropy-machines/entropy-machines.db)")
    ap.add_argument("--schema", help="schema.sql path (default: lib/schema.sql next to this script)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing output db")
    ap.add_argument("--no-verify", action="store_true", help="skip the row-count integrity check")
    args = ap.parse_args(argv)

    root, docs_dir, tracker_path, out_path, schema_path = _resolve_paths(args)

    conn, report, manifest_docs, issues_src, notes_src = migrate(
        root, docs_dir, tracker_path, out_path, schema_path, args.force
    )

    print(f"migrate_db: wrote {out_path}")
    print(
        f"  docs: {report['docs_migrated']} migrated"
        + (f", {len(report['docs_skipped'])} skipped ({', '.join(report['docs_skipped'])})" if report["docs_skipped"] else "")
    )
    if report["fallback_docs"]:
        print(f"  manual-export fallback (single synthetic page): {', '.join(report['fallback_docs'])}")
    print(f"  pages: {report['pages_inserted']}")
    print(
        f"  responses: {report['responses_inserted']}"
        + (f" ({report['responses_value_from_textarea']} value taken from textarea, not responses-data)"
           if report["responses_value_from_textarea"] else "")
    )
    print(f"  replies: {report['replies_inserted']}")
    print(f"  issues: {report['issues_inserted']}")
    print(
        f"  issue_notes: {report['issue_notes_from_log']} from the tracker log"
        + (f" + {report['issue_notes_extra']} migration-extra (issue fields the p3 schema has no column for)"
           if report["issue_notes_extra"] else "")
    )
    print(f"  settings: {report['settings_inserted']}")
    if report["warnings"]:
        print(f"  warnings ({len(report['warnings'])}):")
        for w in report["warnings"]:
            print(f"    - {w}")

    ok = True
    if not args.no_verify:
        tracker_raw = open(tracker_path, encoding="utf-8").read() if os.path.isfile(tracker_path) else ""
        checks = independent_verify(conn, docs_dir, manifest_docs, tracker_raw)
        print("\nverification (independently recounted from source files):")
        for name, expected, actual in checks:
            status = "OK" if expected == actual else "MISMATCH"
            if expected != actual:
                ok = False
            print(f"  {name}: expected {expected}, got {actual}  [{status}]")

    conn.close()
    if not ok:
        print("\nmigrate_db: FAILED verification — see MISMATCH lines above.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
