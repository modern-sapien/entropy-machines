# entropy-machines

Escape the terminal. Enter your factory floor.

You create PRDs, design with agents, and once your decisions are complete,
issues are generated from those PRDs. Worker agents execute each issue in
isolated worktrees — unable to see or corrupt each other's work. A verifier
sweeps everything on a clean tree. An orchestrator folds verified work in
and is the only committer. You review what landed in a sprint report, and
the cycle repeats.

**A PRD creates issues, not the other way round.** The questions in a PRD are
the decisions only you can make. Everything downstream follows from your answers.

```
  YOU ANSWER A PRD
        │
        ▼
  ISSUES FILED ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT
        ▲                                                     │
        └─────────────────────────────────────────────────────┘
```

## Get started

```sh
npx entropy-machines start
```

This vendors the harness into your git repo (if it hasn't been already) and
launches a local server that opens your first PRD — a set of questions about
your project that only you can answer. Your answers are saved to disk, not to
any external service.

Once answered, those responses become tracked issues. Point your coding agent
at [AGENT-QUICKSTART.md](docs/AGENT-QUICKSTART.md) and it takes it from there.

## Four roles

| Role | Does | Never |
|---|---|---|
| **Owner** (you) | Answer PRDs in the browser, review sprint reports, tick the sprint closed | Delegate the ready tick |
| **Worker** | One scoped issue in its own worktree: the change, its tests, a handoff note | Commit, push, or edit outside its scope |
| **Verifier** | One sweep per sprint on a clean tree — breadth over depth | Fix, land, or repeat a number it didn't re-run |
| **Orchestrator** | Dispatch, fold, land, report — the only committer | Land held work without the owner, relay a worker's verification |

[ROLES.md](doctrine/ROLES.md) · [WORKFLOW.md](doctrine/WORKFLOW.md)

## Reference

[CONFIG.md](docs/CONFIG.md) — every knob ·
[SERVE.md](docs/SERVE.md) — the server contract ·
[TRACKER-ADAPTER.md](docs/TRACKER-ADAPTER.md) — bring your own tracker ·
[NPM.md](docs/NPM.md) — the npm wrapper ·
[AGENT-QUICKSTART.md](docs/AGENT-QUICKSTART.md) — for your coding agent

## Requirements

Git, a POSIX shell, Python 3. Your project can be written in anything.
Parallel workers in isolated worktrees is a
[Claude Code](https://claude.com/claude-code) capability — another runner
gets the same gates one issue at a time.

## License

Copyright (c) 2026 modern-sapien. [Elastic License 2.0](LICENSE) — use, copy,
modify and distribute, including inside a company; no selling it or offering it
as a hosted service without permission. Source-available, not OSI-approved.
