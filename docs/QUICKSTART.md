# Quickstart — for agents

This is not a tutorial for a person. If a human wants to know what this is,
point them at [../README.md](../README.md). This page is operating
instructions for a coding agent that just found this harness — vendored into
a project, or as the project itself — and needs to know what's here, how to
find work, what it must never do, and what happens when it tries anyway.

## What this actually is, in one paragraph

Four roles move one issue at a time through a fixed cycle — dispatch, work,
verify, fold — enforced by POSIX-shell gates, not by convention. Planning
and decisions happen in **served HTML docs with response boxes**
(`bin/serve`), not in a chat transcript — that is the primary surface, and
the terminal is where you talk to orchestrator agents actually doing work,
not where the owner answers questions. `bin/status` / `bin/tracker` /
`bin/dispatch` / `bin/handoff` are the commands you, the agent, run. See
[../README.md](../README.md) and [../doctrine/](../doctrine/) for *why* it
is shaped this way — this page only tells you *what to do*.

The harness is **plain tracked files in the project** — `bin/`, `lib/`,
`doctrine/`, `hooks/`, `agents/`, committed alongside the code like any
other `scripts/` directory. There is no nested checkout and there is one
git root: `git rev-parse` always answers with the project. Paths below are
written as `bin/…`, which is correct when the files are vendored at the
repo root; if they sit in a subdirectory, prefix every command with it.

## Step 0 — no `entropy.json` yet: bootstrap

If the project has no `entropy.json`, this is your first job and it is the
whole job. Do not stop to ask permission between the steps.

1. **Write the pointer into the project's instruction file**, as an ordinary
   edit — this is how future sessions learn the factory exists. Put it in
   whichever of `CLAUDE.md` / `AGENTS.md` the project already has; if it has
   both, write it into both, because different runners read different files
   and neither reads the other. If it has neither, create `AGENTS.md`
   (the runner-neutral one), plus `CLAUDE.md` if you are Claude Code. Append
   it as its own section; do not rewrite anything already in the file. Keep
   it to this — it is a pointer, not a copy of the doctrine:

   ```markdown
   ## entropy-machines

   The entropy-machines factory is vendored at `<path>` — plain tracked
   files, no nested checkout.

   Four roles, one line each: **Owner** decides and ticks. **Worker**
   implements one scoped issue in an isolated worktree and commits nothing.
   **Verifier** sweeps a sprint's finished work once, on a clean tree, and
   never lands. **Orchestrator** dispatches, folds, lands and reports — the
   only committer.

   `<path>/bin/status` prints live state: issues ready, issues in flight,
   docs with unanswered questions. `<path>/bin/tracker ready` finds work.
   `<path>/bin/dispatch` is the gate before dispatching a writing agent.
   `<path>/bin/handoff` is the only way work lands. Never commit on a
   worker's behalf.

   Full doctrine, only if you need more than this: `<path>/doctrine/`.
   ```

   Replace `<path>` with the real path from the repo root to the vendored
   files — drop the `<path>/` prefix entirely if they are at the root. This
   block is short on purpose: a rule pasted into an agent's brief was
   followed 96% of the time on this workflow, the same rule sitting in an
   instruction file 7%, so this file's job is to name commands, not to
   restate what they enforce.

2. **`bin/init`** — writes the starter `entropy.json` and puts the
   orientation PRD in the project's docs directory. **It is not idempotent:**
   a second run exits 2 with `init: REFUSED — entropy.json already exists at
   <path>`. That is the refusal working, not a failure — if the file is
   already there the project is initialised, so skip to the next step rather
   than reaching for `--force`.

3. **Do the baseline discovery, and record only what you RAN.** `bin/init`
   writes `suites: []` on purpose — it will not guess a test command. Filling
   it in is your job, and the rule is that a command you have not executed
   does not go in the file.

   Work out the language and toolchain from what is actually in the repo
   (`package.json`, `Makefile`, `go.mod`, `pyproject.toml`, CI config), then
   **run** the candidate test / typecheck / build commands and see what
   happens. Put the ones that pass into `entropy.json`'s `suites`. A command
   that fails or does not exist is a finding, not an entry — a fabricated
   suite makes `bin/post-fold-audit` and the verifier report a broken command
   as a failing project instead of an unconfigured one.

   Then fill in the PRD's **"What I found in your repo"** page — it ships with
   five empty headings waiting for exactly this: language and toolchain, the
   commands you ran and what happened, codegen, worktree symlinks needed
   (`worktree.linkPaths` — `node_modules`, `.venv`, `vendor`), and the
   changelog convention if there is one. Say plainly what you could not
   verify.

   This is discovery, not decision. You are recording facts the owner would
   otherwise have to go and look up. The open questions on the later pages —
   which suites gate a landing, what is protected, which tracker backend —
   stay untouched.

4. **`bin/serve`** — **start it.** Not "mention it". It is a server, not a
   CLI: it holds the terminal until killed, so start it in the background.
   It prints the URL you are about to hand over:

   ```
   serving <project> on http://localhost:8787
     docs: <project>/entropy-docs (entropy-docs)
   ```

   It binds `127.0.0.1` only. If the port is taken it refuses and exits 1,
   naming the next one to try — pass a port (`bin/serve 8788`).

Then give the human that URL and **stop**. Do not file issues. Do not start
project work. Do not answer the orientation PRD's open questions — filling in
what you found is step 3's job, but the questions themselves are the owner's
calls to make, in the browser, and a PRD you answered yourself produces issues
nobody agreed to. Your turn ends with the URL.

## Where things are

| Path | What it is |
|---|---|
| `entropy.json` | The project's own contract — protected paths, suites, tracker backend. Missing at the repo root means the project hasn't been oriented yet. See [CONFIG.md](CONFIG.md). |
| `bin/init` | Writes a starter `entropy.json`, adds `.entropy/` to the project's `.gitignore`, copies the orientation PRD into the docs directory (`docs.dir` in `entropy.json`, default `entropy-docs/`), and reads the tracker back before it claims success. Refuses (exit 2) if `entropy.json` already exists, unless given `--force`; an existing PRD is left alone on the same terms. Every refusal fires before any write. |
| `bin/status` | Read-only. Prints live factory state — issues ready, issues dispatched but not yet handed off, and docs in the docs directory with unanswered questions. Writes nothing and files nothing; run it at the start of a session. |
| `bin/serve [port]` | The factory lights — a local web server (default port 8787), not a CLI. `GET /` is a dashboard built from what `bin/tracker` and the notes log already know; `GET /<doc>.html` serves a doc out of the configured docs directory with response boxes; `POST /__save` writes an answer back into that file on disk; open docs poll for changes and reload. See [SERVE.md](SERVE.md). |
| `bin/dispatch`, `bin/handoff`, `bin/tracker` | The commands you run to move an issue through the cycle. See below. |
| `agents/isolated-worker.md`, `agents/verifier.md` | Role prompts — Claude Code agent definitions. A different runner needs to provide the same discipline manually; see the note at the top of each file. |
| `doctrine/ROLES.md` | What each role does, and must never do. |
| `doctrine/WORKFLOW.md` | The cycle, stage by stage, with what has to be true to leave each stage. |
| `docs/TRACKER-ADAPTER.md` | The six operations a tracker backend must support, if `tracker.backend` points at something other than the built-in file backend. |

## How you find work

1. **`bin/status` first.** One read-only command, no arguments: how many
   issues are ready, which issues are dispatched and not yet handed off, and
   which served docs still have unanswered questions. If the project has no
   `entropy.json` it says so and names `bin/init` — that is Step 0 above,
   not work you can start.

2. **`bin/init` if there is no `entropy.json`.** It writes a deliberately
   minimal starter config (empty `suites` — it will not fabricate a command
   it hasn't verified) and self-checks the tracker before declaring success.
   Real output, run from a fresh scratch project:

   ```
   $ bin/init
   init: wrote /path/to/project/entropy.json
   init: wrote /path/to/project/entropy-docs/PRD-001-orientation.html — open it. It is the first PRD, and the
         questions in it are the ones only you can answer.
   init: tracker is live and empty — `bin/tracker ready` answers.
   init: next — run `bin/serve` and answer the PRD it opens. Filing the
         issues it produces is step one.
   ```

   The last two lines are instructions. A second run refuses instead of
   rewriting anything.

3. **A PRD is upstream of issues, not the other way round.** Run
   `bin/serve` and hand the owner the URL it prints
   (`serving <project> on http://localhost:8787`); its open questions are
   theirs to rule on, in the browser, not yours to guess at. Do not dispatch
   a worker to go guess at what belongs in a PRD. Once it's answered, file
   the issues it produces:

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

4. **`bin/tracker ready` is the actual state of the world.** Check it
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
  (`lib/handoff-guard.sh`), once `lib/install-hooks.sh` has installed
  it — the exact message names the file and which issue is holding it.
- **`bin/dispatch`** run from anywhere but the project root, over files
  that already have uncommitted edits sitting in them, or with the
  `commit-msg` hook not installed, is refused before anything is written —
  not after. Overlapping a file another live dispatch is already holding is
  a warning at dispatch and a refusal at `bin/handoff --lift`.
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
