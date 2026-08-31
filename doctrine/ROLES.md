# Roles

Four roles: three agents and the owner. Every prohibition is here because
something went wrong once.

| Role | Does | Never |
|---|---|---|
| **Owner** | Rules on open questions in served docs, ticks the sprint closed, says when held work merges. | Delegates the ready tick — there is no code path to it. |
| **Worker**<br>`agents/isolated-worker.md` | One scoped issue in its own worktree: the change, its tests, its `changelog.d/` fragment, and a `HANDOFF.md` — `changed` / `found` / `assumed` / `next`. | Commits, pushes, merges, runs the full build, edits outside its scope, or touches another worktree. |
| **Verifier**<br>`agents/verifier.md` | One sweep per sprint (not per worker) on a clean tree: applies every finished patch together, builds, regenerates, runs the suites, checks each change has a test that bites. Verdict with real numbers. | Fixes, lands, commits, reviews design, edits a worker's worktree, or repeats a number it did not re-run. |
| **Orchestrator**<br>the session talking to the owner | Dispatches, folds, lands, reports, files rulings as issues. The **only committer**. | Lands held work without the owner, relays a subagent's verification as its own, or lets its cwd leave the repo root. |

**Worker, hard-won:** write `HANDOFF.md` early — a dead worker otherwise
leaves only a diff. Check `git rev-parse --git-common-dir` first — not
`--show-toplevel`, which prints the worktree's own path and cannot confirm
which repo you branched from. Symlink
`worktree.linkPaths` before running anything. Report what you did **not** run.

| Job | Agent |
|---|---|
| Implement a scoped issue | `isolated-worker` |
| Sprint verification sweep | `verifier` |
| Read-only investigation | `Explore` — no worktree cost |
| Fold, land, report, file | the orchestrator itself |

Written against Claude Code: `agents/*.md` are picked up **at session start
only**. Check your runner's equivalent.
