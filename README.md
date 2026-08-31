# entropy-machines

You answer questions in a browser. Those answers become tracked issues. Agents
build what you decided, in isolated worktrees, and nothing lands until it is
independently verified. That is the whole loop.

```
  YOU ANSWER A PRD
        │
        ▼
  ISSUES FILED ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT
        ▲                                                     │
        └─────────────────────────────────────────────────────┘
```

## How it works

1. **`bin/init`** writes a starter config and opens a PRD — a local HTML doc
   with questions only you can answer.
2. **`bin/serve`** serves it at localhost. You open the URL, read the options,
   type your answers, hit 💾. Your answers are saved to disk, not to a server.
3. Your answers become **tracker issues** — each one scoped, dispatchable.
4. An **orchestrator** (your coding agent) dispatches issues to **workers** —
   each in its own git worktree, unable to see or corrupt the others.
5. A **verifier** sweeps all finished work on a clean tree. The orchestrator
   folds verified work in and is the only committer.
6. A **sprint report** (another served HTML doc) is where you review what
   landed and what is still open.

**A PRD creates issues, not the other way round.** The questions in a PRD are
the decisions only you can make. Everything downstream — the issues, the scoping,
the agent work — follows from your answers.

Four roles: [ROLES.md](doctrine/ROLES.md). The cycle stage by stage:
[WORKFLOW.md](doctrine/WORKFLOW.md).

## Getting started

    npx entropy-machines init          # writes entropy.json + your first PRD
    bin/serve                          # open the URL it prints, answer the PRD

Or clone this repo, copy the six directories (`bin/ lib/ docs/ doctrine/ hooks/
agents/`) into your project, and commit. No Node after the initial copy.

Point your coding agent at [AGENT-QUICKSTART.md](docs/AGENT-QUICKSTART.md) —
it handles the bootstrap (wiring up CLAUDE.md, running init, starting serve,
handing you the URL).

## Reference

[CONFIG.md](docs/CONFIG.md) — every knob ·
[SERVE.md](docs/SERVE.md) — the server contract ·
[TRACKER-ADAPTER.md](docs/TRACKER-ADAPTER.md) — bring your own tracker ·
[NPM.md](docs/NPM.md) — the npm wrapper

## Requirements

Git, a POSIX shell, Python 3. Your project can be written in anything. Automatic
parallel workers in isolated worktrees is a
[Claude Code](https://claude.com/claude-code) capability — another runner gets
the same gates one issue at a time.

## License

Copyright (c) 2026 modern-sapien. [Elastic License 2.0](LICENSE) — use, copy,
modify and distribute, including inside a company; no selling it or offering it
as a hosted service without permission. Source-available, not OSI-approved.
