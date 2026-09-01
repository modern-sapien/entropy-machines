# bin/serve — the factory lights

    bin/serve [port]        # default 8787, 127.0.0.1 only

A local web server, not a CLI. The owner's surface is a browser tab: dialogue
docs with response boxes answered in place, plus a dashboard.

| Route | What |
|---|---|
| `GET /` | Dashboard — ready issues, in-flight claims, per-doc answered counts, recent events. |
| `GET /<doc>.html` | A doc from `docs.dir`, save patch and theme injected at serve time. |
| `GET /__docversion?file=…` | `{"reviews": "<hash>"}`, polled by the live-reload watcher. |
| `POST /__save?file=…` | Body `{"<data-resp>": "<answer>"}`, merged atomically. |

Everything else 404s — no listing, nothing outside `docs.dir`.

## The rule

**No report, plan or PRD is ever published to an external site, and none may
depend on one** — a doc pulling a font or stylesheet from someone else's server
breaks offline and tells that server it was opened. And every section the owner
is asked about has a box to answer in.

**`bin/doclint` enforces exactly those two things.** Run it before handing over
a URL. Exit 1 names file, line and problem for an off-machine origin in an
`href`, `src`, CSS `url()` or script literal (prose mentioning a URL passes, as
do `data:` URIs and relative paths), or for an `<h2>` with no answer box, two
boxes sharing a key, or a missing `#saveBtn` / `#responses-data`.
`data-informational` on an `<h2>` skips that section — no whole-file exemption.
Exit 2 is a refusal, not a pass: it could not read its input. **The look is not
checked** — `lib/REPORT-TEMPLATE.html` is a default, not a conformance target.

## Docs and themes

`docs.dir` (default `entropy-machines-docs/`) is created if absent; docs sit directly in
it, since the save-path check refuses any `file` containing `/`. Reports start
from `lib/REPORT-TEMPLATE.html`, PRDs from `lib/doc-template.html`, whose header
comment authoritatively describes the response-box machinery. `docs.theme` picks
a stylesheet from `lib/themes/` (`janus`, `high-contrast`, `daylight`), inlined on each
`GET` between the `entropy-machines-theme` markers; an unknown name is refused by name.

## Saving

A save endpoint taking a path is a whole-disk write primitive, so `file` is
validated on both routes: no `/`, no `..`, ends `.html`, already in `docs.dir`.
Refusals return plain 4xx JSON. A valid save merges into `#responses-data` and
the matching `<textarea>`s via temp-file-plus-`os.replace`.

**The save patch is injected on every `GET`, never written into the file** —
otherwise an older doc falls back to `showSaveFilePicker`, writing to
`~/Downloads` and leaving the reviewed file untouched. It runs in the click
capture phase with `stopImmediatePropagation`, so it wins whatever else is bound.

## Hot reload

The doc polls `__docversion` every 5s: a clean tab reloads itself, a dirty one
shows a bar instead. Typed text is never clobbered.

`reviews` is **not** a whole-file hash — your own 💾 rewrites `#responses-data`
and the answered `<textarea>`s, which would read back as an incoming reply. It
is a SHA-256 with exactly those two regions blanked. **Consequence:**
overwriting an existing answer is indistinguishable from the reader typing and
triggers no reload; land a reply as new content outside the answer regions.

## Dashboard, port, root

`GET /` uses only state already tracked: `tracker ready`; `tracker notes` through
`lib/notes.py claims --hours 24`, the same derivation `bin/dispatch` uses for its
denylist; each doc's own counts; the notes tail. An unreachable tracker says so
rather than rendering empty — unreadable and empty are different facts.

A busy port refuses with the next port to try, not a traceback. One root,
resolved via `--git-common-dir` so it is the MAIN checkout even from a linked
worktree; no environment override, so `cd` to serve another project.
