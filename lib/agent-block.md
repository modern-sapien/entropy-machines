<!--
  lib/agent-block.md — the ONE source of the text bin/adopt injects into a
  user's CLAUDE.md / AGENTS.md / Cursor rules file. Editable here without
  touching bin/adopt; bin/adopt computes the content hash from whatever is
  between the section markers below, so editing this file is how you bump
  what --check calls "stale" on every already-adopted project.

  FORMAT bin/adopt PARSES (not rendered markdown structure — a machine
  format that happens to be HTML-comment-safe inside a .md file). Every
  directive below is shown INDENTED ON PURPOSE: bin/adopt only recognizes a
  directive at COLUMN 0, so this documentation cannot be parsed as content.
  Keep it that way — a template in this project once documented its own
  machine format literally and every reader then matched the documentation.

    @@profile:<name>
    <raw template text, one profile>
    @@profile:<name>
    <raw template text, another profile>
    @@fragment:<name>
    <raw template text, substituted INTO a profile, conditionally>
    @@end

  Placeholders substituted at install time:
    {{HARNESS_PATH}}      path from the PROJECT root to the harness root
                          (ENTROPY_HOME), relative, POSIX-slash, when the
                          harness lives inside the project; the absolute path
                          when it lives outside it (a sibling clone — where a
                          relative path would leak the author's home directory
                          into a file the user commits). "." when the harness
                          IS the project root — kept explicit ("./bin/tracker")
                          rather than bare, so the rendered command is
                          unambiguous regardless of layout.
    {{HARNESS_RESOLVE}}   the harness-resolve fragment below, but ONLY in the
                          nested/vendored layout ({{HARNESS_PATH}} relative and
                          not "."). Empty in every other layout. See the
                          fragment's own note for why it exists. bin/adopt
                          collapses the blank line it leaves behind, so a
                          profile can put it on its own paragraph either way.

  KEEP EACH PROFILE SHORT. Measured on this project: a rule pasted into an
  agent's brief was followed 96% of the time; the same rule left in an
  instruction file, 7%. This file IS that instruction file for three tools —
  it must mostly say "run this command, it will tell you what to do," not
  restate doctrine/ inline.

  minimal — for runners with a session-start hook (Claude Code today: this
  same profile also gets `bin/adopt claude`'s SessionStart hook, which prints
  live state every session — ready/in-flight issues, unanswered docs — so the
  block itself does not need to). A pointer, nothing else.

  full — for runners with no hook (Codex, Cursor). No session start pushes
  state at them, so the block carries the command syntax inline instead of
  just naming the commands.
-->
@@profile:minimal
The **entropy-machines** factory is vendored at `{{HARNESS_PATH}}`. A
SessionStart hook already prints live state (ready/in-flight issues,
docs with unanswered questions) at the start of every session — you do not
need to go looking for it yourself.

{{HARNESS_RESOLVE}}

Four roles, one line each: **Owner** decides and ticks. **Worker** implements
one scoped issue in an isolated worktree and commits nothing. **Verifier**
sweeps a sprint's finished work once, on a clean tree, and never lands.
**Orchestrator** dispatches, folds, lands and reports — the only committer.

`{{HARNESS_PATH}}/bin/tracker ready` finds work. `{{HARNESS_PATH}}/bin/dispatch`
is the gate before dispatching a writing agent. `{{HARNESS_PATH}}/bin/handoff`
is the only way work lands. Never commit on a worker's behalf.

Full doctrine, only if you need more than this: `{{HARNESS_PATH}}/doctrine/`.
@@profile:full
The **entropy-machines** factory is vendored at `{{HARNESS_PATH}}`. No
session-start hook runs here, so check live state yourself at the start of a
session — `{{HARNESS_PATH}}/bin/tracker ready` below is cheap and answers fast.

{{HARNESS_RESOLVE}}

Four roles, one line each: **Owner** decides and ticks. **Worker** implements
one scoped issue in an isolated worktree and commits nothing. **Verifier**
sweeps a sprint's finished work once, on a clean tree, and never lands.
**Orchestrator** dispatches, folds, lands and reports — the only committer.

Commands:

```
{{HARNESS_PATH}}/bin/tracker ready
    List claimable issues (no open blockers, not held, not gated).
{{HARNESS_PATH}}/bin/dispatch <id> --files "<paths>" --brief "<one line>"
    The gate before dispatching a writing agent. Run it first, always.
{{HARNESS_PATH}}/bin/handoff <id> --from <worktree> --verified "<what you re-ran>"
    The only way work lands. Never commit on a worker's behalf.
```

Full doctrine, only if you need more than this: `{{HARNESS_PATH}}/doctrine/`.
@@fragment:harness-resolve
If `{{HARNESS_PATH}}/` is not there, you are in a linked git worktree: the
harness is a gitignored nested clone, so no worktree ever contains it. Get the
real one with `EM="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)/{{HARNESS_PATH}}"`
and run `$EM/bin/...` in place of every `{{HARNESS_PATH}}/bin/...` below.
@@end
