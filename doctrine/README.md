# The factory

How work moves through this repo: the cycle, the roles, and the rules that
exist because something went wrong once.

This directory is the home for workflow documentation. A project can keep its
own local, gitignored docs directory for product and design material
alongside it; this directory is committed, because it governs how anyone —
human or agent — is supposed to operate here.

- **[WORKFLOW.md](WORKFLOW.md)** — the cycle, stage by stage, with what must be
  true to leave each stage.
- **[ROLES.md](ROLES.md)** — who does what, and what each role must never do.

---

## The cycle

```
   ┌──────────────────────────────────────────────────────────┐
   │                                                          │
   ▼                                                          │
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──┘
(tracker)  (workers)  (verifier)  (orchestr.)  (orchestrator +
                                                 owner ticks)
```

Issues get worked. Finished work is verified as a sprint, on a clean tree,
before anything is folded. The orchestrator folds it in and lands it. The sprint
ends in a report the owner ticks. Rulings from that report — plus whatever
arrives from other workstreams — become the next issues, and round it goes.

## The one-paragraph version

**Workers** implement one scoped issue each, in isolated git worktrees, and
commit nothing. **A verifier** sweeps all of their finished output together,
once, on a clean tree, and reports whether it is healthy. **An orchestrator**
folds the verified work into `main`, re-proving anything risky by its own
mutation, and is the only committer. The orchestrator then writes the sprint
report, the owner ticks it, and the rulings in it become issues.

## Why it is shaped like this

**Verification is a sprint-level sweep, not a per-agent gate.** One verifier
across the whole sprint is cheaper than one per worker, and it is the only
vantage point that can see two changes interacting. It also keeps the
orchestrator's attention on the owner rather than on nitty-gritty re-running.

**The orchestrator still owns depth.** The verifier checks that a test exists
and plausibly bites. Proving a test is pinned to *behaviour* — by mutating one
half of a fix at a time and watching the right subset go red — stays with the
orchestrator, on the risky changes only. A subagent's proof can be vacuous in a
way that re-running it cannot reveal; only an independent mutation shows what a
test is actually pinned to.

**Nothing lands eagerly.** Finished work is held until the owner says merge,
because other workstreams may need to land first and an eager merge creates
exactly the collision the worktrees exist to prevent.

**The clean tree is the source of truth.** The orchestrator's checkout is
usually dirty with other sessions' work. A worker's worktree branches from
committed HEAD, so it is clean. When a worker reports a failure the
orchestrator cannot reproduce, **the worker is right** — see the incident in
[WORKFLOW.md](WORKFLOW.md#the-clean-tree-is-the-truth).
