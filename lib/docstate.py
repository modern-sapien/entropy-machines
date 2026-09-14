"""Shared review-cycle state for dialogue docs.

Source of truth is manifest.json (per-doc handle, file, status, version).
STATE.md is GENERATED from it — never hand-edit the doc table. Version history
is automatic: every save snapshots the prior file into history/<file>/.

Used by bin/serve (auto-snapshot + status on 💾-save) and bin/cycle (the CLI
to move a doc through review). Keeping the logic here means both agree.

Ported from browser-wrap's production-plan infrastructure.
"""
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
PENDING = None


def init(docs_dir=None):
    """Set the docs directory. Must be called before any other function."""
    global DIR, MANIFEST, HISTORY, STATE, PENDING
    if docs_dir is None:
        docs_dir = os.environ.get("ENTROPY_MACHINES_DOCS", os.getcwd())
    DIR = os.path.abspath(docs_dir)
    MANIFEST = os.path.join(DIR, "manifest.json")
    HISTORY = os.path.join(DIR, "history")
    STATE = os.path.join(DIR, "STATE.md")
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
    if not os.path.exists(MANIFEST):
        return {}
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
    version first; pure status moves don't. Persists + regenerates STATE.md.
    Returns the doc's current version."""
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
    return e.get("version", 0)


# The one caller allowed to flip `ready`. Not security — a local single-user
# server has no auth to enforce and pretending otherwise would be theatre. It
# is a mechanism in the sense this repo means: there is NO CLI verb, no cycle.py
# transition, and no path an agent reaches by doing its ordinary job. Getting
# here requires importing this module and passing this constant on purpose,
# which is hand-editing the manifest with extra steps.
#
# Why it matters: "this doc is accepted" is the judgment that turns a document
# into actionable work — on a PRD, a batch of filed issues; on a report, a
# closed sprint; on any other doc, "the owner has signed off." Every other
# transition in this file is reversible bookkeeping. This one spends the
# owner's night.
OWNER_CLICK = "owner-click:UNATTENDED-OPS-2026-08-09"


def set_ready(m, did, ready, by):
    """Mark a doc as accepted (ready), or take it back. Owner click only.

    Applies to every tracked doc type — PRDs, reports, and docs alike. On a
    PRD it means "ready to build"; on a report it means "sprint closed"; on
    any other doc it means the owner has signed off.

    `ready` is a FLAG, not a status: status says who holds the ball ("open" =
    your turn), and a doc can be resolved without being accepted, or accepted
    while a follow-up question is still open. Overloading status would have
    made those two states unrepresentable.
    """
    if by != OWNER_CLICK:
        raise PermissionError(
            "set_ready is the owner's click and nothing else.\n"
            "  There is deliberately no CLI verb and no agent path here — the "
            "checkbox in the doc is the whole interface.\n"
            "  If a doc needs to be marked accepted, ask the owner to tick it.")
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
    return e.get("ready")


def is_ready(e):
    """True when the owner has ticked this doc's ready box."""
    return bool(e.get("ready"))



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
> automatically. `bin/cycle list` shows every handle + status.
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


def write_index(m):
    # INDEX.html generation removed — the React SPA serves the dashboard.
    return
