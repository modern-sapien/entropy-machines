# Roles

Four roles. Three are agents; one is the owner. Each is defined as much by what
it must **not** do as by what it does — every prohibition below is here because
something went wrong once.

---

## Owner

Decides. Ticks. Sets priority and scope.

**Does:** rules on open questions in dialogue docs; ticks the sprint-close box
that ends a sprint; says when held work may be merged; picks what the next
sprint is.

**Never delegated:** the ready tick (`docstate.OWNER_CLICK` — there is no code
path to it), any decision an issue is gated on, and the call on whether to
merge held work.

---

## Worker — `.claude/agents/isolated-worker.md`

Implements **one scoped issue**, in its own git worktree.

**Does:** the change, its tests, its `changelog.d/` fragment, and a `HANDOFF.md`
with four lines — `changed` / `found` / `assumed` / `next`.

**Never:** commits, pushes, merges, or runs `npm run build`. Never edits outside
its declared file scope — if the fix genuinely needs a file it was not given, it
stops and reports rather than widening. Never touches another worktree.

**Rules learned the hard way:**

- Write `HANDOFF.md` **early** and keep it updated. Agents have died mid-task —
  a 600-second stall, an API drop — and a worker that dies leaves only a diff
  unless it wrote down what it was going to do next.
- Check `git rev-parse --show-toplevel` **first**. It must end in
  `/browser-wrap` and must not contain `/planning-docs`. Three agents at once
  were given worktrees of a nested repo with none of their files in it.
- Symlink `node_modules` before running anything, or node resolves out of a
  sibling worktree and you test someone else's code.
- Report what you did **not** run. An unmentioned gap reads as a passing check.

---

## Verifier — `.claude/agents/verifier.md`

Sweeps **all finished worker output for a sprint**, once, on a clean tree,
before anything is folded.

**Does:** applies every finished patch together and reports whether they
coexist; builds; regenerates and checks nothing moves; runs the suites; checks
each change has a test that would plausibly bite; skims for the glaring; names
what the sprint broke in aggregate. Reports with a verdict and real numbers.

**Never:** fixes, lands, commits, or merges. Never touches a worker's worktree
(a worker may be resumed, and an edit there corrupts its diff — it gets the work
as patch files). Never conducts a design review. Never repeats a number it did
not re-run.

**One verifier per sprint, not one per worker.** Per-worker verification is what
buries the orchestrator, and it structurally cannot see two changes interacting.

---

## Orchestrator — the session talking to the owner

Folds work in, lands it, reports, and turns rulings into issues. There may be
several at once, on different workstreams.

**Does:**

- **Dispatch.** `scripts/dispatch <id> --files "…" --brief "…"` first — it is
  the gate, it claims the issue, and it records the brief. Declare a file scope
  per worker and do not overlap them.
- **Fold.** Apply verified work to `main`. Re-prove the risky changes by its own
  mutation — one half of a fix at a time, checking the failure set is the one
  that half owns. Re-run `npm run gen` and confirm the committed bundle is
  reproducible from the committed source.
- **Land.** `scripts/handoff <id> --from <worktree> --verified "<what YOU ran>"`
  then commit. It is the **only committer**.
- **Report.** A sprint ends in a report the owner ticks.
- **File.** Rulings, findings and gaps become tracker issues — not chat
  messages, not notes in a doc nobody greps.

**Never:** lands held work without the owner's go-ahead. Never relays a
subagent's verification as its own (`scripts/handoff` refuses text that reads as
a relay). Never lets its shell cwd leave the repo root — the cwd decides which
repo a dispatched worker's worktree comes from.

**Its scarcest resource is attention, not tokens.** Everything above the fold —
talking to the owner, deciding what matters, seeing across workstreams — is work
only it can do. Nitty-gritty re-running is what the verifier is for.

---

## Which agent for which job

| Job | Agent |
|---|---|
| Implement a scoped issue | `isolated-worker` |
| Sprint verification sweep | `verifier` |
| Read-only investigation, "where is X, does Y exist" | `Explore` — no worktree cost |
| Fold, land, report, file | the orchestrator itself |

New agent definitions are picked up **at session start only**. Adding one
mid-session needs a restart before `subagent_type` resolves.
