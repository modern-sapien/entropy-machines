# Quickstart — for agents

Operating instructions for a coding agent that just found this harness. A human
who wants to know what this is should read [../README.md](../README.md).

Four roles move one issue at a time through a fixed cycle — dispatch, work,
verify, fold — enforced by POSIX-shell gates, not by convention. Planning and
decisions happen in **served HTML docs with response boxes** (`bin/serve`), not
in a chat transcript; the terminal is where you talk to the agents doing the
work. `bin/status` / `bin/tracker` / `bin/dispatch` / `bin/handoff` are the
commands you run. [../doctrine/](../doctrine/) has the *why*.

The harness is plain tracked files — `bin/`, `lib/`, `docs/`, `doctrine/`,
`hooks/`, `agents/` — committed alongside the code, like any `scripts/` directory.
No nested checkout, one git root: `git rev-parse` always answers with the
project. Paths below assume the files sit at the repo root; if they sit in a
subdirectory, prefix every command with it.

## Step 0 — no `entropy.json` yet: bootstrap

This is your first job and the whole job. Do not stop to ask permission between
the steps.

1. **Write the pointer into the project's instruction file**, as an ordinary
   edit — this is how future sessions learn the factory exists. Append it as
   its own section to whichever of `CLAUDE.md` / `AGENTS.md` the project has;
   to both if it has both, since different runners read different files and
   neither reads the other; create `AGENTS.md` (runner-neutral) plus
   `CLAUDE.md` if you are Claude Code and it has neither. Rewrite nothing
   already in the file.

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

   Replace `<path>` with the real path from the repo root, or drop the
   `<path>/` prefix if the files are at the root. Keep the block this short: a
   rule pasted into an agent's brief was followed 96% of the time on this
   workflow against 7% for one sitting in an instruction file, so the block
   names commands rather than restating what they enforce.

2. **`bin/init`.** Writes the starter `entropy.json`, adds `.entropy/` to
   `.gitignore`, copies the orientation PRD into the docs directory
   (`docs.dir`, default `entropy-docs/`), and reads the tracker back before
   claiming success. **Not idempotent:** a second run exits 2 with `init:
   REFUSED — entropy.json already exists at <path>`. That is the refusal
   working — move on rather than reaching for `--force`.

3. **Do the baseline discovery, and record only what you RAN.** `bin/init`
   writes `suites: []` on purpose; it will not guess a test command. Work out
   the toolchain from what is in the repo (`package.json`, `Makefile`,
   `go.mod`, `pyproject.toml`, CI config), **run** the candidate test /
   typecheck / build commands, and put only the ones that passed into
   `entropy.json`'s `suites`. A command that fails or does not exist is a
   finding, not an entry — a fabricated suite makes `bin/post-fold-audit` and
   the verifier report a broken command as a failing project rather than an
   unconfigured one.

   Then fill in the PRD's **"What we found in your repo"** page: five empty
   headings waiting for exactly this — language and toolchain, the commands you
   ran and what happened, codegen, worktree symlinks needed
   (`worktree.linkPaths` — `node_modules`, `.venv`, `vendor`), and the
   changelog convention if there is one. Say plainly what you could not verify.
   The open questions on later pages are the owner's calls; leave them.

4. **Start `bin/serve`.** Not "mention it". It is a server, not a CLI: it holds
   the terminal until killed, so background it. It binds `127.0.0.1` only and
   prints the URL you are about to hand over:

   ```
   serving <project> on http://localhost:8787
     docs: <project>/entropy-docs (entropy-docs)
   ```

   If the port is taken it refuses, exits 1 and names the next one to try —
   pass a port (`bin/serve 8788`). Run `bin/doclint` first: docs here are local
   files that never load anything from an external site, and it refuses one
   that does.

Give the human that URL and **stop**. Do not file issues, start project work, or
answer the PRD's open questions — a PRD you answered yourself produces issues
nobody agreed to.

## Where things are

| Path | What it is |
|---|---|
| `entropy.json` | The project's contract — protected paths, suites, tracker backend. Missing at the repo root means the project hasn't been oriented yet. See [CONFIG.md](CONFIG.md). |
| `bin/init` | Bootstrap; step 0. Refuses (exit 2) over an existing `entropy.json` unless given `--force`; an existing PRD is left alone on the same terms. Every refusal fires before any write. |
| `bin/status` | Read-only, no arguments. Issues ready, issues dispatched with no handoff recorded, docs with unanswered questions. Run it at the start of a session. |
| `bin/serve [port]` | A local web server (default 8787). `GET /` is a dashboard built from what `bin/tracker` and the notes log already know; `GET /<doc>.html` serves a doc from the docs directory with response boxes; `POST /__save` writes an answer back to disk; open docs poll and reload. See [SERVE.md](SERVE.md). |
| `bin/doclint [path…]` | Gates the docs. Refuses a doc that references an external site (`http://`, `https://`, `//host`) or that has an `<h2>` with no answer box, no `#saveBtn` or no `#responses-data`. Exit 1 names file, line and problem; exit 2 means it could not read its input. Style is not checked — copy `lib/REPORT-TEMPLATE.html` and restyle it freely. |
| `bin/dispatch`, `bin/handoff`, `bin/tracker` | The commands that move an issue through the cycle. See below. |
| `agents/isolated-worker.md`, `agents/verifier.md` | Role prompts — Claude Code agent definitions. A different runner supplies the same discipline by hand; `isolated-worker.md` says what it has to reproduce. |
| `doctrine/ROLES.md` | What each role does, and must never do. |
| `doctrine/WORKFLOW.md` | The cycle stage by stage, and what has to be true to leave each stage. |
| `docs/TRACKER-ADAPTER.md` | The six operations a tracker backend must support, if `tracker.backend` is not the built-in file backend. |

## How you find work

`bin/status` first. With no `entropy.json` it says so and names `bin/init` —
that is step 0, not work you can start.

**A PRD is upstream of issues, not the other way round.** Its open questions are
the owner's to rule on in the browser. Do not dispatch a worker to guess at what
belongs in a PRD; a worker is for sub-questions that are genuinely expensive to
answer, meaning verified truth about commands or code. Once the PRD is answered,
file the issues it produces — `set` auto-vivifies, there is no `add`:

```
bin/tracker set i-verify-toolchain status=notstarted effort=S \
  title="Verify test/typecheck/build commands and complete entropy.json"
```

A question the owner hasn't ruled on yet is filed **gated** — a `gate=` field,
not a status value — so it isn't claimable before it should be:

```
bin/tracker set i-tracker-backend status=notstarted gate="PRD-001#q3" \
  title="Decide tracker.backend: file vs. adapt an existing tracker"
```

**`bin/tracker ready` is the actual state of the world.** Check it before
trusting any doc's description of what's next: it excludes anything held
(`heldWhy` set) or gated (`gate` set), neither of which is a `status` value.
`status` only ever holds `notstarted` / `progress` / `done`.

## What you must never do

- **Commit, if you're a worker or a verifier.** Only the orchestrator commits,
  and only after `bin/handoff` lands verified work.
- **Guess at a command you have not run.** If you didn't run it, say so — don't
  put it in `entropy.json`'s `suites` or `generate`, don't claim it in a handoff.
- **Write a file another live dispatch is holding.** Your `--files` scope is a
  *denylist*, not an allowlist: what is enforced is the list of files other
  agents hold right now, which `bin/dispatch` pastes into your brief. Everything
  else is yours if the fix needs it. If the fix needs a claimed file, stop —
  don't write it, don't ship the half you were allowed to write, and name the
  file and what it must contain in `HANDOFF.md`'s `found:` line.
- **Touch another worktree**, or run this project's full build — some build and
  release commands rewrite committed bookkeeping (a collated changelog, a
  checkpoint file). Use the suites named in `entropy.json`.
- **Relay another agent's verification as your own.** "Tests pass" in a
  worker's `HANDOFF.md` is not evidence — re-run it yourself before folding.
- **Land held work.** Held is a decision recorded with a reason, not a stall.

## What happens when you try

Each of these was triggered against these scripts, not inferred from them:

- **`bin/dispatch`** run from anywhere but the project root, over files with
  uncommitted edits in them, or with the `commit-msg` hook not installed
  (`lib/install-hooks.sh`), is refused before anything is written. Overlapping
  a file another live dispatch holds is a warning, not a refusal.
- **A commit with no issue id that touches a file an open dispatch is holding**
  is refused by the `commit-msg` hook (`lib/handoff-guard.sh`) once the hooks
  are installed; the message names the file and the issue holding it. Naming
  the id satisfies that check and hands the commit to the id-keyed one, which
  then wants the handoff record.
- **`bin/handoff --verified`** text that just restates what the worker claimed
  is refused. So is a handoff carrying neither `--found` nor `--next` without
  `--clean`.
- **`bin/tracker set <id> status=held`** is refused, naming `heldWhy` instead.
- **A commit missing a `changelog.d/` fragment** is blocked by the `pre-commit`
  hook (`lib/changelog-guard.sh`) when `entropy.json`'s `changelog.enabled` is
  `true`. With `false` — the default `bin/init` writes — it prints
  `changelog-guard: changelog.enabled is false in entropy.json — skipped.` and
  passes. Check which state the project is in.

## Commands you'll actually run

Six tracker operations, no more (contract in
[TRACKER-ADAPTER.md](TRACKER-ADAPTER.md)):

```
bin/tracker show <id>
bin/tracker notes [--issue <id>]
bin/tracker remember --issue <id> <text>
bin/tracker claim <id>
bin/tracker ready
bin/tracker set <id> <key>=<value> [<key>=<value> ...]
```

Dispatch one scoped issue to a worker in its own worktree:

```
bin/dispatch i-verify-toolchain --files "entropy.json" \
  --brief "Verify this repo's actual test/typecheck/build commands and propose
entropy.json's completion, per docs/CONFIG.md. RUN every command you propose.
Commit nothing."
```

`--files` is an advisory prediction, recorded for the audit trail. Dispatch
writes `.dispatch-context/<id>.md` in the main checkout and prints a brief block
whose first line is that file's absolute path. **Paste that block into the agent
verbatim** — a rule pasted into the brief was followed 96% of the time across
224 subagent transcripts on this workflow, against 7% for the same rule sitting
only in a project-level instructions file. See
[../doctrine/WORKFLOW.md](../doctrine/WORKFLOW.md#2-worked).

Land verified work — you're the only committer:

```
bin/handoff i-verify-toolchain --interrogate                            # questions for the LIVE agent
bin/handoff i-verify-toolchain --record-interrogation --answer "..."    # one per question
bin/handoff i-verify-toolchain --from <worker-worktree> --lift          # copy its files in
# ...verify in THIS tree, then:
bin/handoff i-verify-toolchain --from <worker-worktree> \
  --verified "re-ran <what you actually ran>, matches entropy.json"
```

`--from` lifts the worker's own `changed` / `found` / `assumed` / `next` lines
out of its `HANDOFF.md`. `--verified` is never lifted — state what *you* ran.

## Current limits, stated plainly

- **`bin/handoff` cannot read `bin/dispatch`'s notes.** Dispatch and
  `lib/notes.py` write structured JSONL records; handoff still parses the older
  free-text form. Three things read as enforced and are not: `--lift` copies a
  file another dispatch is holding instead of refusing it, the interrogation
  step is never required (handoff prints "no DISPATCH note found" when there is
  one), and a recorded handoff never releases the claim, so `bin/status` keeps
  reporting the issue in flight. Read `bin/dispatch`'s overlap warning yourself
  before lifting.
- **`--lift` exits 1 on `.scratch`.** `hooks/post-checkout` symlinks a private
  `.scratch` into every worktree it makes, and `--lift` tries to copy it:
  `cp: <worktree>/.scratch is a directory (not copied)`, having copied nothing.
  Delete the symlink from the worker's worktree and rerun.
- **Agnostic in principle, Claude-native in practice for v1.** The gates
  (`bin/dispatch`, `bin/handoff`, `bin/tracker`, the hooks) are POSIX shell and
  work with any agent that can run a shell command. Parallel workers in
  isolated git worktrees, spawned and collected automatically, is a Claude Code
  capability right now. Another runner gets the same gates and doctrine,
  working one issue at a time in one tree, manually following
  `agents/isolated-worker.md` as a prompt — not parity, a real limit.
