#!/usr/bin/env python3
"""Review-cycle CLI for the production-plan docs.

The bookkeeping side of the workflow — status flips, version snapshots, and
STATE.md regeneration all happen here so nothing drifts by hand. Run from this
directory.

  python3 cycle.py list                       # every handle + status + ball
  python3 cycle.py resolve "<phrase>"         # handle → file (fuzzy)
  python3 cycle.py responses <handle>         # read the user's saved answers (for me to review)
  python3 cycle.py start <handle>             # mark 'in-review' (I'm on it)
  python3 cycle.py done  <handle> [label]     # mark 'open' (ball back to you) + snapshot
  python3 cycle.py set   <handle> <status>    # any status transition (open/in-review/resolved/held)
  python3 cycle.py new   <handle> <file> <title> [status]   # register a new doc
  python3 cycle.py history <handle>           # list this doc's versions
  python3 cycle.py sync                       # regenerate STATE.md + INDEX.html from manifest
"""
import json
import os
import re
import sys

import docstate as ds


def _resolve_or_die(m, phrase):
    did = ds.resolve(m, phrase)
    if did is None:
        sys.exit(f"no doc matches {phrase!r} — try `cycle.py list`")
    if did.startswith("AMBIGUOUS:"):
        sys.exit(f"{phrase!r} is ambiguous: {did.split(':',1)[1]}")
    return did


def cmd_list(m, _):
    for did, e in m["docs"].items():
        glyph, who = ds.STATUS.get(e.get("status", ""), (e.get("status", "?"), "?"))
        print(f"  {did:12} {glyph:28} ball:{who:4} v{e.get('version',0):<3} {e['file']}")


def cmd_resolve(m, args):
    print(m["docs"][_resolve_or_die(m, args[0])]["file"])


def cmd_responses(m, args):
    """Print the user's saved answers from the doc's responses-data — what I read to review."""
    did = _resolve_or_die(m, args[0])
    path = os.path.join(ds.DIR, m["docs"][did]["file"])
    src = open(path, encoding="utf-8").read()
    mm = re.search(r'<script type="application/json" id="responses-data">(.*?)</script>', src, re.S)
    data = json.loads(mm.group(1)) if mm else {}
    filled = {k: v for k, v in data.items() if isinstance(v, str) and v.strip()}
    if not filled:
        print(f"(no saved answers yet in {m['docs'][did]['file']})")
        return
    for k, v in filled.items():
        print(f"\n### [{k}]\n{v}")


def cmd_start(m, args):
    did = _resolve_or_die(m, args[0])
    ds.set_status(m, did, "in-review")
    print(f"{did} → in-review (v{m['docs'][did]['version']}). STATE.md + INDEX.html refreshed.")


def cmd_done(m, args):
    did = _resolve_or_die(m, args[0])
    label = args[1] if len(args) > 1 else "open"
    ds.set_status(m, did, "open", label)
    print(f"{did} → open, ball back to you (v{m['docs'][did]['version']}). STATE.md + INDEX.html refreshed.")


def cmd_set(m, args):
    did = _resolve_or_die(m, args[0])
    # `ready` is not a status and there is deliberately no verb for it — the
    # checkbox in the doc is the whole interface. Say so, rather than letting
    # docstate raise "unknown status" and leaving the reader to guess whether
    # that is a typo or a rule.
    if args[1] == "ready":
        sys.exit(
            "cycle.py: 'ready' is not a status and has no CLI verb.\n"
            "  It is the owner's checkbox at the top left of each PRD, and the\n"
            "  only thing that sets it is that click (docstate.OWNER_CLICK).\n"
            "  Statuses say who holds the ball: open / in-review / resolved / held.")
    ds.set_status(m, did, args[1])
    print(f"{did} → {args[1]} (v{m['docs'][did]['version']}). STATE.md refreshed.")
    if args[1] == "resolved":
        print("  A decision just locked in.")


def _open_in_serve(filename):
    """Open a doc in the running serve instance, if one is up."""
    import socket
    import webbrowser
    port = int(os.environ.get("SERVE_PORT", "8787"))
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
        s.close()
    except OSError:
        return
    webbrowser.open(f"http://localhost:{port}/{filename}")


def cmd_new(m, args):
    handle, file, title = args[0], args[1], args[2]
    status = args[3] if len(args) > 3 else "in-review"
    if handle in m["docs"]:
        sys.exit(f"{handle!r} already exists")
    m["docs"][handle] = {"file": file, "title": title, "status": status, "version": 0}
    ds.store(m)
    ds.write_state(m)
    ds.write_index(m)
    ds.render_doctracker()
    print(f"registered {handle} → {file} ({status}). STATE.md + INDEX.html + DOCS.html refreshed.")
    _open_in_serve(file)


def cmd_history(m, args):
    did = _resolve_or_die(m, args[0])
    hdir = os.path.join(ds.HISTORY, m["docs"][did]["file"])
    if not os.path.isdir(hdir):
        print("(no versions yet)")
        return
    for name in sorted(os.listdir(hdir)):
        print("  " + name)


def cmd_sync(m, _):
    ds.write_state(m)
    ds.write_index(m)
    ds.render_doctracker()
    print("STATE.md + INDEX.html + DOCS.html regenerated from manifest.json")


CMDS = {
    "list": cmd_list, "resolve": cmd_resolve, "responses": cmd_responses,
    "start": cmd_start, "done": cmd_done, "set": cmd_set, "new": cmd_new,
    "history": cmd_history, "sync": cmd_sync,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(__doc__)
        sys.exit(0 if len(sys.argv) < 2 else 1)
    ds.init()
    manifest = ds.load()
    CMDS[sys.argv[1]](manifest, sys.argv[2:])
