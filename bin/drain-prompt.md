You are running unattended. Nobody is watching, nobody can answer a question,
and the session will be killed after its timeout. Work accordingly: finish
and verify a smaller thing rather than leaving a larger thing half-done.

## Your work

Take these issues, in this order, and no others:

    __ISSUES__

Read each with `bin/tracker show <id>` before starting it. If an issue turns
out to need something you cannot do from a terminal with nobody present — a
live UI, an external service, a decision nobody has made — STOP on that
issue and run:

    bin/tracker set <id> heldWhy="<why, specific enough for a human to act on>"

so no future unattended run picks it up again, then move to the next one.
Recording why is the whole point; silently skipping it means the next run
rediscovers the same wall.

## How to work

1. `git checkout -b __BRANCH__` before your first edit. Never commit on the
   default branch.
2. Implement one issue at a time. Commit each one separately.
3. Verify before each commit: run every suite listed under `suites` in this
   repo's `entropy.json` (docs/CONFIG.md) that is not tagged `slow`. Run the
   full set, including anything tagged `slow`, at least once before you
   finish. If `suites` is empty, say so in your report rather than skipping
   verification silently.
4. If this project's `entropy.json` has `changelog.enabled` true, write one
   changelog fragment per commit using the command in
   `changelog.newFragmentCmd`, naming the issue it closes. Never hand-edit
   the collated file at `changelog.collatedFile` directly, and never run
   this project's full build/release command — some rewrite committed
   bookkeeping (a collated changelog, a checkpoint file) as a side effect,
   which is not a change you were asked to make.
5. `bin/tracker set <id> status=done` when an issue is genuinely finished
   and verified — not when the code is written, when the tests passed.

## What you may not touch

This repo's `entropy.json` lists paths under `project.protectedPaths` — an
append-only interface, a generated bundle, a cross-writer contract, anything
that needs a human holding both ends. Do not edit any of them on your own
initiative. If an issue cannot be done without touching one, mark it held as
above and move on. The runner also diffs your finished work against this
list before pushing and quarantines the whole run if it finds a match, so
there is no version of this where touching one helps.

## Before you finish

Review your own diff for correctness and simplification issues before
declaring anything done, using whatever review tooling this environment
gives you — or record in your handoff why you did not.

Then write a `HANDOFF.md` at the repo root: exactly four one-line keys —
`changed` / `found` / `assumed` / `next` — plus, per issue you touched, run
`bin/tracker remember --issue <id> "<what changed, what you verified and its
numbers, anything you skipped and why>"` so the next session (attended or
not) finds it without opening this branch. If you marked an issue held, say
so in both places — that is the most useful line here, because it is the one
that changes what tomorrow's run does.

Do not push and do not open a pull request. The runner does that after it has
checked your diff.
