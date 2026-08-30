# Quickstart — for agents

This is not a tutorial for a person. If a human wants to know what this is,
point them at [../README.md](../README.md). This page is operating
instructions for a coding agent that just found this repo — vendored into a
project, or as the project itself — and needs to know what's here, how to
find work, what it must never do, and what happens when it tries anyway.

## What this actually is, in one paragraph

Four roles move one issue at a time through a fixed cycle — dispatch, work,
verify, fold — enforced by POSIX-shell gates, not by convention. Planning
and decisions happen in **served HTML docs with response boxes**
(`bin/serve`), not in a chat transcript — that is the primary surface, and
the terminal is where you talk to orchestrator agents actually doing work,
not where the owner answers questions. `bin/dispatch` / `bin/handoff` /
`bin/tracker` are the commands you, the agent, run. See
[../README.md](../README.md) and [../doctrine/](../doctrine/) for *why* it
is shaped this way — this page only tells you *what to do*.

## Step 0 — you were just cloned: set yourself up

If the project has no `entropy.json` yet, this is your first job and it is
the whole job. Run all three, in order, **from the project root** — not
from inside the harness clone. Each resolves the project from your cwd's git
repo, and a freshly cloned harness is its own git repo, so running them from
inside it adopts and inits the *harness* instead of the project. Commands
below assume the harness sits in `entropy-machines/` under the project root;
if it is vendored *at* the root, drop the prefix.

Do not stop to ask the human for permission between them. All three are
idempotent and each carries its own refusals: `adopt` replaces its managed
block in place rather than appending a second copy, `init` refuses to
overwrite an existing `entropy.json` without `--force`, `serve` refuses a
port already in use.

1. **`entropy-machines/bin/adopt --yes`** — writes the managed integration
   block (source: `lib/agent-block.md`) into the runner instruction files
   this project already has, so future sessions know the factory exists:
   `CLAUDE.md` (plus a `SessionStart` hook merged into
   `.claude/settings.json`), `AGENTS.md`, `.cursor/rules/entropy.mdc`. With
   no target named it installs into whichever of those the project already
   shows signs of; name one (`claude` / `codex` / `cursor` / `all`) to
   bypass detection. **`--yes` is not optional for you** — without it adopt
   prints a preview and waits on a `y/N` prompt, and an agent with no stdin
   to answer it counts as declining: nothing written, exit 1. Use
   `--dry-run` first if you want the preview with no side effects at all.
   Full contract in [ADOPT.md](ADOPT.md).

2. **`entropy-machines/bin/init`** — writes the starter `entropy.json`,
   gitignores `.entropy/`, drops the orientation PRD into the project's docs
   directory, and reads the tracker back before it claims success. Its real
   output is quoted verbatim under "How you find work" below — read it, the
   last two lines are instructions.

3. **`entropy-machines/bin/serve`** — **start it.** Not "mention it". It is
   a server, not a CLI: it holds the terminal until killed, so start it in
   the background. It prints the URL you are about to hand over:

   ```
   serving <project> on http://localhost:8787
   ```

   Pass a port (`bin/serve 8788`) if 8787 is already in use.

Then give the human that URL and **stop**. Do not file issues. Do not start
project work. Do not answer the orientation PRD's questions, and do not
infer them from the codebase — they are the owner's calls to make, in the
browser, and a PRD you filled in yourself produces issues nobody agreed to.
Your turn ends with the URL.

## Where things are

| Path | What it is |
|---|---|
| `entropy.json` | The project's own contract — protected paths, suites, tracker backend. Missing at a project's root means the project hasn't been oriented yet. See [CONFIG.md](CONFIG.md). |
| `bin/init` | Writes a starter `entropy.json` and drops the orientation PRD into the project's docs directory (`docs.dir` in `entropy.json`, default `entropy-docs/`). Refuses to overwrite an existing `entropy.json` without `--force`. |
| `bin/serve [port]` | The factory lights — a local web server (default port 8787), not a CLI. `GET /` is a dashboard built from what `bin/tracker` and the notes log already know; `GET /<doc>.html` serves a doc out of the configured docs directory with response boxes; `POST /__save` writes an answer back into that file on disk; open docs poll for changes and reload. Verified live (see below). |
| `bin/adopt` | Writes the managed integration block (source: `lib/agent-block.md`) into a project's `AGENTS.md`/`CLAUDE.md`/Cursor rules, bounded by hashed markers so a re-run replaces it in place. `--check` reports missing/stale/current, `--remove` deletes only its own block, and it prompts for consent unless given `--yes`. See [ADOPT.md](ADOPT.md). |
| `bin/dispatch`, `bin/handoff`, `bin/tracker` | The commands you run to move an issue through the cycle. See below. |
| `agents/isolated-worker.md`, `agents/verifier.md` | Role prompts — Claude Code agent definitions. A different runner needs to provide the same discipline manually; see the note at the top of each file. |
| `doctrine/ROLES.md` | What each role does, and must never do. |
| `doctrine/WORKFLOW.md` | The cycle, stage by stage, with what has to be true to leave each stage. |
| `docs/TRACKER-ADAPTER.md` | The six operations a tracker backend must support, if `tracker.backend` points at something other than the built-in file backend. |

## How you find work

1. **Check whether `entropy.json` exists at the project root.** If not, run
   `bin/init`. It writes a deliberately minimal starter config (empty
   `suites` — it will not fabricate a command it hasn't verified),
   gitignores `.entropy/`, drops the orientation PRD into the project's docs
   directory, and self-checks the tracker before declaring success — real
   output, run from a fresh scratch project:

   ```
   $ bin/init
   init: wrote /path/to/project/entropy.json
   init: wrote /path/to/project/entropy-docs/PRD-001-orientation.html — open it. It is the first PRD, and the
         questions in it are the ones only you can answer.
   init: tracker is live and empty — `bin/tracker ready` answers.
   init: next — run `bin/serve` and answer the PRD it opens. Filing the
         issues it produces is step one.
   ```

   `bin/init` can be run from outside its own checkout — it resolves the
   harness root from its own path and the project root by walking up from
   your cwd, so a vendored-at-root layout and a separately cloned harness
   both work.

2. **A PRD is upstream of issues, not the other way round.** Run
   `bin/serve` and hand the owner the URL it prints
   (`serving <project> on http://localhost:8787`); its open questions are
   theirs to rule on, in the browser, not yours to guess at. Verified live —
   `bin/serve` on a fresh-`init`'d project served the dashboard at `/` and
   `entropy-docs/PRD-001-orientation.html` at `/PRD-001-orientation.html`,
   both `200`, and `POST /__save` merges an answer back into the file on
   disk. Do not dispatch a worker to go guess at what belongs in a PRD.
   Once it's answered, file the issues it produces:

   ```
   bin/tracker set i-verify-toolchain \
     status=notstarted \
     title="Verify test/typecheck/build commands and complete entropy.json" \
     effort=S
   ```

   `set` auto-vivifies an issue; there is no `add`. A question the owner
   hasn't ruled on yet gets filed **gated** (a `gate=` field, not a status
   value) so it doesn't show up as claimable before it should:

   ```
   bin/tracker set i-tracker-backend \
     status=notstarted \
     title="Decide tracker.backend: file vs. adapt an existing tracker" \
     gate="PRD-001#q3"
   ```

3. **`bin/tracker ready` is the actual state of the world.** Check it
   before trusting any doc's description of what's next — it excludes
   anything held (`heldWhy` set) or gated (`gate` set), neither of which is
   a `status` value. `status` only ever holds `notstarted` / `progress` /
   `done`.

## What you must never do

- **Commit, if you're a worker or a verifier.** Only the orchestrator
  commits, and only after `bin/handoff` lands verified work.
- **Guess at a command you have not run.** `entropy.json`'s `suites` and
  `generate` fields exist so nothing here fabricates a command that
  doesn't actually work. If you didn't run it, say so — don't put it in
  `entropy.json` and don't claim it in a handoff.
- **Edit outside your declared file scope.** If a fix genuinely needs a
  file you weren't given, stop and report — don't widen your own scope to
  cover it.
- **Touch another worktree**, or run this project's full build. Some build
  or release commands rewrite committed bookkeeping (a collated changelog,
  a checkpoint file) as a side effect — use the suites named in
  `entropy.json`, not the full build.
- **Relay another agent's verification as your own.** "Tests pass" in a
  worker's `HANDOFF.md` is not evidence you can act on — re-run it
  yourself before folding.
- **Land held work.** Held is a decision, recorded with a reason, not a
  stall — it moves only when the owner says so.

## What happens when you try

These are refusals with a mechanism behind them, checked against the
current scripts — not conventions someone might forget to follow:

- **A commit with no issue id that touches a file an open dispatch is
  holding** is refused by the `commit-msg` hook
  (`lib/handoff-guard.sh`), once `bash lib/install-hooks.sh` has installed
  it — the exact message names the file and which issue is holding it.
- **`bin/dispatch`** run from anywhere but the project root, over files
  that already have uncommitted edits sitting in them, or over a file
  another live dispatch is already holding, is refused before anything is
  written — not after.
- **`bin/handoff --verified`** text that just restates what the worker
  claimed is refused. It has to be something you personally ran.
- **`bin/tracker set <id> status=held`** is refused, with a message naming
  the field to use instead (`heldWhy`).
- **A commit missing a `changelog.d/` fragment**, when
  `entropy.json`'s `changelog.enabled` is `true`, is blocked by the
  `pre-commit` hook (`lib/changelog-guard.sh`). With `changelog.enabled:
  false` — the default `bin/init` writes — that hook is a deliberate
  no-op; check which state the project is actually in before assuming
  either.

## Commands you'll actually run

Six tracker operations, no more (full contract in
[TRACKER-ADAPTER.md](TRACKER-ADAPTER.md)):

```
bin/tracker show <id>
bin/tracker notes [--issue <id>]
bin/tracker remember --issue <id> <text>
bin/tracker claim <id>
bin/tracker ready
bin/tracker set <id> <key>=<value> [<key>=<value> ...]
```

Dispatch one scoped issue to a worker, in its own worktree:

```
bin/dispatch i-verify-toolchain \
  --files "entropy.json" \
  --brief "Verify this repo's actual test/typecheck/build commands and
propose entropy.json's completion, per docs/CONFIG.md. RUN every command you
propose — don't copy one from a README. Commit nothing."
```

**Everything the worker needs has to be in the brief.** Not because it's
technically unreachable otherwise, but because of where it lands: a rule
pasted directly into the brief was followed 96% of the time across 225
subagent runs on this workflow; the same rule sitting only in a
project-level instructions file, 7%. See
[../doctrine/WORKFLOW.md](../doctrine/WORKFLOW.md#2-worked).

Land verified work — you're the only committer:

```
bin/handoff i-verify-toolchain --from <path-to-worker-worktree> \
  --verified "re-ran <what you actually ran>, matches entropy.json"
```

`--from` lifts the worker's own `changed` / `found` / `assumed` / `next`
lines out of its `HANDOFF.md`. `--verified` is never lifted — state what
*you* ran, not what the worker said it ran.

## The one thing to internalize before anything else

**A PRD is upstream.** Answering the orientation PRD produces issues; it is
never produced by discovery work someone dispatched first. If most of a
PRD's content is already known or is a call only the owner gets to make,
writing it takes minutes, not a worker. A worker only shows up for the
sub-questions that are genuinely expensive to answer — verified truth about
commands or code, which has to come from running something, not from
memory or a README.

## Current limits, stated plainly

- **Agnostic in principle, Claude-native in practice for v1.** The gates
  (`bin/dispatch`, `bin/handoff`, `bin/tracker`, the hooks) are POSIX shell
  and work with any agent that can run a shell command. Parallel workers in
  isolated git worktrees, spawned and collected automatically, is a Claude
  Code capability right now. Another runner gets the same gates and
  doctrine, working one issue at a time in one tree, manually following
  `agents/isolated-worker.md` as a prompt — not parity, a real limit.
