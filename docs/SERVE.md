# bin/serve — the factory lights

    bin/serve [port]        # default 8787

A local web server, not a CLI. The owner's primary surface for this harness
is a browser tab: dialogue docs (PRDs, plans, reports) with response boxes
they answer in place, and a dashboard showing what the factory is doing
right now. The terminal is for talking to orchestrator agents doing work,
not for reading state — see `docs/QUICKSTART.md`.

## What it serves

| Route | What |
|---|---|
| `GET /` | The dashboard — ready issues, in-flight claims, per-doc answered/unanswered counts, recent tracker events. See "The dashboard" below. |
| `GET /<doc>.html` | A doc from the configured docs directory, served with its Downloads-folder save always defeated (see "Saving" below). |
| `GET /__docversion?file=<doc>.html` | `{"reviews": "<hex hash>"}` — polled by the doc's own live-reload watcher. See "Hot reload" below. |
| `POST /__save?file=<doc>.html` | Body is `{"<data-resp-key>": "<answer>", ...}`. Merged into `<doc>.html` on disk, atomically. |

Anything else 404s. There is no directory listing and no serving of files
outside the docs directory — this is not a general file server.

## Where docs live

`docs.dir` in `entropy.json`, default `entropy-docs/` (relative to the
project root; an absolute path is used as-is). `lib/config.py`'s `DEFAULTS`
has no entry for this key yet — `bin/serve` falls back to `entropy-docs`
itself when the lookup fails, rather than editing that shared file. The
directory is created if it does not exist. Docs must sit directly inside
it — no subdirectories — because the save path validation (next section)
refuses any `file` value containing `/`.

## The document contract

A doc `bin/serve` can usefully serve is built from `lib/doc-template.html`
— read that file's own header comment for the authoritative contract
(response-box shape, `data-resp` keys, the `#responses-data` block, page
structure). The short version: every question lives in
`<div class="response" data-resp="UNIQUE-KEY">` with a `<textarea>`, and
`<script type="application/json" id="responses-data">{}</script>` near the
end of `<body>` mirrors what's been saved. A doc missing that structure
still gets served, just has zero answerable questions.

## Saving

A save endpoint that accepts a path is a file-write primitive aimed at the
whole disk, so `file` is validated the same way on `POST /__save` and
`GET /__docversion`: reject anything containing `/` or `..`, or not ending
in `.html`, or not an existing file in the docs directory. Refused inputs
get a plain 4xx JSON body, not a traceback.

A valid save is merged into two places in the file — the `#responses-data`
JSON block, and each `<textarea>` whose enclosing `.response` has the
matching `data-resp` — then written with temp-file-plus-`os.replace`, so a
reader (including another request to this same server) never observes a
half-written file.

**The save patch is injected at serve time on every `GET`, unconditionally
— never written into the file.** Docs built from the current
`lib/doc-template.html` already carry their own `__disk-save-patch` script
that does the right thing (POSTs to `/__save`), but `bin/serve` does not
trust that to always be present — an older doc, or one written by hand,
still falls back to `showSaveFilePicker` / a downloaded copy, which writes
to `~/Downloads` and leaves the file under review untouched. The injected
patch runs in the click event's capture phase and calls
`stopImmediatePropagation`, so it wins regardless of what else is wired to
the save button. This is why a doc can never be served with the
Downloads-folder save still live as the only way to save.

## Hot reload

When an agent (or anyone) edits a doc on disk, an already-open tab should
pick it up without the reader having to know to hit reload — **and it must
never silently destroy text someone is mid-typing.**

Docs built from `lib/doc-template.html` already ship the client half of
this: a script that polls `GET /__docversion?file=<f>` every 5 seconds and
compares the returned `reviews` hash against what it last saw. On a change
it checks whether every textarea's current value matches what
`#responses-data` held at page load (`dirty()`):

- **Clean** (nothing unsaved) → reloads on its own.
- **Dirty** (the reader has typed something not yet saved) → shows a
  dismissable bar ("New reply on disk — you have unsaved edits. 💾 first,
  then reload.") instead of reloading. The reader's typed text is left
  alone either way.

`bin/serve`'s job is only the server half: computing `reviews` so that it
changes exactly when it should.

### Why `reviews` is not a hash of the whole file

The reader's own 💾 rewrites the `#responses-data` block and every answered
`<textarea>`. If `reviews` were a hash of the whole file, saving your own
answer would change it — the poller would read that as "a reply arrived"
and either reload for no reason or throw up the dirty-changes bar over
nothing. (This is a real, already-hit bug — see the comment above the
`__docversion` script in `lib/doc-template.html`: it used to watch a
version number for exactly this reason and got walked back after the owner
reported "I never actually see replies upon reload".)

So `reviews` is a SHA-256 of the file with two regions blanked out first:
the contents of `#responses-data`, and the inner text of every
`<textarea>`. Those are exactly the two regions `/__save` owns. What's left
changes only when something *other* than an answer round-trip touched the
file — edited prose, a restructured section, a new response box.

**Known gap, called out on purpose:** `lib/doc-template.html`'s own
`__docversion` script comment describes hashing "the folded
`<aside class="review">` blocks" — a per-reply element that does not
actually exist anywhere in that template's markup or in any doc it
produces today. That concept appears to be carried over from a sibling
project's doc tooling without the markup coming with it. Until this repo
has its own reply-box convention, an agent's reply has to land as new or
changed content *outside* the answer regions (edited discussion text, a
new section) to be picked up by hot reload — directly overwriting an
existing answered `<textarea>`'s baked value is, by design, indistinguishable
from the reader's own typing and will not trigger a reload on its own.

## The dashboard (`GET /`)

Built only from state the harness already tracks — nothing new is invented
or persisted by `bin/serve` itself:

- **Ready** — `bin/tracker ready`, as-is.
- **In flight** — `bin/tracker notes` (the full notes log) piped through
  `lib/notes.py claims --hours 24`, the identical derivation `bin/dispatch`
  uses to compute its denylist: an issue's last event is a `DISPATCH` (still
  holding its declared scope) or a `HANDOFF` (released it). This is not a
  second opinion of what's claimed — it's the same one query bin/dispatch
  already trusts.
- **Docs** — every `.html` file in the docs directory, with an
  answered/total `data-resp` count read from each file's own
  `#responses-data` block.
- **Recent events** — the tail of `bin/tracker notes`, most recent first.

If the tracker is unreachable (bad `tracker.command.bin`, etc.), each
section that depends on it says so plainly instead of silently rendering
empty — an unreadable tracker and an empty one are different facts, the
same distinction `bin/dispatch` already makes for its own claim list.

Visual standard matches the docs themselves (VS Code hc-black/hc-light):
borders separate, never background tints; focus is a ring, never a fill;
state is weight/case/color+word, never opacity alone; four type steps.

## Port

Default `8787`. `bin/serve <port>` to pick another. A port already in use
produces:

    serve: REFUSED — port 8787 is already in use.
      Another server (maybe a previous `bin/serve`) already holds it.
      Try a different port:  bin/serve 8788

not a Python traceback.

## Root

Like every other entry point: `. lib/roots.sh`, `entropy_home "$0"`,
`entropy_require_root serve`. There is ONE root — the git repository, resolved
via `--git-common-dir` so it is the MAIN checkout even from inside a linked
worktree. `ENTROPY_ROOT` names it; `ENTROPY_HOME` is only the directory this
harness's own files sit in, which is inside it. There is no environment
override for either: the harness is vendored as plain tracked files in the
repo it works on, so git always has one answer. To serve a different project,
`cd` into it.

## Verified

- A doc renders in a browser; typing an answer and clicking 💾 writes it
  into the actual file on disk (grepped), not `~/Downloads`.
- Editing a doc's content directly on disk — simulating an agent's reply —
  makes an already-open, clean tab reload and show it, and clicking the
  reply bar's Reload button picks up a change made while the tab was dirty.
- A tab with unsaved typed text is not silently clobbered by an on-disk
  change; the text survives and a bar appears instead.
- `GET /` renders real ready/in-flight/doc-count/event state seeded through
  `bin/tracker` directly.
- A busy port produces the message above, not a traceback.
- `POST /__save` refuses a `file` containing `/` or `..`, or not ending
  `.html` (400, JSON body, no traceback).
