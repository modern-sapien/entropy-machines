#!/usr/bin/env python3
"""tracker-view — render TRACKER.html, a browsable READ-ONLY view of the issue
store, into the project's docs directory.

Never invoked directly: `bin/tracker render` resolves the config once and runs
this with what it needs in the environment (docs/CONFIG.md rule 3 — one reader
of config.json per command).

  ENTROPY_MACHINES_ROOT             repo root; relative paths below resolve against it
  ENTROPY_MACHINES_TRACKER_PATH     the store, relative to ENTROPY_MACHINES_ROOT
  ENTROPY_MACHINES_TRACKER_BACKEND  "file" or "command"
  ENTROPY_MACHINES_DOCS_DIR         docs.dir — where TRACKER.html lands
  ENTROPY_MACHINES_PROJECT_NAME     project.name, for the page title (optional)

WHY THIS IS NOT A SEVENTH ADAPTER OPERATION. docs/TRACKER-ADAPTER.md asks a
backend for six things, and rendering is not one of them: it is a VIEW over
whatever a backend already stores, so making it a backend operation would ask
every future `command` backend to ship an HTML generator. It is also not
`bin/tracker`'s own job — that file is a dispatcher whose entire discipline is
to resolve config and hand off inside a subshell — so the view lives here, in
one place, and `bin/tracker render` intercepts the word before the backend
dispatch ever sees it. A backend can never be asked to implement `render`.

WHY IT READS THE STORE DIRECTLY, AND WHY IT REFUSES A `command` BACKEND. The
six operations cannot enumerate issues: `show` takes an id you already have
and `ready` deliberately returns only what is claimable — which is the exact
half of the picture this page exists to show the other side of. So this reads
the file backend's JSON, once, and refuses when tracker.backend is "command"
rather than printing a page that silently omits every issue that is held,
gated, blocked or done. A partial tracker is worse than no tracker: it reads
as complete. (If you run an external tracker, that tracker has its own UI —
this one is for the built-in store.)

ONE READ, NOT THREE SUBPROCESSES. lib/tracker-file replaces the store
atomically, so a single read is a consistent snapshot; three shell-outs to
`show`/`ready`/`notes` could interleave with a concurrent writer and produce a
page that never existed. The cost is that the readiness rule — notstarted, not
held, not gated, no open blocker (an unknown blocker counts as open) — is
stated here as well as in lib/tracker-file's cmd_ready. That duplication is
guarded by a test: tests/cases/tracker-render-writes-a-browsable-view.sh
compares the ids this page marks ready against `bin/tracker ready` itself.

HELD, GATED AND BLOCKED ARE NOT STATUSES — they are field presence, and an
issue can carry several at once (a half-implemented issue can be held). The
page never flattens them into one column: every issue lands in one bucket by
precedence for grouping, and carries a badge plus a reason line for EVERY
condition that applies. The reason is the only thing a reader actually needs:
"not ready" without "why" is what this view exists to stop.

READ-ONLY BY CONSTRUCTION. No answer boxes, no save button, no write path, no
fetch of any kind, and nothing loaded from off this machine. bin/serve serves
it because it is an .html file in the docs directory, and that is the whole
integration.
"""
from __future__ import annotations

import datetime
import html
import json
import os
import sys

BUCKET_ORDER = ["ready", "inflight", "held", "gated", "blocked", "done"]


def refuse(msg_lines, code=2):
    for line in msg_lines:
        print(line, file=sys.stderr)
    sys.exit(code)


def open_blockers_of(issue, issues):
    """The blockers that still block. An id with no issue behind it counts as
    open — the same call lib/tracker-file's cmd_ready makes, and the safe one:
    a typo in blockedBy must not read as satisfied."""
    out = []
    for dep in issue.get("blockedBy") or []:
        dep_issue = issues.get(dep)
        if dep_issue is None or dep_issue.get("status") != "done":
            out.append(dep)
    return out


def derive(iid, issue, issues):
    """The flags and the grouping bucket for one issue."""
    status = issue.get("status") or "notstarted"
    held = bool((issue.get("heldWhy") or "").strip())
    gated = bool((issue.get("gate") or "").strip())
    openb = open_blockers_of(issue, issues)
    done = status == "done"
    inflight = status == "progress"
    ready = status == "notstarted" and not held and not gated and not openb

    flags = []
    if ready:
        flags.append("ready")
    if inflight:
        flags.append("inflight")
    if held:
        flags.append("held")
    if gated:
        flags.append("gated")
    if openb:
        flags.append("blocked")
    if done:
        flags.append("done")

    # Precedence for the single bucket a row is grouped under. Done first
    # (closed work is not "held" in any useful sense); then the reasons it is
    # not claimable, most decision-like first; then in flight; then ready.
    if done:
        bucket = "done"
    elif held:
        bucket = "held"
    elif gated:
        bucket = "gated"
    elif openb:
        bucket = "blocked"
    elif inflight:
        bucket = "inflight"
    elif ready:
        bucket = "ready"
    else:
        # notstarted with no reason recorded and no blocker is ready by
        # definition, so this is unreachable today. It exists so a future
        # field that suppresses readiness cannot make an issue vanish from
        # every group: it lands in "blocked" with no reason and is visible.
        bucket = "blocked"

    return flags, bucket, openb


def build_payload(store, project, store_rel):
    issues = store.get("issues") or {}
    notes = store.get("notes") or []

    blocks = {}
    for iid, issue in issues.items():
        for dep in issue.get("blockedBy") or []:
            blocks.setdefault(dep, [])
            if iid not in blocks[dep]:
                blocks[dep].append(iid)

    by_issue = {}
    orphan_notes = 0
    for rec in notes:
        if not isinstance(rec, dict):
            continue
        iid = rec.get("issue")
        if not isinstance(iid, str) or iid not in issues:
            orphan_notes += 1
            continue
        fields = rec.get("fields")
        by_issue.setdefault(iid, []).append({
            "ts": rec.get("ts") or "",
            "verb": rec.get("verb") or "NOTE",
            "actor": rec.get("actor") or "unknown",
            "fields": fields if isinstance(fields, dict) else {},
        })

    out_issues = {}
    for iid in sorted(issues):
        issue = issues[iid]
        flags, bucket, openb = derive(iid, issue, issues)
        done_blockers = [b for b in (issue.get("blockedBy") or []) if b not in openb]
        out_issues[iid] = {
            "id": iid,
            "title": issue.get("title") or "",
            "status": issue.get("status") or "notstarted",
            "effort": issue.get("effort") or "",
            "heldWhy": issue.get("heldWhy") or "",
            "heldAt": issue.get("heldAt") or "",
            "gate": issue.get("gate") or "",
            "gatedAt": issue.get("gatedAt") or "",
            "claimedBy": issue.get("claimedBy") or "",
            "claimedAt": issue.get("claimedAt") or "",
            "blockedBy": list(issue.get("blockedBy") or []),
            "openBlockers": openb,
            "doneBlockers": done_blockers,
            "blocks": sorted(blocks.get(iid, [])),
            "flags": flags,
            "bucket": bucket,
            "notes": by_issue.get(iid, []),
        }

    efforts = sorted({i["effort"] for i in out_issues.values() if i["effort"]},
                     key=lambda e: ({"S": 0, "M": 1, "L": 2}.get(e, 3), e))

    return {
        "project": project,
        "store": store_rel,
        "generated": datetime.datetime.now(datetime.timezone.utc)
                             .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "issues": out_issues,
        "efforts": efforts,
        "orphanNotes": orphan_notes,
    }


def render(payload, out_path):
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True).replace("</", "<\\/")
    doc = (TEMPLATE
           .replace("__PROJECT__", html.escape(payload["project"] or "this repo"))
           .replace("__GENERATED__", html.escape(payload["generated"]))
           .replace("__STORE__", html.escape(payload["store"]))
           .replace("__DATA__", blob))
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(doc)
    os.replace(tmp, out_path)
    return out_path


def finish(payload, docs_path, root, store_rel):
    """Write the page and report what went into it. Exits 0."""
    out = render(payload, os.path.join(docs_path, "TRACKER.html"))
    n = len(payload["issues"])
    buckets = {b: 0 for b in BUCKET_ORDER}
    for issue in payload["issues"].values():
        buckets[issue["bucket"]] += 1
    breakdown = ", ".join("%d %s" % (buckets[b], b) for b in BUCKET_ORDER if buckets[b])
    print("tracker render: wrote %s" % os.path.relpath(out, root))
    if n:
        print("  %d issue(s): %s" % (n, breakdown))
    else:
        print("  no issues filed yet — `bin/tracker set <id> title=\"…\"` files "
              "the first one.")
    print("  read-only view, generated from %s — re-run after any change; "
          "hand edits are lost." % store_rel)
    print("  `bin/serve` already serves it: open /TRACKER.html there.")
    return 0


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip("\n"))
        return 0
    if argv:
        print("usage: bin/tracker render", file=sys.stderr)
        return 2

    root = os.environ.get("ENTROPY_MACHINES_ROOT") or os.getcwd()
    backend = os.environ.get("ENTROPY_MACHINES_TRACKER_BACKEND") or "file"
    store_rel = os.environ.get("ENTROPY_MACHINES_TRACKER_PATH") or ".entropy-machines/issues.json"
    docs_dir = os.environ.get("ENTROPY_MACHINES_DOCS_DIR") or "entropy-machines-docs"
    project = os.environ.get("ENTROPY_MACHINES_PROJECT_NAME") or os.path.basename(root)

    if backend != "file":
        refuse([
            'tracker render: REFUSED — tracker.backend is "%s", and this view '
            "can only be built" % backend,
            "  from the built-in \"file\" store. The adapter contract "
            "(docs/TRACKER-ADAPTER.md)",
            "  has no operation that lists issues — `show` takes an id you "
            "already have and",
            "  `ready` returns only what is claimable, which is the half this "
            "page exists to",
            "  show the other side of. Rendering from those two would drop "
            "every held, gated,",
            "  blocked and done issue and still look complete, so it refuses "
            "instead.",
        ])

    store_path = store_rel if os.path.isabs(store_rel) else os.path.join(root, store_rel)
    # A MISSING STORE IS AN EMPTY STORE, not an error — exactly what
    # lib/tracker-file's _load() decides, and the same reason: the file is
    # created by the first write, so a project that has just run bin/init has
    # no store yet and is not broken. Refusing here would leave the link the
    # shipped PRD carries to this page dead for every new project until
    # somebody happened to file an issue, which is the bug this page was
    # written to fix.
    store = {"issues": {}, "notes": []}
    if os.path.isfile(store_path):
        try:
            with open(store_path, encoding="utf-8") as f:
                store = json.load(f)
        except (OSError, ValueError) as err:
            refuse([
                "tracker render: REFUSED — could not read the issue store at "
                "%s:" % store_path,
                "  %s" % err,
            ])

    docs_path = docs_dir if os.path.isabs(docs_dir) else os.path.join(root, docs_dir.strip("/"))
    if not os.path.isdir(docs_path):
        try:
            os.makedirs(docs_path)
        except OSError as err:
            refuse([
                "tracker render: REFUSED — could not create the docs directory "
                "%s:" % docs_path,
                "  %s" % err,
            ])

    return finish(build_payload(store, project, store_rel), docs_path, root, store_rel)


# ---------------------------------------------------------------------------
# the page
# ---------------------------------------------------------------------------
# Palette and rules follow VS Code's High Contrast themes (hc-black default,
# hc-light under [data-theme=light]): separation by border, never a background
# tint; one focus hue that is never used as a fill; no state carried in
# opacity; four type steps. Nothing is fetched — no CDN, no webfont, no
# script, no image. The whole page is this file.
TEMPLATE = r"""<!doctype html>
<html lang="en" data-generated="bin/tracker render"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__PROJECT__ — issue tracker</title>
<!-- GENERATED FILE — the data-generated attribute on <html> above says the same
     thing where a tool can see it, because a checker that masks HTML comments
     (bin/doclint does, deliberately) cannot read this one.
     Written by `bin/tracker render` (lib/tracker-view.py) from
     the issue store. Hand edits are lost on the next render; change the issues
     instead. This is a READ-ONLY view: it has no question boxes, no save
     button and no write path of any kind, deliberately, because it is
     regenerated rather than answered. It is also entirely local: every byte it
     needs is in this file. -->
<style>
:root{                        /* hc-black */
  --bg:#000; --panel:#000;
  --ink:#fff; --dim:rgba(255,255,255,.7);
  --line:#6FC3DF;             /* contrastBorder */
  --focus:#F38518;            /* focusBorder / activeContrastBorder */
  --accent:#21A6FF;           /* textLink.foreground */
  --ready:#23D18B; --prog:#F5F543; --blocked:#F48771; --held:#D670D6;
  --gated:#21A6FF; --done:#fff;
  --fs-sm:12px; --fs-base:14px; --fs-head:16px; --fs-title:20px;
  --mono:ui-monospace,SFMono-Regular,Menlo,monospace;
}
:root[data-theme=light]{      /* hc-light */
  --bg:#fff; --panel:#fff;
  --ink:#292929; --dim:rgba(41,41,41,.75);
  --line:#0F4A85;
  --focus:#006BBD;
  --accent:#0F4A85;
  --ready:#0A5C21; --prog:#7A4A00; --blocked:#A81C0B; --held:#6B21A8;
  --gated:#0F4A85; --done:#292929;
}
*{box-sizing:border-box}
body{margin:0;display:flex;min-height:100vh;background:var(--bg);color:var(--ink);
  font:var(--fs-base)/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
body>nav{width:296px;flex:none;border-right:1px solid var(--line);background:var(--panel);
  padding:22px 14px;position:sticky;top:0;height:100vh;overflow-y:auto}
body>nav .brand{display:flex;align-items:center;gap:8px;font-weight:700;
  font-size:var(--fs-base);margin-bottom:16px;padding:0 6px}
body>nav .brand .logo{width:18px;height:18px;border:1px solid var(--line);background:none}
body>nav a{display:block;padding:6px 10px;color:var(--ink);text-decoration:none;
  font-size:var(--fs-base);margin-bottom:2px;border:1px solid transparent}
body>nav a:hover{box-shadow:inset 0 0 0 2px var(--focus)}
body>nav a.cur{border-color:var(--line);font-weight:700}
body>nav .grp{font-size:var(--fs-sm);font-weight:700;text-transform:uppercase;
  letter-spacing:.06em;color:var(--ink);margin:16px 6px 6px}
.content{flex:1;min-width:0}
a{color:var(--accent)}
code,.mono{font-family:var(--mono);font-size:var(--fs-sm)}
code{border:1px solid var(--line);padding:0 4px}
:focus-visible{outline:2px solid var(--focus);outline-offset:1px}

header{position:sticky;top:0;z-index:20;background:var(--panel);
  border-bottom:1px solid var(--line);padding:10px 16px;
  display:flex;gap:12px;align-items:center;flex-wrap:wrap}
header h1{font-size:var(--fs-head);margin:0;font-weight:700}
header h1 span{color:var(--dim);font-weight:400}
#q{flex:1;min-width:200px;background:var(--panel);border:1px solid var(--line);
  color:var(--ink);padding:7px 10px;font-size:var(--fs-base)}
#q::placeholder{color:var(--dim)}
#q:focus{outline:none;border-color:var(--focus);box-shadow:0 0 0 1px var(--focus)}
.seg{display:flex;border:1px solid var(--line)}
.seg button{background:var(--panel);border:0;color:var(--ink);padding:7px 11px;
  font-size:var(--fs-sm);font-weight:700;cursor:pointer;border-right:1px solid var(--line)}
.seg button:last-child{border-right:0}
.seg button:hover{box-shadow:inset 0 0 0 1px var(--focus)}
.seg button.on{color:var(--focus);box-shadow:inset 0 0 0 2px var(--focus)}
#clear{background:var(--panel);border:1px solid var(--focus);color:var(--ink);
  padding:7px 11px;font-size:var(--fs-sm);font-weight:700;cursor:pointer}
#clear:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.tot{color:var(--ink);font-size:var(--fs-sm);white-space:nowrap;
  font-variant-numeric:tabular-nums}
.jump{display:flex;flex-wrap:wrap;gap:6px;width:100%;order:9}
.jump button{background:var(--panel);border:1px solid var(--line);color:var(--ink);
  font-size:var(--fs-sm);font-weight:700;padding:3px 9px;cursor:pointer;
  display:inline-flex;align-items:center;gap:6px}
.jump button:hover{box-shadow:inset 0 0 0 2px var(--focus)}

main{display:flex;align-items:flex-start}
aside{width:230px;flex:none;position:sticky;top:52px;max-height:calc(100vh - 52px);
  overflow:auto;padding:14px 10px 40px;border-right:1px solid var(--line)}
.grp{font-weight:700;font-size:var(--fs-sm);letter-spacing:.09em;
  text-transform:uppercase;margin:14px 6px 6px}
.grp .hint{display:block;text-transform:none;letter-spacing:0;font-weight:400;
  color:var(--ink);font-size:var(--fs-sm)}
.f{display:flex;align-items:center;gap:8px;width:100%;background:var(--panel);
  border:1px solid transparent;color:var(--ink);padding:5px 7px;cursor:pointer;
  font-size:var(--fs-base);text-align:left}
.f:hover{border-color:var(--line)}
.f.on{border-color:var(--focus);box-shadow:inset 0 0 0 1px var(--focus);font-weight:700}
.f .n{margin-left:auto;font-size:var(--fs-base);font-variant-numeric:tabular-nums;
  min-width:2.5em;text-align:right}
.f.zero .n{text-decoration:line-through}
.dot{width:10px;height:10px;flex:none;border:1px solid var(--bg);
  box-shadow:0 0 0 1px currentColor}
.dot.ready{background:var(--ready);color:var(--ready)}
.dot.inflight{background:var(--prog);color:var(--prog)}
.dot.held{background:var(--held);color:var(--held)}
.dot.gated{background:var(--gated);color:var(--gated)}
.dot.blocked{background:var(--blocked);color:var(--blocked)}
.dot.done{background:var(--done);color:var(--done)}

section{flex:1;min-width:0;padding:16px 18px 80px}
.bh{display:flex;align-items:baseline;gap:10px;margin:22px 0 8px}
.bh:first-child{margin-top:0}
.bh h2{font-size:var(--fs-head);margin:0;font-weight:700}
.bh .meta{color:var(--ink);font-size:var(--fs-sm)}
.rows{border:1px solid var(--line)}
.row{display:flex;gap:10px;align-items:flex-start;padding:9px 12px;cursor:pointer;
  border-top:1px solid var(--line);flex-wrap:wrap}
.row:first-child{border-top:0}
.row:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.row .dot{margin-top:5px}
.row .t{flex:1;min-width:220px;font-weight:700}
.row.done .t{font-weight:400}   /* weight, not opacity, marks closed work */
.row .id{font-family:var(--mono);font-size:var(--fs-sm);flex:none}
.row .why{flex-basis:100%;padding-left:20px;font-size:var(--fs-sm)}
.row .why b{font-weight:700}
.tag{font-size:var(--fs-sm);font-weight:700;padding:1px 8px;border:1px solid var(--line);
  flex:none;white-space:nowrap;background:transparent}
.tag.eff{font-variant-numeric:tabular-nums;min-width:24px;text-align:center}
.tag.ready{color:var(--ready);border-color:var(--ready)}
.tag.inflight{color:var(--prog);border-color:var(--prog)}
.tag.held{color:var(--held);border-color:var(--held)}
.tag.gated{color:var(--gated);border-color:var(--gated)}
.tag.blocked{color:var(--blocked);border-color:var(--blocked)}
.why.held{color:var(--held)}
.why.gated{color:var(--gated)}
.why.blocked{color:var(--blocked)}

.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}
.col{border:1px solid var(--line);padding:8px;min-width:0}
.col h3{margin:2px 4px 8px;font-size:var(--fs-base);font-weight:700;
  display:flex;gap:7px;align-items:center}
.card{border:1px solid var(--line);padding:7px 9px;margin-bottom:6px;cursor:pointer}
.card:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.card .t{font-size:var(--fs-base);margin-bottom:3px;font-weight:600}
.card .m{font-family:var(--mono);font-size:var(--fs-sm);display:flex;gap:6px}

#empty{padding:40px 4px}
footer{border-top:1px solid var(--line);margin:0 18px;padding:12px 0 40px;
  font-size:var(--fs-sm)}

#scrim{position:fixed;inset:0;background:#000c;z-index:30;display:none}
#scrim.on{display:block}
#det{position:fixed;top:0;right:0;bottom:0;width:min(680px,94vw);z-index:31;
  background:var(--panel);border-left:2px solid var(--line);overflow:auto;
  transform:translateX(100%);transition:transform .16s ease;padding:18px 22px 60px}
#det.on{transform:none}
#det h2{margin:6px 40px 4px 0;font-size:var(--fs-title);line-height:1.3}
#det .sub{font-family:var(--mono);font-size:var(--fs-sm);margin-bottom:14px}
#close{position:absolute;top:12px;right:16px;background:var(--panel);
  border:1px solid var(--line);width:30px;height:30px;color:var(--ink);
  font-size:var(--fs-title);cursor:pointer;line-height:1}
#close:hover{border-color:var(--focus);box-shadow:inset 0 0 0 1px var(--focus)}
.blk{margin:16px 0}
.blk h4{margin:0 0 6px;font-size:var(--fs-sm);letter-spacing:.09em;
  text-transform:uppercase;font-weight:700}
.blk.reason{border:1px solid var(--line);border-left:3px solid var(--line);padding:9px 12px}
.blk.reason.held{border-color:var(--held)}
.blk.reason.held h4{color:var(--held)}
.blk.reason.gated{border-color:var(--gated)}
.blk.reason.gated h4{color:var(--gated)}
.blk.reason.blocked{border-color:var(--blocked)}
.blk.reason.blocked h4{color:var(--blocked)}
.blk .when{font-size:var(--fs-sm);font-family:var(--mono)}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--line);
  padding:3px 8px;font-size:var(--fs-sm);cursor:pointer}
.chip.dead{cursor:default;border-style:dashed}
.chip:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.note{border-top:1px solid var(--line);padding:8px 0}
.note:first-of-type{border-top:0}
.note .hd{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;
  font-family:var(--mono);font-size:var(--fs-sm)}
.note .verb{font-weight:700;border:1px solid var(--line);padding:0 6px}
.note .verb.DISPATCH{color:var(--prog);border-color:var(--prog)}
.note .verb.HANDOFF{color:var(--ready);border-color:var(--ready)}
.note .when{margin-left:auto}
.note dl{margin:6px 0 0;display:grid;grid-template-columns:max-content 1fr;
  gap:2px 10px}
.note dt{font-family:var(--mono);font-size:var(--fs-sm);font-weight:700}
.note dd{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
</style></head>
<body>
<nav>
  <div class="brand"><span class="logo"></span> Issue tracker</div>
  <div class="grp">Categories</div>
  <a href="TRACKER.html">issues</a>
  <a href="PRDS.html">PRDs</a>
  <a href="REPORTS.html">reports</a>
  <a href="DOCS.html">docs</a>
</nav>
<div class="content">
<header>
  <h1>__PROJECT__ <span>· issue tracker</span></h1>
  <input id="q" placeholder="search id, title, reason, note…  (/ to focus)">
  <div class="seg" id="view">
    <button data-v="list" class="on">List</button>
    <button data-v="board">Board</button>
  </div>
  <div class="seg" id="theme"><button title="light / dark">&#9680;</button></div>
  <button id="clear" hidden>clear filters</button>
  <div class="tot" id="tot"></div>
  <div class="jump" id="jump"></div>
</header>
<main>
  <aside>
    <div class="grp">State<span class="hint">held, gated and blocked are
      fields, not statuses — an issue can carry more than one.</span></div>
    <div id="fstate"></div>
    <div class="grp">Effort</div><div id="feff"></div>
  </aside>
  <section id="out"></section>
</main>
<footer id="foot"></footer>
</div>
<div id="scrim"></div>
<div id="det"><button id="close" title="close">&#215;</button><div id="detBody"></div></div>

<script id="tracker-data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('tracker-data').textContent);
const IS = D.issues;
const ids = Object.keys(IS);
const BUCKETS = [
  ['ready','Ready','claimable now — nothing is holding it'],
  ['inflight','In flight','claimed, being worked'],
  ['held','Held','a decision not to do it now, with the reason'],
  ['gated','Gated','waiting on a ruling outside the issue graph'],
  ['blocked','Blocked','waiting on another issue'],
  ['done','Done','finished']
];
const BL = Object.fromEntries(BUCKETS.map(b => [b[0], b[1]]));
const esc = s => String(s == null ? '' : s)
  .replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const day = ts => (ts || '').slice(0, 10);

const F = {state:new Set(), eff:new Set()};
let view = 'list', q = '';

function haystack(id){
  const it = IS[id];
  const notes = it.notes.map(n => n.verb + ' ' + n.actor + ' ' +
    Object.entries(n.fields).map(([k,v]) => k + ' ' +
      (Array.isArray(v) ? v.join(' ') : String(v == null ? '' : v))).join(' ')).join(' ');
  return (id + ' ' + it.title + ' ' + it.heldWhy + ' ' + it.gate + ' ' +
    it.claimedBy + ' ' + it.blockedBy.join(' ') + ' ' + notes).toLowerCase();
}
function hits(id){
  if (!q) return true;
  const hay = haystack(id);
  return q.split(/\s+/).every(w => hay.includes(w));
}
// One predicate for the list and for the facet counts. `skip` leaves one facet
// out, so each sidebar group counts against every OTHER active filter.
function passes(id, skip){
  const it = IS[id];
  if (!hits(id)) return false;
  if (skip !== 'state' && F.state.size && !it.flags.some(f => F.state.has(f))) return false;
  if (skip !== 'eff' && F.eff.size && !F.eff.has(it.effort)) return false;
  return true;
}
const match = id => passes(id, null);

function reasonLines(it){
  // WHY IT IS NOT CLAIMABLE — the whole point of the page. Each condition is
  // its own line with its own wording and its own hue, so held, gated and
  // blocked never read as the same thing.
  const out = [];
  if (it.heldWhy) out.push(['held',
    '<b>held</b> — ' + esc(it.heldWhy) + (it.heldAt ? ' <span class="mono">(since ' +
      esc(day(it.heldAt)) + ')</span>' : '')]);
  if (it.gate) out.push(['gated',
    '<b>gated</b> on <code>' + esc(it.gate) + '</code> — an open question outside the ' +
    'issue graph' + (it.gatedAt ? ' <span class="mono">(since ' + esc(day(it.gatedAt)) +
      ')</span>' : '')]);
  if (it.openBlockers.length) out.push(['blocked',
    '<b>blocked by</b> ' + it.openBlockers.map(b => '<code>' + esc(b) + '</code>' +
      (IS[b] ? '' : ' (no such issue)')).join(', ')]);
  return out;
}

function tagsFor(it){
  let t = '';
  it.flags.forEach(f => {
    if (f === 'done' || f === 'ready') return;
    t += '<span class="tag ' + f + '">' + esc(BL[f].toLowerCase()) + '</span>';
  });
  if (it.flags.includes('ready')) t += '<span class="tag ready">ready</span>';
  if (it.claimedBy) t += '<span class="tag">' + esc(it.claimedBy) + '</span>';
  if (it.blocks.length) t += '<span class="tag">blocks ' + it.blocks.length + '</span>';
  return t;
}

function rowFor(id){
  const it = IS[id];
  const why = reasonLines(it).map(r =>
    '<div class="why ' + r[0] + '">' + r[1] + '</div>').join('');
  return '<div class="row ' + it.bucket + '" data-id="' + esc(id) + '">' +
    '<span class="dot ' + it.bucket + '"></span>' +
    '<span class="t">' + (esc(it.title) || '<em>(no title)</em>') + '</span>' +
    tagsFor(it) +
    '<span class="tag eff">' + (esc(it.effort) || '·') + '</span>' +
    '<span class="id">' + esc(id) + '</span>' + why + '</div>';
}

function render(){
  const sel = ids.filter(match);
  document.getElementById('tot').textContent =
    sel.length + ' of ' + ids.length + ' · ' +
    sel.filter(i => IS[i].status !== 'done').length + ' open';
  const out = document.getElementById('out');

  if (!sel.length){
    out.innerHTML = '<div id="empty">' + (ids.length ? 'Nothing matches.' :
      'No issues filed yet. <code>bin/tracker set &lt;id&gt; title=&quot;…&quot;</code> ' +
      'files the first one, then re-run <code>bin/tracker render</code>.') + '</div>';
  } else if (view === 'board'){
    out.innerHTML = '<div class="cols">' + BUCKETS.map(([b, label]) => {
      const items = sel.filter(i => IS[i].bucket === b);
      return '<div class="col" id="b-' + b + '"><h3><span class="dot ' + b + '"></span>' +
        label + '<span style="margin-left:auto">' + items.length + '</span></h3>' +
        items.map(i => '<div class="card" data-id="' + esc(i) + '">' +
          '<div class="t">' + (esc(IS[i].title) || '(no title)') + '</div>' +
          '<div class="m">' + esc(i) + '<span style="margin-left:auto">' +
          esc(IS[i].effort) + '</span></div></div>').join('') + '</div>';
    }).join('') + '</div>';
  } else {
    let h = '';
    for (const [b, label, blurb] of BUCKETS){
      const items = sel.filter(i => IS[i].bucket === b);
      if (!items.length) continue;
      h += '<div class="bh" id="b-' + b + '"><span class="dot ' + b + '"></span>' +
        '<h2>' + label + '</h2><span class="meta">' + items.length + ' · ' + blurb +
        '</span></div><div class="rows">' + items.map(rowFor).join('') + '</div>';
    }
    out.innerHTML = h;
  }
  counts();
  foot();
}

function counts(){
  const pool = k => ids.filter(i => passes(i, k));
  const opt = (k, v, label, n, on) =>
    '<button class="f ' + (on ? 'on' : '') + ' ' + (n ? '' : 'zero') + '" data-k="' + k +
    '" data-v="' + esc(v) + '">' + label + '<span class="n">' + n + '</span></button>';
  const bs = pool('state'), be = pool('eff');
  document.getElementById('fstate').innerHTML = BUCKETS.map(([b, label]) =>
    opt('state', b, '<span class="dot ' + b + '"></span>' + label,
        bs.filter(i => IS[i].flags.includes(b)).length, F.state.has(b))).join('');
  document.getElementById('feff').innerHTML = D.efforts.length
    ? D.efforts.map(e => opt('eff', e, esc(e),
        be.filter(i => IS[i].effort === e).length, F.eff.has(e))).join('')
    : '<div class="f" style="cursor:default">no effort recorded yet</div>';
  document.getElementById('jump').innerHTML = BUCKETS.map(([b, label]) =>
    '<button data-jump="' + b + '"><span class="dot ' + b + '"></span>' + label + ' ' +
    ids.filter(i => IS[i].flags.includes(b)).length + '</button>').join('');
  const n = F.state.size + F.eff.size + (q ? 1 : 0);
  document.getElementById('clear').hidden = !n;
}

function foot(){
  document.getElementById('foot').innerHTML =
    'Generated <span class="mono">__GENERATED__</span> from <code>__STORE__</code> by ' +
    '<code>bin/tracker render</code>. Read-only: it is a view, not a document — ' +
    're-run that command to refresh it, and expect any hand edit to be overwritten.' +
    (D.orphanNotes ? ' <b>' + D.orphanNotes + '</b> note(s) name an issue that is not ' +
      'in the store and are not shown.' : '');
}

function chipRow(list){
  return list.map(i => IS[i]
    ? '<span class="chip" data-id="' + esc(i) + '"><span class="dot ' + IS[i].bucket +
      '"></span>' + esc(i) + ' — ' + (esc(IS[i].title) || '(no title)') + '</span>'
    : '<span class="chip dead">' + esc(i) + ' — no such issue (counts as blocking)</span>'
  ).join('');
}

function noteHtml(n){
  const rows = Object.keys(n.fields).sort().map(k => {
    const v = n.fields[k];
    const text = Array.isArray(v) ? v.join('\n')
      : (v && typeof v === 'object') ? JSON.stringify(v, null, 2) : String(v == null ? '' : v);
    return '<dt>' + esc(k) + '</dt><dd>' + esc(text) + '</dd>';
  }).join('');
  return '<div class="note"><div class="hd"><span class="verb ' + esc(n.verb) + '">' +
    esc(n.verb) + '</span><span>' + esc(n.actor) + '</span>' +
    '<span class="when">' + esc(n.ts) + '</span></div>' +
    (rows ? '<dl>' + rows + '</dl>' : '') + '</div>';
}

function openDet(id){
  const it = IS[id];
  let h = '<h2>' + (esc(it.title) || '(no title)') + '</h2><div class="sub">' +
    esc(id) + ' · status ' + esc(it.status) + ' · effort ' + (esc(it.effort) || '—') +
    (it.claimedBy ? ' · claimed by ' + esc(it.claimedBy) +
      (it.claimedAt ? ' ' + esc(day(it.claimedAt)) : '') : '') + '</div>';

  if (it.heldWhy) h += '<div class="blk reason held"><h4>Held — why</h4><div>' +
    esc(it.heldWhy) + '</div>' + (it.heldAt ? '<div class="when">since ' +
      esc(it.heldAt) + '</div>' : '') +
    '<div class="when">a decision, not a completion — clear it with ' +
    'tracker set ' + esc(id) + ' heldWhy=</div></div>';

  if (it.gate) h += '<div class="blk reason gated"><h4>Gated on an open question</h4>' +
    '<div><code>' + esc(it.gate) + '</code></div>' + (it.gatedAt ?
      '<div class="when">since ' + esc(it.gatedAt) + '</div>' : '') +
    '<div class="when">no gate is ever recognised as cleared by the tracker; ' +
    'clearing it is a ruling — tracker set ' + esc(id) + ' gate=</div></div>';

  if (it.openBlockers.length) h += '<div class="blk reason blocked">' +
    '<h4>Blocked by (still open)</h4><div class="chips">' +
    chipRow(it.openBlockers) + '</div></div>';
  if (it.doneBlockers.length) h += '<div class="blk"><h4>Was blocked by (done)</h4>' +
    '<div class="chips">' + chipRow(it.doneBlockers) + '</div></div>';
  if (it.blocks.length) h += '<div class="blk"><h4>Blocks</h4><div class="chips">' +
    chipRow(it.blocks) + '</div></div>';
  if (it.flags.includes('ready')) h += '<div class="blk"><h4>Claimable</h4>' +
    '<div>Nothing is holding this: not held, not gated, no open blocker. ' +
    'It is in <code>bin/tracker ready</code>.</div></div>';

  h += '<div class="blk"><h4>Notes — the audit trail</h4>' + (it.notes.length
    ? it.notes.map(noteHtml).join('')
    : '<div>No notes on this issue. A dispatch writes one, and so does a handoff.' +
      '</div>') + '</div>';

  document.getElementById('detBody').innerHTML = h;
  document.getElementById('det').classList.add('on');
  document.getElementById('scrim').classList.add('on');
  location.hash = id;
}
function closeDet(){
  document.getElementById('det').classList.remove('on');
  document.getElementById('scrim').classList.remove('on');
  if (location.hash) history.replaceState(null, '', location.pathname);
}

document.addEventListener('click', e => {
  if (e.target.id === 'clear'){
    F.state.clear(); F.eff.clear(); q = '';
    document.getElementById('q').value = ''; return render();
  }
  const j = e.target.closest('[data-jump]');
  if (j){
    const b = j.dataset.jump;
    F.state.clear(); F.state.add(b); render();
    const el = document.getElementById('b-' + b);
    if (el) el.scrollIntoView({block:'start'});
    return;
  }
  const f = e.target.closest('.f');
  if (f && f.dataset.k){
    const s = F[f.dataset.k];
    s.has(f.dataset.v) ? s.delete(f.dataset.v) : s.add(f.dataset.v);
    return render();
  }
  const v = e.target.closest('#view button');
  if (v){
    view = v.dataset.v;
    document.querySelectorAll('#view button').forEach(b => b.classList.toggle('on', b === v));
    return render();
  }
  if (e.target.closest('#theme')){
    const cur = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = cur;
    try { localStorage.entropyMachinesTheme = cur; } catch (err) { /* private mode */ }
    return;
  }
  const node = e.target.closest('[data-id]');
  if (node) return openDet(node.dataset.id);
  if (e.target.id === 'close' || e.target.id === 'scrim') closeDet();
});
document.getElementById('q').addEventListener('input', e => {
  q = e.target.value.trim().toLowerCase(); render();
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeDet();
  if (e.key === '/' && e.target.id !== 'q'){
    e.preventDefault(); document.getElementById('q').focus();
  }
});
try { if (localStorage.entropyMachinesTheme) document.documentElement.dataset.theme = localStorage.entropyMachinesTheme; }
catch (err) { /* private mode: keep the default */ }
render();
if (location.hash && IS[location.hash.slice(1)]) openDet(location.hash.slice(1));
// A deep link changed while the page is open must switch the panel.
window.addEventListener('hashchange', () => {
  const id = location.hash.slice(1);
  if (IS[id]) openDet(id);
});
// Highlight current page in sidebar
(function(){
  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  document.querySelectorAll('body>nav a[href]').forEach(function(a){
    if(a.getAttribute('href')===file) a.classList.add('cur');
  });
})();
</script>
</body></html>
"""


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
