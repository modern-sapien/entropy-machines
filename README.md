# entropy-machines

A workflow for running coding agents on a real codebase without letting them
corrupt each other's work or land things nobody proved. Four roles, a handful of
gates that refuse mistakes that actually happened, and one idea: **an agent's
claim that a test passes is not evidence, and the harness should be built as if
you know that.**

```
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──┐
   ▲                                                          │
   └──────────────────────────────────────────────────────────┘
```

**Workers** implement one scoped issue each, in isolated git worktrees, and
commit nothing. **A verifier** sweeps all their finished output together, once,
on a clean tree. **An orchestrator** folds verified work in, re-proving anything
risky by its own mutation, and is the only committer. The **owner** rules on
decisions and closes the sprint — the one step with no command behind it.
[WORKFLOW.md](doctrine/WORKFLOW.md) has the cycle stage by stage;
[ROLES.md](doctrine/ROLES.md), who may do what.

## What's different

**Verification is a sprint-level sweep, not a per-agent gate** — cheaper, and
the only vantage point that can see two changes interacting.

**Proof is by mutation, not re-running.** Replaying a worker's own revert only
shows the test noticed *that* revert; blinding one half of a fix and checking
the failure set is the one that half owns is what shows a test is pinned to
behaviour. `lib/fail-first.mjs` does it and CI can require it.

**The surface is a local server, not a CLI** — decisions happen in served HTML
docs the owner answers in a browser. **A PRD creates issues, not the other way
round.**

Every rule exists because something went wrong once, and a rule with nothing
enforcing it is a note. So `bin/dispatch` refuses a non-root cwd (a drifted
session silently gets the *wrong repo's* worktree), uncommitted edits in the
files being handed out, and a missing `commit-msg` hook; `bin/handoff` refuses
`--verified` text that merely relays the worker.

## Getting it into your project

Vendored as **plain tracked files** — `bin/ lib/ docs/ doctrine/ hooks/ agents/`
— committed alongside your code the way a repo carries `scripts/`. No nested
checkout, no submodule, one git root.

    npx entropy-machines init [--dir <path>]     # Node for this step, never again

Or clone this repo, copy those six directories in, and commit — no Node.

Then tell your coding agent to read [QUICKSTART.md](docs/QUICKSTART.md) and
bootstrap. It points your `CLAUDE.md` / `AGENTS.md` at the harness, runs
`bin/init` (starter [`entropy.json`](docs/CONFIG.md) plus the orientation PRD),
starts `bin/serve`, and hands you a URL. The PRD's questions are yours;
`bin/status` is the read-only view later.

[CONFIG.md](docs/CONFIG.md) — every knob · [SERVE.md](docs/SERVE.md) — the
server's contract · [TRACKER-ADAPTER.md](docs/TRACKER-ADAPTER.md) — bring your
own tracker · [NPM.md](docs/NPM.md) — the wrapper.

## Requirements and limits

Git, a POSIX shell, Python 3; your *project* can be written in anything. The
gates work with any agent that can run a shell command, but **automatic parallel
workers in isolated worktrees is a [Claude Code](https://claude.com/claude-code)
capability in v1** — another runner gets the same gates one issue at a time.

**One known gap**, since a gate that reads as enforced and isn't is the failure
this project is about: `bin/dispatch` writes structured JSON notes, `bin/handoff`
still parses the older free-text form, so `--lift` doesn't refuse a held file and
a recorded handoff doesn't release the claim. Read dispatch's overlap warning
yourself. Extracted from a private repo where it was in daily use; the incidents
are real, the project they happened to is not described.

## License

Copyright (c) 2026 modern-sapien. [Elastic License 2.0](LICENSE) — use, copy,
modify and distribute, including inside a company; no selling it or offering it
as a hosted service without permission. Source-available, not OSI-approved.
