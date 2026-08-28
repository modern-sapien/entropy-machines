# bin/adopt — the drop-in installer

Makes the harness discoverable by a coding agent already working in the
target project, without the user hand-editing anything. Copy this harness
into (or beside) your repo, run one command, and Claude Code / Codex / Cursor
each know the factory exists and how to use it.

```
bin/adopt [claude|codex|cursor|all]   install/update (default: detect what is present)
bin/adopt --check [<target>...]        missing|stale|current per target
bin/adopt --remove [<target>...]       remove ONLY our blocks/files
bin/adopt --dry-run                    print what would happen, write nothing
bin/adopt --yes                        skip the confirmation prompt
bin/adopt prime                        print live state (used by the Claude Code hook)
```

## What it writes

| Runner | File | Profile | Extra |
|---|---|---|---|
| Claude Code | `CLAUDE.md` | minimal | `.claude/settings.json` gets a SessionStart hook |
| Codex | `AGENTS.md` | full | — |
| Cursor | `.cursor/rules/entropy.mdc` | full | file is fully **ours** — no markers |

`AGENTS.md` is the primary target — it is the real cross-tool standard.
`CLAUDE.md` gets the short pointer because Claude Code also gets the hook,
which does the job an inline command reference would otherwise have to do.

The actual text of both profiles lives in one place, **`lib/agent-block.md`**
— edit it there, not in this doc or in `bin/adopt`. Keep it short: pasted
directly into an agent's brief, a rule lands; left in an instruction file for
the agent to go read on its own, it mostly doesn't (96% vs 7%, measured on
this project). That is also why the block mostly says "run this command" —
`bin/tracker ready`, `bin/dispatch`, `bin/handoff` — rather than re-explaining
`doctrine/`.

## The hashed managed block

Design lifted from [`beads`](https://github.com/gastownhall/beads). Every
edit into a file you own is bounded by a marker carrying a version, a
profile, and a content hash:

```
<!-- BEGIN ENTROPY-MACHINES v:1 profile:minimal hash:19cc25d9 -->
...
<!-- END ENTROPY-MACHINES -->
```

The hash is over the exact rendered text between the markers. `--check`
re-renders from the current `lib/agent-block.md` and the current harness
path and compares:

- **missing** — no block found.
- **stale** — a block is present, but either its own hash doesn't match its
  body (someone hand-edited it) or the freshly-rendered hash doesn't match
  (the template changed, or the harness moved relative to the project since
  install).
- **current** — matches exactly.

Re-running install on an existing block **replaces it in place** — same
position in the file, nothing else in the file touched — never appends a
second copy. Several tools' blocks can coexist in one `AGENTS.md`; `adopt`
only ever looks for its own `ENTROPY-MACHINES` marker pair.

`--remove` deletes only the block (plus the one blank line above it and the
one newline after it, if adopt is the one that put them there) — everything
else in the file is untouched. If the block was the *only* thing in the
file, the whole file is deleted rather than left as an empty husk.

**Known limit:** removal is proven byte-identical for the common case, where
the file already ended in exactly one trailing newline before install. A
file with unusual trailing whitespace going in (no trailing newline, or
several blank lines at EOF) is not guaranteed to restore byte-for-byte —
adopt normalizes to a single trailing newline. If that matters to you, check
with `git diff` after `--remove`.

`.cursor/rules/entropy.mdc` is different: adopt owns the *whole file*, so
there's nothing to bound with markers — `--check`/`--remove` compare/delete
the entire file.

## The Claude Code SessionStart hook

`bin/adopt claude` also merges a hook into `.claude/settings.json` that runs
`<harness>/bin/adopt prime` at the start of every session. This is how state
gets served without bloating `CLAUDE.md`: `prime` prints issues ready, issues
currently dispatched-but-not-yet-handed-off, and any dialogue doc under
`planning/*.html` with unanswered questions (best-effort — see the source
for exactly what it can and can't see).

SessionStart has no single "match everything" trigger — `startup`, `resume`,
`clear`, and `compact` are four independent matchers, so adopt writes one
hook group per matcher (four groups, each running the same command). `prime`
is "current" only when all four are present with the right (absolute)
command path.

**The merge is conservative.** It parses the existing `.claude/settings.json`
as JSON, and only ever adds to or edits an entry it can positively identify
as its own (`command` ending in `/bin/adopt prime`) — every other hook in the
file, including other `SessionStart` matchers you already had, is left
exactly as it was. If the file doesn't parse as JSON, or `hooks` /
`hooks.SessionStart` isn't the shape expected, **adopt refuses and writes
nothing**, and says what it found. It does not guess.

## Consent

By default `bin/adopt` prints exactly what it is about to write — every file
path, and the full rendered block body for each block-file target — and
waits for a `y`/`N` answer before writing anything.

- `--yes` skips the prompt (for scripts/CI).
- `--dry-run` prints the same preview and exits without ever prompting or
  writing — the only way to see what would happen with zero side effects.
- Declining, or piping in nothing at all (no stdin to read), writes nothing
  and exits 1.

## Exit codes

- `install` / `remove`: `0` wrote (or nothing needed doing) · `1` declined or
  nothing to do · `2` misuse or a refusal (e.g. malformed `settings.json`).
- `--check`: `0` every requested target is `current` · `1` at least one is
  `missing`/`stale` · `2` misuse.

## Default target selection

With no target named, `--check` and `--remove` operate on all three.
`install` (no flags) detects what's already present instead: `claude` if
`CLAUDE.md` or `.claude/` exists, `cursor` if `.cursor/` exists, and `codex`
(`AGENTS.md`) if it already exists **or** nothing else was detected at all —
so a totally bare repo still gets the one file described as the real
cross-tool standard, rather than `adopt` with no arguments being a silent
no-op. Name a target explicitly (`bin/adopt all`, `bin/adopt cursor`, ...) to
bypass detection.

## `prime`'s "unanswered docs" check is a heuristic

There is no dedicated doc-status tool in this harness yet (that's a
different, separate piece of work). `prime` scans `<project>/planning/*.html`
for this harness's own dialogue-doc convention — `<div class="response"
data-resp="KEY">` markers and a `<script id="responses-data">` JSON blob of
answered keys (see `lib/doc-template.html`, `planning/serve.py`) — and counts
keys with no non-empty answer. A project with dialogue docs somewhere else,
or using a different convention, gets nothing reported here, silently — this
is deliberately best-effort and never fails the hook.
