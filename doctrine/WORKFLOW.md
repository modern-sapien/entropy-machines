# The workflow

One sprint, stage by stage. Each stage lists what must be true to leave it.

```
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──▶ ISSUES
```

---

## 1. Issues

The tracker is the state of the world, not the docs. Start any session with
`scripts/tracker orient` — it prints what is done, held, gated, claimed and
ready, with a reason attached to each.

**Leave this stage when:** the issues to work are chosen, non-overlapping in
file scope, and none is gated on an open decision. `orient` prints gated issues
under GATED ON OPEN DESIGN — those are not free to pick up.

**Rules:**

- A **held** issue is decided, not forgotten. Read the hold note before calling
  it a gap.
- An issue gated on a doc unblocks when the owner ticks that doc ready.
- Two issues touching one file **serialize** — they do not run concurrently.
  Either give them to one worker or run them in sequence.

## 2. Worked

One worker per issue, each in its own worktree.

`scripts/dispatch <id> --files "…" --brief "…"` **before** spawning anything. It
refuses a non-root cwd, refuses uncommitted edits inside the worker's own scope,
flags an id git log already mentions, claims the issue, and records the brief
where other sessions can see it.

**Everything the worker needs must be in the brief.** Not because the worker
cannot reach it — subagents DO load `CLAUDE.md`, and `post-checkout` symlinks
`planning-docs/` into the worktree — but because proximity is what gets a rule
followed. Measured over 225 subagent runs here, a rule pasted into the brief was
followed 96% of the time; the same rule sitting in `CLAUDE.md`, 7%. An owner
ruling that is not in the brief is, for that worker, effectively unwritten.

**Leave this stage when:** every worker has finished or been stopped, and each
has a `HANDOFF.md` with `changed` / `found` / `assumed` / `next`.

A stopped worker is fine. A stopped worker with no handoff is a loss.

## 3. Verified

**One verifier for the sprint**, not one per worker. It gets every finished
patch as a file, applies them together in its own worktree, and sweeps: do they
coexist, does it build, are the generated files honest, do the suites pass, does
each change have a test that bites, is anything glaringly wrong, and what did
the sprint break in aggregate.

**Leave this stage when:** the verifier returns `healthy` or `healthy with
caveats`, and the caveats are understood. `not ready` goes back to stage 2.

## 4. Folded

The orchestrator, and only the orchestrator, merges.

For each change: apply to `main`; run `npm run gen` and confirm **nothing
moves** (a generated file that differs means the committed bundle does not match
the committed source); then, for the risky ones, **mutate one half of the fix at
a time** and check the failure set is the one that half owns.

Why mutation and not a re-run: replaying a worker's own revert only shows the
test notices *that* revert. A different mutation shows what the test is pinned
to. Blinding one of two code paths reddened exactly 3 of 25 tests and left the
rest green — that is what proved those tests discriminated. Two disjoint
mutations producing two disjoint failure sets is the strongest cheap signal
there is.

Then `scripts/handoff <id> --from <worktree> --verified "<what YOU ran>"` and
commit. The handoff refuses text that relays the worker instead of stating what
you ran.

**Leave this stage when:** it is committed on `main` with a `changelog.d/`
fragment, the issue is `done`, and the suites are green on the final tree — not
on each patch separately.

**Nothing is folded while work is HELD.** The owner says when.

### The verifier blesses a combination, not each merge

The verifier's base is whatever `main` was when its sweep started. Folding is
serial and every fold moves `main`, so by the third patch of three the tree the
verifier blessed no longer exists. That is not a flaw to design around — it is
the division of labour:

- The **verifier** answers "does this sprint's work cohere and is it healthy",
  once, against one base.
- The **orchestrator** owns each individual merge, including any conflict
  resolution, and is responsible for proving its own resolution is guarded.

Confirmed as the rule by the owner, 2026-08-22 (build-0822-factory, `s-factory`).
The alternative — re-verify after every fold — is slower and would defeat the
point of a single sweep.

**A conflict resolution is the orchestrator's own code, and needs its own
proof.** On 2026-08-22 a `select_option` patch stopped applying because a
`type-target.ts` guard had landed underneath it; the naive resolution left the
feature unreachable. The fix — exempting `HTMLSelectElement` from that guard —
was invented at merge time, covered by no worker's test and seen by no
verifier. The orchestrator mutated it to prove it bites. Do that every time you
resolve a conflict by writing something new.

## 5. Sprint report

The sprint ends in a report the owner ticks. Built from
`planning-docs/feature-guidance/production-plan/REPORT-TEMPLATE.html`,
registered with `cycle.py new`, and it must pass `reportlint.py` — a citation
band naming the issues it delivers and opens, and a response box per section.

**Leave this stage when:** the owner ticks the sprint-close box. That tick is
owner-only and there is no code path to it.

## 6. Back to issues

Rulings in the report become tracker issues. So does anything another workstream
surfaced. `scripts/tracker remember "…" --issue <id>` puts a finding where the
next session will actually read it.

A ruling that lives only in a chat message is lost. A ruling that lives only in
a doc is nearly lost.

---

## Standing rules

### The clean tree is the truth

The orchestrator's checkout is usually dirty with other sessions' uncommitted
work. A worker's worktree branches from committed HEAD, so it is clean.

**When a worker reports a failure the orchestrator cannot reproduce, the worker
is right.**

On 2026-08-22 three workers reported two Go tests failing. The landing session
could not reproduce it and dismissed it twice as a local artefact. The truth:
all 11 committed guides were broken at HEAD — they had no `intent` and the
loader now required one, so on a fresh clone `janus run` could load none of
them — and uncommitted edits in the landing session's tree were masking it. The
green run was the artefact.

### A new rule names what enforces it

An incident that repeats after being written down gets a mechanism, not a better
note. When you add a rule here, name the wrapper, gate, refusal or CI job that
enforces it — or state plainly that nothing does.

### Work is held until the owner says merge

Finished worker output stays uncommitted in its worktree. Other workstreams may
need to land first, and an eager merge creates exactly the collision the
worktrees exist to prevent.

### Never `npm run build` in a worker or verifier

It rewrites `docs/CHANGELOG.md` and `docs/.qa-checkpoint`.

### Symlink `node_modules` in every worktree

A worktree has none, so node walks up and resolves out of a **sibling worktree**
— you test someone else's code and report it as your own. Green, confident,
wrong. `scripts/preflight-tree.mjs` refuses a suite from a tree that cannot
resolve its own dependencies.
