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
for the agent runner. The gates (`bin/dispatch`, `bin/handoff`, `bin/tracker`,
the hooks) are plain POSIX shell and work with any agent that can run a shell
command — that part is genuinely agnostic. **Parallel workers in isolated git
worktrees, spawned and collected automatically, is a Claude Code capability in
v1.** Another runner gets the same gates and the same doctrine, working one
issue at a time in one tree, by following `agents/isolated-worker.md` as a
plain prompt. That is a real current limit, not a rough edge that happens to
show up on other runners equally.

## The surface: a local server, not a CLI

`bin/serve` starts a small local web server and is the actual front of this
tool. Planning, open questions, and decisions happen in served HTML docs
with response boxes the owner answers in a browser — not in a chat
transcript, and not by hand-editing a tracker file. Think of it as the
factory's lights: it's how you see what the factory is doing. The terminal
is for one thing only — talking to the orchestrator agents that are
actively doing the work — not for the owner to answer questions in.

## A PRD creates issues, not the other way round

The orientation PRD — the first thing `bin/init` puts in front of you — is
the **upstream** artifact. Filling it in is what produces a project's first
issues; issues do not get worked in order to produce a PRD. Most of what
belongs in a PRD is either already known or is a call only the owner gets
to make, so answering one is normally minutes of work, not a dispatch. A
worker only gets involved for the sub-questions that are genuinely
expensive to answer — verified truth about a command or a codebase, which
has to come from running something, not from memory.

## The cycle: four commands, four roles

Once issues exist, one moves through four commands at a time, each run by a
different role, each refusing a specific mistake:

1. **`bin/dispatch <id> --files "…" --brief "…"`** — the orchestrator hands
   one scoped issue to one worker in its own git worktree. Refuses a
   dispatch from anywhere but the repo root (a session that has drifted
   gets the *wrong repo's* worktree, silently), refuses uncommitted edits
   still sitting inside the files being handed out, and refuses to overlap
   a file another live dispatch is already holding.
2. **The worker implements it**, in that worktree, and commits nothing.
   Nothing it produces is real until someone else looks at it.
3. **A verifier sweeps the whole sprint**, once, on a clean tree — not one
   verifier per worker. It is the only vantage point that can see two
   workers' changes interacting, and it reports a verdict, not a fix.
4. **`bin/handoff <id> --from <worktree> --verified "…"`** — the
   orchestrator folds verified work into `main` and is the *only* committer.
   It refuses `--verified` text that just relays what the worker claimed
   ("tests pass" is not evidence); the orchestrator has to say what it
   re-ran itself. For anything risky, that means mutating one half of a fix
   at a time and checking the failure set belongs to that half — replaying
   a worker's own revert only proves the test noticed *that* revert.

The **owner** sits outside this loop, on purpose: rules, in a served doc, on
the questions a worker flags but cannot answer for itself; says when held
work may merge; closes the sprint. That is the one step with no command
behind it — see [doctrine/ROLES.md](doctrine/ROLES.md) for why it stays
that way.

Everything above is a summary. [doctrine/WORKFLOW.md](doctrine/WORKFLOW.md)
has the cycle stage by stage, including the incidents each gate above was
built to stop happening again.

## Adopting it

Dropping this into a project is meant to write into that project's own
`AGENTS.md` (and a pointer from `CLAUDE.md`, where the runner is Claude
Code) rather than a human running a checklist — `bin/adopt` writes a small,
versioned, content-hashed managed block, never a raw overwrite, and it asks
before writing anything. `--check` reports whether the block is missing,
stale, or current; `--remove` takes out only that block, cleanly. That
script is still landing as this README is being written — the content it
will inject already exists (`lib/agent-block.md`), the script doesn't yet.
See [docs/QUICKSTART.md](docs/QUICKSTART.md), written for the agent doing
the adopting, for its current state.

## Getting started

Clone this into your project (or as it), then run `bin/init` — it writes a
minimal starter `entropy.json` and puts the orientation PRD in front of you.
[docs/QUICKSTART.md](docs/QUICKSTART.md) is written for the coding agent
doing this alongside you, not for you directly: what the repo has, how it
finds work, what it must never do, and what happens when it tries anyway.

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
