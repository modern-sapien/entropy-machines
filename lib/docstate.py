"""Shared review-cycle state for dialogue docs.

Source of truth is manifest.json (per-doc handle, file, status, version).
STATE.md is GENERATED from it — never hand-edit the doc table. Version history
is automatic: every save snapshots the prior file into history/<file>/.

Used by bin/serve (auto-snapshot + status on 💾-save) and bin/cycle (the CLI
to move a doc through review). Keeping the logic here means both agree.

Ported from browser-wrap's production-plan infrastructure.
"""
import html as html_mod
import json
import os
import re
import shutil
from datetime import datetime

# Resolved by init(). Callers (bin/serve, bin/cycle, reply.py) must call
# init(docs_dir) before using any other function. Falls back to cwd.
DIR = None
MANIFEST = None
HISTORY = None
STATE = None
INDEX = None
PENDING = None


def init(docs_dir=None):
    """Set the docs directory. Must be called before any other function."""
    global DIR, MANIFEST, HISTORY, STATE, INDEX, PENDING
    if docs_dir is None:
        docs_dir = os.environ.get("ENTROPY_MACHINES_DOCS", os.getcwd())
    DIR = os.path.abspath(docs_dir)
    MANIFEST = os.path.join(DIR, "manifest.json")
    HISTORY = os.path.join(DIR, "history")
    STATE = os.path.join(DIR, "STATE.md")
    INDEX = os.path.join(DIR, "INDEX.html")
    PENDING = os.path.join(DIR, "pending-review.jsonl")

# Docs in these statuses are quiet — nothing pending either way — so their
# response boxes aren't worth scanning for the index.
QUIET_STATUSES = {"resolved", "held"}

# status → (glyph, who holds the ball)
# Collapsed 2026-07-30 from a 7-state vocabulary (awaiting-you/responses-in/
# reviewing/responded/reviewed/held/drafted) that carried no more information
# than "whose turn is it" plus two special cases. Now: 3 ball-states (you/me/—)
# plus `held` (paused, not your turn or mine). `drafted` (not yet shared with
# you) folds into `in-review` — both mean "ball's with me, nothing for you yet."
STATUS = {
    "open": ("🟡 open — your turn", "you"),
    "in-review": ("🔵 in review — my turn", "me"),
    "resolved": ("✅ resolved", "—"),
    "held": ("⏸ held", "—"),
}

# Old name → new name, for migrating a manifest written before the collapse.
STATUS_MIGRATE = {
    "awaiting-you": "open",
    "responded": "open",
    "responses-in": "in-review",
    "reviewing": "in-review",
    "drafted": "in-review",
    "reviewed": "resolved",
    "held": "held",
}


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M")


def load():
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    for e in m.get("docs", {}).values():
        s = e.get("status", "")
        if s in STATUS_MIGRATE:
            e["status"] = STATUS_MIGRATE[s]
    return m


def store(m):
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, MANIFEST)


def resolve(m, phrase):
    """Handle → doc id. Exact handle/id/file first, then substring on
    handle/file/title. Returns doc id or None (or 'AMBIGUOUS:a,b')."""
    p = (phrase or "").strip().lower()
    docs = m["docs"]
    for did, e in docs.items():
        if p in (did.lower(), e.get("file", "").lower(), e.get("handle", "").lower()):
            return did
    hits = [
        did for did, e in docs.items()
        if p and (p in did.lower() or p in e.get("file", "").lower()
                  or p in e.get("title", "").lower() or p in e.get("handle", "").lower())
    ]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        return "AMBIGUOUS:" + ",".join(hits)
    return None


def snapshot(m, did, label=""):
    """Copy the doc's current file into history/<file>/vNNN-<ts>[-label].html,
    bump its version. No-op if the file doesn't exist yet."""
    e = m["docs"][did]
    src = os.path.join(DIR, e["file"])
    if not os.path.isfile(src):
        return e.get("version", 0)
    ver = e.get("version", 0) + 1
    hdir = os.path.join(HISTORY, e["file"])
    os.makedirs(hdir, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    safe = re.sub(r"[^a-z0-9-]+", "-", label.lower()).strip("-")
    name = f"v{ver:03d}-{stamp}" + (f"-{safe}" if safe else "") + ".html"
    shutil.copy2(src, os.path.join(hdir, name))
    e["version"] = ver
    e["updatedAt"] = now()
    return ver


# Transitions that mean the doc's content just changed → worth a version.
# Pure status moves (in-review / held) don't snapshot.
SNAPSHOT_STATUSES = {"open", "resolved"}


def set_status(m, did, status, label=""):
    """Move a doc to a new status. Content-bearing transitions snapshot a
    version first; pure status moves don't. Persists + regenerates STATE.md,
    INDEX.html and DOCS.html. Returns the doc's current version."""
    if status not in STATUS:
        raise ValueError(f"unknown status {status!r}; one of {list(STATUS)}")
    e = m["docs"][did]
    if status in SNAPSHOT_STATUSES:
        snapshot(m, did, label or status)
    e["status"] = status
    e["updatedAt"] = now()
    if status in ("open", "resolved"):
        e["reviewedAt"] = now()
    store(m)
    write_state(m)
    write_index(m)
    render_doctracker()
    return e.get("version", 0)


# The one caller allowed to flip `ready`. Not security — a local single-user
# server has no auth to enforce and pretending otherwise would be theatre. It
# is a mechanism in the sense this repo means: there is NO CLI verb, no cycle.py
# transition, and no path an agent reaches by doing its ordinary job. Getting
# here requires importing this module and passing this constant on purpose,
# which is hand-editing the manifest with extra steps.
#
# Why it matters: "this PRD is ready to build" is the judgment that turns a
# document into a batch of filed issues and, eventually, into unattended work.
# Every other transition in this file is reversible bookkeeping. This one
# spends the owner's night.
OWNER_CLICK = "owner-click:UNATTENDED-OPS-2026-08-09"


def set_ready(m, did, ready, by):
    """Mark a PRD ready to build, or take it back. Owner click only.

    `ready` is a FLAG, not a status: status says who holds the ball ("open" =
    your turn), and a PRD can be resolved without being ready to build or ready
    while a follow-up question is still open. Overloading status would have
    made those two states unrepresentable.
    """
    if by != OWNER_CLICK:
        raise PermissionError(
            "set_ready is the owner's click and nothing else.\n"
            "  There is deliberately no CLI verb and no agent path here — the "
            "checkbox in the doc is the whole interface.\n"
            "  If a PRD needs to be marked ready, ask the owner to tick it.")
    e = m["docs"][did]
    if ready:
        e["ready"] = {"at": now(), "by": "owner"}
        # The tick is the "I'm done, act on it" signal, so it goes on the same
        # durable queue a 💾 does — otherwise it is a flag in the manifest that
        # only a session already looking would ever notice. Untick queues
        # nothing: taking it back is not a request for work.
        queue_review(did, e.get("file", ""), kind="ready")
    else:
        e.pop("ready", None)
    e["updatedAt"] = now()
    # A version bump is what the live-reload poller watches, so ticking the box
    # in one tab updates any other tab showing the same doc.
    e["version"] = e.get("version", 0) + 1
    store(m)
    write_state(m)
    write_index(m)
    render_doctracker()
    return e.get("ready")


def is_ready(e):
    """True when the owner has ticked this doc's ready box."""
    return bool(e.get("ready"))


def render_doctracker():
    """Rebuild DOCS.html (the doc-level tracker UI). Lazy import — doctracker
    imports this module at top level. Never fatal: a broken doctracker.py must
    not block a status flip or a save."""
    try:
        import doctracker
        doctracker.render()
    except Exception as exc:  # noqa: BLE001 - advisory, never blocks the write
        import sys
        print(f"warning: DOCS.html not rebuilt ({exc})", file=sys.stderr)


def queue_review(did, file, kind="save"):
    """Append a save to the review queue. Append-only, one JSON object a line.

    The status flip below is a STATE, and a state is lossy: two saves before
    anyone looks are indistinguishable from one, and a save that lands while no
    session is running leaves nothing that says it happened — the live-reload
    poller only helps a tab that is already open. The queue is the durable half,
    so an unattended responder can ask 'what was answered since I last looked'
    and get an answer that does not depend on having been running at the time.

    `kind` distinguishes the two gestures a reader makes, because they mean
    different things to whoever picks the entry up:

      "save"   a 💾. May be a draft — four of them landed on build-0809 in one
               session while the owner was still typing. Answer it, but do not
               treat it as the reader being finished.
      "ready"  the owner's tick (set_ready). That IS the finished signal: it is
               owner-click-only by construction, and on a sprint report it means
               the sprint is closed. Added 2026-08-11 — before it, a tick wrote
               a manifest flag and nothing else, so "auto pick up on submit"
               had no event to key on.

    Consumed by the responder, which deletes entries it has handled. Best
    effort: a queue write must never be the reason a 💾 fails, because the save
    itself is the thing that matters.
    """
    try:
        with open(PENDING, "a", encoding="utf-8") as f:
            f.write(json.dumps({"doc": did, "file": file, "savedAt": now(),
                                "by": "human", "kind": kind}) + "\n")
    except OSError:
        pass


def read_review_queue(path=None):
    """Queued saves, oldest first. Bad lines are skipped, never fatal."""
    path = path or PENDING
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return out


def drain_review_queue(path=None):
    """Take the queue: return its entries and move it aside in one step.

    Renamed to `.processing` rather than deleted, so a consumer that dies
    halfway leaves the evidence on disk instead of silently swallowing the
    saves it was holding. A rename is atomic on the same filesystem, so a 💾
    landing mid-drain writes a fresh queue rather than appending to one that is
    about to vanish.

    Collapses to the LAST entry per doc: three saves to one doc while nothing
    was running is one thing to respond to, not three.

    The collapse keeps the last entry's TIME but never downgrades its `kind`:
    once the owner has ticked a doc, a later 💾 on the same doc must not turn
    "submitted" back into "saved". Losing that would mean the one gesture that
    says "I am finished, act on it" is erased by the reader typing one more
    word — silently, since the queue is what a consumer sees.
    """
    path = path or PENDING
    entries = read_review_queue(path)
    if not entries:
        return []
    try:
        os.replace(path, path + ".processing")
    except OSError:
        pass
    latest = {}
    for e in entries:
        did = e.get("doc")
        if not did:
            continue
        prior = latest.get(did)
        if prior and prior.get("kind") == "ready" and e.get("kind") != "ready":
            e = dict(e, kind="ready", submittedAt=prior.get("savedAt"))
        latest[did] = e
    return list(latest.values())


def on_save(file):
    """Called by serve.py after a 💾 write: snapshot + flip to 'in-review'
    (ball → me). Silent no-op for files not in the manifest."""
    m = load()
    did = next((d for d, e in m["docs"].items() if e.get("file") == file), None)
    if not did:
        return
    snapshot(m, did, "save")
    # After the snapshot, before the status flip: a queue entry that exists for
    # a save that was never snapshotted would point at nothing.
    queue_review(did, file)
    m["docs"][did]["status"] = "in-review"
    m["docs"][did]["updatedAt"] = now()
    store(m)
    write_state(m)
    write_index(m)
    render_doctracker()


# ---- STATE.md generation -------------------------------------------------
# The doc table + cycle header are generated. Everything between the CYCLE
# markers is PRESERVED across regenerations — that's where the freeform cycle
# narrative (shipped / blocked / next / owed) lives, edited in place.
CYCLE_START = "<!-- CYCLE:START -->"
CYCLE_END = "<!-- CYCLE:END -->"

PREAMBLE = """# STATE — review/build cycle

**Generated file — do not hand-edit the table.** Source of truth is
`manifest.json`; the table + statuses regenerate on every save (`bin/serve`) and
every `bin/cycle` action. Version history is automatic under `history/`. The
narrative between the CYCLE markers is preserved across regenerations — edit it
there.

> **Resume a fresh session by naming a doc:** e.g. _"my responses are in for
> `prd-001`, take a look."_ The handle resolves via manifest, marks it in-review,
> reads your answers, and the status/version/STATE bookkeeping happens
> automatically. `bin/cycle list` shows every handle + status. Open `INDEX.html`
> for the flat queue of open questions.
"""


def _table(m):
    rows = ["| Handle | Doc | Status | Ball | v |", "|---|---|---|---|---|"]
    for did, e in m["docs"].items():
        glyph, _who = STATUS.get(e.get("status", ""), (e.get("status", "?"), "?"))
        who = STATUS.get(e.get("status", ""), ("", "?"))[1]
        rows.append(
            f"| `{did}` | {e.get('title', e.get('file',''))} | {glyph} | {who} | {e.get('version',0)} |"
        )
    return "\n".join(rows)


def write_state(m):
    cycle = ""
    if os.path.isfile(STATE):
        old = open(STATE, encoding="utf-8").read()
        mm = re.search(re.escape(CYCLE_START) + r"(.*?)" + re.escape(CYCLE_END), old, re.S)
        if mm:
            cycle = mm.group(1)
    if not cycle.strip():
        cycle = "\n## Current cycle\n\n_(edit this region — it's preserved across regenerations)_\n\n"
    out = (
        PREAMBLE
        + f"\n_Updated {now()}._\n\n## Docs in flight\n\n"
        + _table(m)
        + "\n\n"
        + CYCLE_START
        + cycle
        + CYCLE_END
        + "\n"
    )
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, STATE)


# ---- INDEX.html generation -------------------------------------------------
# The single-page "what's pending" view. Scans every non-quiet doc's response
# boxes + review asides and buckets each *question* (not each doc) into one of
# three states, independent of the doc's own status:
#   - empty textarea            → still needs your answer
#   - answered, no review aside → I owe you a reply
#   - answered + review aside   → my reply is in; worth a read/confirm
# This is what makes "did Claude read my answer" checkable in one place
# instead of hunting through whichever of the 13 docs it landed in.

_BOX_RX = re.compile(
    r'<div class="response" data-resp="([^"]+)">\s*'
    r'<label>(.*?)</label>\s*'
    r'<div class="discuss">(.*?)</div>\s*'
    r'<textarea[^>]*>(.*?)</textarea>\s*'
    r'</div>',
    re.S,
)
_SECTION_RX = re.compile(r'<section[^>]*\sid="([^"]+)"')
_TAG_RX = re.compile(r"<[^>]+>")


def _text(s):
    return html_mod.unescape(_TAG_RX.sub("", s)).strip()


def extract_boxes(path):
    """Every response box in `path`, each tagged with its answer/review state.

    Returns a list of dicts: key, label, answer, review (html or None),
    section (enclosing <section id> or None, for deep-linking)."""
    if not os.path.isfile(path):
        return []
    src = open(path, encoding="utf-8").read()
    sections = [(m.start(), m.group(1)) for m in _SECTION_RX.finditer(src)]

    def section_for(pos):
        cur = None
        for start, sid in sections:
            if start > pos:
                break
            cur = sid
        return cur

    boxes = []
    for m in _BOX_RX.finditer(src):
        key, label, _discuss, answer = m.groups()
        rm = re.search(
            r'<aside class="review" data-review="%s">(.*?)</aside>' % re.escape(key),
            src, re.S,
        )
        boxes.append({
            "key": key,
            "label": _text(label),
            "answer": html_mod.unescape(answer).strip(),
            "review": rm.group(1).strip() if rm else None,
            "section": section_for(m.start()),
        })
    return boxes


def _esc(s):
    return html_mod.escape(s)


def write_index(m):
    needs_answer, owe_reply, for_your_read, quiet = [], [], [], []
    for did, e in m["docs"].items():
        status = e.get("status", "")
        title = e.get("title", e.get("file", did))
        file = e.get("file", "")
        if status in QUIET_STATUSES:
            quiet.append((did, e))
            continue
        for b in extract_boxes(os.path.join(DIR, file)):
            link = f"{file}#{b['section']}" if b["section"] else file
            row = {**b, "did": did, "title": title, "link": link}
            if not b["answer"]:
                needs_answer.append(row)
            elif not b["review"]:
                owe_reply.append(row)
            else:
                for_your_read.append(row)

    def section(icon, heading, sub, rows, show_answer=False, show_review=False):
        if not rows:
            return ""
        items = []
        for r in rows:
            bits = [f'<div class="q"><a href="{_esc(r["link"])}">{_esc(r["title"])}</a> · <strong>{_esc(r["label"])}</strong></div>']
            if show_answer and r["answer"]:
                bits.append(f'<div class="ans">{_esc(r["answer"])}</div>')
            if show_review and r["review"]:
                bits.append(f'<div class="rev">{r["review"]}</div>')
            items.append(f'<li>{"".join(bits)}</li>')
        return (
            f'<section><h2>{icon} {heading} <span class="count">{len(rows)}</span></h2>'
            f'<p class="sub">{sub}</p><ul class="qlist">{"".join(items)}</ul></section>'
        )

    body = (
        section("🟡", "Needs your answer", "New questions nobody has answered yet.", needs_answer)
        + section("🔵", "I owe you a reply", "You answered — I haven't folded a reply in yet.", owe_reply, show_answer=True)
        + section("✅", "My reply — take a look", "Answered and replied to; read or reopen if you want more.", for_your_read, show_answer=True, show_review=True)
    )
    if not body:
        body = '<section><p class="sub">Nothing pending — every active doc is caught up.</p></section>'

    quiet_rows = "".join(
        f'<tr><td><a href="{_esc(e.get("file",""))}">{_esc(e.get("title", did))}</a></td>'
        f'<td>{STATUS.get(e.get("status",""), (e.get("status","?"),))[0]}</td></tr>'
        for did, e in quiet
    )

    html_out = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Open questions</title>
<style>
  :root{{
    --bg:#faf9fc; --surface:#ffffff; --border:#ddd6fe; --text:#18181b; --muted:#71717a;
    --accent:#7c3aed; --code-bg:#f4f2f8; --warn:#f59e0b; --good:#1a7f37;
    --font:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  }}
  @media (prefers-color-scheme:dark){{
    :root{{ --bg:#0a0a0d; --surface:#18181b; --border:#3a2f5c; --text:#fafafa; --muted:#a1a1aa;
      --accent:#a78bfa; --code-bg:#232030; --warn:#fbbf24; --good:#4ec97a; }}
  }}
  *{{box-sizing:border-box}}
  body{{font-family:var(--font); color:var(--text); background:var(--bg); margin:0; padding:2rem 2.4rem 5rem; line-height:1.55;}}
  h1{{font-size:1.4rem; margin:0 0 .2rem;}}
  .sub{{color:var(--muted); margin:.2rem 0 1.6rem;}}
  h2{{font-size:1.05rem; margin:1.6rem 0 .1rem;}}
  h2 .count{{display:inline-block; font-size:.72rem; font-weight:700; background:var(--code-bg); color:var(--muted); border-radius:99px; padding:.05rem .5rem; vertical-align:middle;}}
  section > .sub{{margin:0 0 .6rem;}}
  ul.qlist{{list-style:none; margin:0; padding:0;}}
  ul.qlist li{{border-left:3px solid var(--warn); background:var(--surface); border:1px solid var(--border); border-left-width:3px; border-radius:0 8px 8px 0; padding:.6rem .8rem; margin:.5rem 0;}}
  .q{{font-size:.95rem;}}
  .q a{{color:var(--text); text-decoration:none; font-weight:600;}}
  .q a:hover{{color:var(--accent);}}
  .ans{{margin-top:.4rem; padding:.4rem .6rem; background:var(--code-bg); border-radius:6px; font-size:.88rem; white-space:pre-wrap;}}
  .rev{{margin-top:.4rem; padding:.4rem .6rem; border-left:2px solid var(--good); font-size:.88rem;}}
  .rev p{{margin:.3rem 0;}}
  table{{border-collapse:collapse; width:100%; font-size:.85rem; margin-top:.5rem;}}
  td{{padding:.3rem .5rem; border-bottom:1px solid var(--border);}}
  td a{{color:var(--text);}}
  details summary{{cursor:pointer; color:var(--muted); font-size:.85rem; margin-top:2rem;}}
</style>
</head><body>
<h1>Open questions</h1>
<p class="sub">Generated {_esc(now())} from every doc's response boxes — one place to check what's pending, instead of 13 files.</p>
{body}
<details><summary>Everything else — resolved / held, no action needed ({len(quiet)})</summary>
<table>{quiet_rows}</table>
</details>
</body></html>
"""
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(html_out)
    os.replace(tmp, INDEX)
