# The workflow

One sprint, stage by stage. Each stage lists what must be true to leave it.

```
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──▶ ISSUES
```

---

## 1. Issues

The tracker is the state of the world, not the docs. Start any session by
checking it — `ready` for what is claimable, `show <id>` for the status
(done, held, gated, claimed) of anything specific, each with a reason
attached. (The full set of operations a tracker backend must support is in
`../docs/TRACKER-ADAPTER.md`.)

**Leave this stage when:** the issues to work are chosen, non-overlapping in
file scope, and none is gated on an open decision. A gated issue is not free
to pick up until whatever it is gated on resolves.

**Rules:**

- A **held** issue is decided, not forgotten. Read the hold note before calling
  it a gap.
- An issue gated on a doc unblocks when the owner ticks that doc ready.
- Two issues touching one file **serialize** — they do not run concurrently.
  Either give them to one worker or run them in sequence.

## 2. Worked

One worker per issue, each in its own worktree.

`dispatch <id> --files "…" --brief "…"` **before** spawning anything. It
refuses a non-root cwd, refuses uncommitted edits inside the worker's own
scope, flags an id the history already mentions, claims the issue, and
records the brief where other sessions can see it.

**Everything the worker needs must be in the brief.** Not because the worker
cannot reach it otherwise — subagents load every level of a project's
instructions hierarchy, and a project's other local docs may well be reachable
too — but because proximity is what gets a rule followed. Measured over 225
subagent runs on an earlier version of this workflow, a rule pasted directly
into the brief was followed 96% of the time; the same rule sitting only in the
project-level instructions file, 7%. An owner ruling that is not in the brief
is, for that worker, effectively unwritten. That is a property of prompt
position, not of what the agent technically has access to — it holds
regardless of which agent runner you're on.

**Leave this stage when:** every worker has finished or been stopped, and each
has a `HANDOFF.md` with `changed` / `found` / `assumed` / `next`.

A stopped worker is fine. A stopped worker with no handoff is a loss.

## 3. Verified

**One verifier for the sprint**, not one per worker. It gets every finished
patch as a file, applies them together in its own worktree, and sweeps: do
they coexist, does it build, are the generated files honest, do the suites
pass, does each change have a test that bites, is anything glaringly wrong,
and what did the sprint break in aggregate.

**Leave this stage when:** the verifier returns `healthy` or `healthy with
caveats`, and the caveats are understood. `not ready` goes back to stage 2.

## 4. Folded

The orchestrator, and only the orchestrator, merges.

For each change: apply to `main`; run this project's generate command
(`entropy.json`'s `generate` block — see `../docs/CONFIG.md`) and confirm
**nothing moves** (a generated file that differs means the committed bundle
does not match the committed source); then, for the risky ones, **mutate one
half of the fix at a time** and check the failure set is the one that half
owns.

Why mutation and not a re-run: replaying a worker's own revert only shows the
test notices *that* revert. A different mutation shows what the test is
pinned to. Blinding one of two code paths once reddened a small, exact subset
of the suite and left the rest green — that is what proved those tests
discriminated. Two disjoint mutations producing two disjoint failure sets is
the strongest cheap signal there is.

Then `handoff <id> --from <worktree> --verified "<what YOU ran>"` and commit.
The handoff refuses text that relays the worker instead of stating what you
ran.

**Leave this stage when:** it is committed on `main` with a `changelog.d/`
fragment, the issue is `done`, and the suites named in `entropy.json` are
green on the final tree — not on each patch separately.

**Nothing is folded while work is HELD.** The owner says when.

### The verifier blesses a combination, not each merge

The verifier's base is whatever `main` was when its sweep started. Folding is
serial and every fold moves `main`, so by the third patch of three the tree
the verifier blessed no longer exists. That is not a flaw to design around —
it is the division of labour:

- The **verifier** answers "does this sprint's work cohere and is it
  healthy", once, against one base.
- The **orchestrator** owns each individual merge, including any conflict
  resolution, and is responsible for proving its own resolution is guarded.

This is the rule, not an oversight: re-verifying after every fold would defeat
the point of a single sweep, for a gain the orchestrator's own mutation checks
already cover on the changes that matter.

**A conflict resolution is the orchestrator's own code, and needs its own
proof.** A patch once stopped applying cleanly because another change had
landed underneath it; the naive resolution left one input path unreachable.
The fix was invented at merge time, covered by no worker's test and seen by
no verifier. The orchestrator mutated it to prove it bites. Do that every
time you resolve a conflict by writing something new.

## 5. Sprint report

The sprint ends in a report the owner reads and ticks closed. What the report
looks like is up to the project; the doctrine only requires that it names the
issues the sprint delivered and the issues it opened, and gives the owner
somewhere to respond section by section.

**The report is a local HTML file in the project's docs directory** — served
by `bin/serve`, answered in the browser, saved back to disk — never published
to an external site and never loading anything from one. `bin/doclint` gates
it: run it on the report before you hand over the URL, and it refuses a doc
that references an off-machine origin or that has a section with no box to
answer in. Copy `lib/REPORT-TEMPLATE.html` to start; its look is a default,
not a rule.

**Leave this stage when:** the owner ticks the sprint-close box. That tick is
owner-only and there is no code path to it.

## 6. Back to issues

Rulings in the report become tracker issues. So does anything another
workstream surfaced. `remember --issue <id> "…"` puts a finding where the
next session will actually read it.

A ruling that lives only in a chat message is lost. A ruling that lives only
in a doc is nearly lost.

---

## Standing rules

### The clean tree is the truth

The orchestrator's checkout is usually dirty with other sessions' uncommitted
work. A worker's worktree branches from committed HEAD, so it is clean.

**When a worker reports a failure the orchestrator cannot reproduce, the
worker is right.**

Once, several workers reported the same tests failing. The orchestrator could
not reproduce it and dismissed it twice as a local artefact. The truth: a
committed fixture set was broken at HEAD — a loader had started requiring a
field none of the fixtures carried, so a fresh clone could load none of them
— and uncommitted edits in the orchestrator's own tree were masking the same
break. The green run was the artefact.

### A new rule names what enforces it

An incident that repeats after being written down gets a mechanism, not a
better note. When you add a rule here, name the wrapper, gate, refusal or CI
job that enforces it — or state plainly that nothing does.

### Work is held until the owner says merge

Finished worker output stays uncommitted in its worktree. Other workstreams
may need to land first, and an eager merge creates exactly the collision the
worktrees exist to prevent.

### Never run this project's full build in a worker or verifier

Some build or release commands rewrite committed bookkeeping — a collated
changelog, a checkpoint file — as a side effect. Check `entropy.json`'s
`changelog` block for what's collated here, and use the suites named under
`suites` instead of the full build.

### Symlink shared dependencies in every worktree

A fresh worktree starts without them. Left unlinked, a runtime resolves them
by walking up the directory tree and finds a **sibling worktree** instead —
you test someone else's code and report it as your own. Green, confident,
wrong. `entropy.json`'s `worktree.linkPaths` names what a project needs
linked (`node_modules` is the default); a preflight check (`lib/preflight-
tree.mjs` in this repo) should refuse a suite from a tree that cannot resolve
its own dependencies rather than let it run against the wrong ones.
