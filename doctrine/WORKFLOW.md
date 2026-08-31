# The workflow

```
ISSUES ──▶ WORKED ──▶ VERIFIED ──▶ FOLDED ──▶ SPRINT REPORT ──▶ ISSUES
```

## 1. Issues
The tracker is the state of the world, not the docs (`../docs/TRACKER-ADAPTER.md`).
**Leave when:** issues are chosen, non-overlapping in file scope, none gated on an
open decision. Held means decided, not forgotten. Two issues on one file serialize.

## 2. Worked
One worker per issue, each in its own worktree. `dispatch <id> --files "…" --brief
"…"` **before** spawning anything — it refuses a non-root cwd, refuses uncommitted
edits inside the worker's scope, claims the issue, records the brief.
**Everything the worker needs goes in the brief:** over 225 subagent runs a rule
pasted into the brief was followed 96% of the time, the same rule left in the
project instructions file 7%. Prompt position, not access.
**Leave when:** every worker has finished or stopped *with* a `HANDOFF.md`. A
stopped worker is fine; one with no handoff is a loss.

## 3. Verified
One verifier for the sprint. It gets every finished patch as a file and sweeps them
together. **Leave when:** `healthy` or `healthy with caveats` and the caveats are
understood. `not ready` goes back to stage 2.

## 4. Folded
The orchestrator, and only the orchestrator, merges. Per change: apply to `main`;
run `generate` and confirm **nothing moves**; for the risky ones **mutate one half
of the fix at a time** and check the failure set is the one that half owns —
replaying a worker's own revert only proves the test noticed *that* revert. Then
`handoff <id> --from <worktree> --verified "<what YOU ran>"` and commit.
**Leave when:** committed on `main` with a fragment, the issue `done`, suites green
**on the final tree** — not on each patch. Nothing is folded while work is HELD.
Because folding is serial, the verifier blessed a combination, not each merge: **a
conflict resolution is the orchestrator's own code and needs its own proof.**

## 5. Sprint report
Names the issues delivered and the issues opened, and gives the owner somewhere to
respond section by section. **A local HTML file in the project's docs directory** —
served by `bin/serve`, answered in the browser, saved back to disk; never published
to an external site, never loading from one. `bin/doclint` gates that plus
answerability. **Leave when:** the owner ticks the sprint closed — no code path.

## 6. Back to issues
Rulings become tracker issues. `remember --issue <id> "…"` puts a finding where the
next session reads it. A ruling living only in chat is lost; only in a doc, nearly.

## Standing rules

### The clean tree is the truth
A worker's worktree branches from committed HEAD; the orchestrator's checkout is
dirty. **When a worker reports a failure the orchestrator cannot reproduce, the
worker is right.** Dismissing that once hid a fixture set broken at HEAD.

- **A new rule names what enforces it** — wrapper, gate, refusal or CI job, or say
  plainly that nothing does.
- **Work is held until the owner says merge.**
- **Never run the full build in a worker or verifier** — release commands rewrite
  committed bookkeeping. Use `entropy.json`'s `suites`.
- **Symlink `worktree.linkPaths` in every worktree.** Unlinked, a runtime walks up
  and resolves a *sibling worktree* — you test someone else's code and report it as
  your own. Green, confident, wrong.
