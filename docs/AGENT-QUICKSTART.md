# Agent quickstart

This doc is for the coding agent bootstrapping and running the harness.
If you are the project owner (a human), start at [../README.md](../README.md).
The *why*: [../doctrine/](../doctrine/).

Four roles move one issue through a fixed cycle — dispatch, work, verify, fold —
enforced by shell gates, not convention. Decisions happen in served HTML docs with
response boxes, not in chat. Plain tracked files, one git root; prefix the commands
below if they sit in a subdirectory.

## Step 0 — no `entropy.json` yet

Your first job and the whole job. Don't stop for permission between steps.

1. **Point `CLAUDE.md` and/or `AGENTS.md` at it** — both if both exist, rewriting
   nothing already there:

   ```markdown
   ## entropy-machines
   Vendored at `<path>`. **Owner** decides and ticks. **Worker** does one scoped
   issue in an isolated worktree and commits nothing. **Verifier** sweeps a sprint
   once, on a clean tree. **Orchestrator** dispatches, folds, lands — the only
   committer. `<path>/bin/status` = live state, `bin/tracker ready` = find work,
   `bin/dispatch` = the gate before any writing agent, `bin/handoff` = the only way
   work lands. Doctrine: `<path>/doctrine/`.
   ```

2. **`bin/init`** — writes `entropy.json`, gitignores `.entropy/`, copies the
   orientation PRD into `docs.dir`. A second run exits 2; that refusal is working.

3. **Baseline discovery — record only what you RAN.** `init` writes `suites: []`
   rather than guess. **Run** the candidate test/typecheck/build commands and enter
   only those that passed; one that fails is a finding, not an entry. Then fill the
   PRD's "What we found in your repo" page, saying what you couldn't verify. Leave
   the open questions — the owner's.

4. **Start `bin/serve`** — actually start it, backgrounded; it holds the terminal.
   Binds `127.0.0.1` and prints its URL. Run `bin/doclint` first.

Hand over that URL and **stop**. A PRD you answered yourself produces issues nobody
agreed to.

## The commands

```
bin/status                                        # read-only: ready, in flight, unanswered
bin/tracker show|notes|remember|claim|ready|set   # six operations, no more
bin/dispatch <id> --files "…" --brief "…"         # the gate; paste its block verbatim
bin/handoff <id> --from <worktree> --verified "<what YOU ran>"
bin/serve [port] · bin/doclint [path…]
```

`tracker ready` is the state of the world, not a doc's account of it: it excludes
held (`heldWhy`) and gated (`gate`), neither a status value — `status` holds only
`notstarted`/`progress`/`done`. `set` auto-vivifies; there is no `add`.
`dispatch --files` is advisory; what's enforced is the denylist of files other
agents hold, pasted into your brief. `handoff --from` lifts the worker's four
lines; `--verified` never is. See [CONFIG.md](CONFIG.md), [SERVE.md](SERVE.md),
[TRACKER-ADAPTER.md](TRACKER-ADAPTER.md).

## Never

Commit, unless you are the orchestrator landing via `handoff`. Claim a command you
did not run. Write a file another live dispatch holds — stop, ship nothing, name it
in `HANDOFF.md`'s `found:`. Touch another worktree, or run the full build (it
rewrites committed bookkeeping — use `suites`). Relay another agent's verification.
Land held work.

## Limits

- **`handoff` cannot read `dispatch`'s notes** (JSONL vs. the older free-text
  form), so `--lift` copies a held file instead of refusing, interrogation is never
  required, and a recorded handoff never releases the claim. Read dispatch's
  overlap warning yourself.
- **`--lift` exits 1 on `.scratch`** — delete that symlink from the worktree, rerun.
- **Claude-native in practice.** The gates are POSIX shell; automatic parallel
  workers in isolated worktrees is a Claude Code capability. Another runner gets
  the same gates one issue at a time, using `agents/isolated-worker.md` by hand.
- **Isolation can silently not happen.** `isolation: worktree` branches the repo the
  *calling session's cwd* is in, so driving one project from a shell in another
  hands every worker the wrong repo — or one shared checkout where agents see each
  other's edits. Workers check `git rev-parse --git-common-dir` (never
  `--show-toplevel`); orchestrators verify cwd, keep scopes disjoint and never `git
  add -A` while a lane is live. No gate covers it —
  [../doctrine/WORKFLOW.md](../doctrine/WORKFLOW.md).
