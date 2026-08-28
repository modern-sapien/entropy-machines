# entropy-machines

A workflow for running coding agents on a real codebase without letting them
corrupt each other's work or land things nobody proved.

It is four roles, a handful of gates that refuse the mistakes that have
actually happened, and one idea: **an agent's claim that a test passes is not
evidence, and the harness should be built as if you know that.**

```
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──┐
   ▲                                                          │
   └──────────────────────────────────────────────────────────┘
```

**Workers** implement one scoped issue each, in isolated git worktrees, and
commit nothing. **A verifier** sweeps all of their finished output together,
once, on a clean tree. **An orchestrator** folds the verified work in, re-proving
anything risky by its own mutation, and is the only committer. The **owner**
rules on decisions and closes the sprint.

Read [doctrine/WORKFLOW.md](doctrine/WORKFLOW.md) for the cycle stage by stage
and [doctrine/ROLES.md](doctrine/ROLES.md) for who may do what.

## Why it is shaped this way

Most of the rules here exist because something went wrong once. Two agents
landed changes in one file and had to be hand-split. One ran `git stash` while
another was mid-edit. A worker's test suite resolved its dependencies out of a
sibling worktree and reported that tree's results as its own. A "regression
guard" passed on the unfixed code.

The rules that survived are the ones with a mechanism behind them. A rule with
nothing enforcing it is a note, and notes do not stop the incident from
recurring — that is the single most expensive thing this codebase learned.

## What is actually different here

**Verification is a sprint-level sweep, not a per-agent gate.** One verifier
across the whole sprint is cheaper than one per worker, and it is the only
vantage point that can see two changes interacting.

**Proof is by mutation, not by re-running.** Replaying a worker's own revert
only shows the test notices *that* revert. Blinding one half of a fix at a time
and checking that the failure set is the one that half owns is what shows a
test is pinned to behaviour. `lib/fail-first.mjs` does this, and CI can require
it. It cannot tell you an assertion is meaningful — someone still reads it.

**Nothing lands eagerly.** Finished work is held until the owner says merge.

## Requirements

Git, a POSIX shell, Python 3, and Node. Your *project* can be written in
anything — every language- and toolchain-specific value lives in
[`entropy.json`](docs/CONFIG.md), not in the harness.

The reference implementation targets [Claude Code](https://claude.com/claude-code)
for the agent runner. The workflow does not depend on it; see
[agents/](agents/) for what a different runner would have to provide.

## Getting started

[docs/QUICKSTART.md](docs/QUICKSTART.md) — install, configure, dispatch one
agent, land it.

- [docs/CONFIG.md](docs/CONFIG.md) — every knob, and the rule that a new
  hardcoded path in `bin/` is a bug.
- [docs/TRACKER-ADAPTER.md](docs/TRACKER-ADAPTER.md) — the six operations the
  harness needs from an issue tracker. Bring your own, or use the built-in.

## Status

Extracted from a private repo where it had been in daily use, and generalized.
The incidents in the doctrine are real; the project they happened to is not
described. Expect rough edges in the places where "our repo" was load-bearing
and is now a config key.

## License

[Elastic License 2.0](LICENSE). You may use, copy, modify and distribute it,
including inside a company. You may not sell it or offer it to third parties as
a hosted or managed service without permission. This is a source-available
license, not an OSI-approved open source license.
