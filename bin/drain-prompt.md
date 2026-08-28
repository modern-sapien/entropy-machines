You are running unattended. Nobody is watching, nobody can answer a question,
and the session will be killed at 90 minutes. Work accordingly: finish and
verify a smaller thing rather than leaving a larger thing half-done.

## Your work

Take these issues, in this order, and no others:

    __ISSUES__

Read each with `scripts/tracker show <id>` before starting it. If an issue
turns out to need a live browser, the bridge daemon, a decision nobody has
made, or anything you cannot verify from a terminal — STOP on that issue, run
`scripts/tracker autonomy <id> --unsafe "<why>"` so no future unattended run
picks it up again, and move to the next one. Recording why is the whole point;
silently skipping it means tomorrow's run rediscovers the same wall.

## How to work

1. `git checkout -b __BRANCH__` before your first edit. Never commit on main.
2. Implement one issue at a time. Commit each one separately.
3. Verify before each commit: `npm run typecheck && npm test && npm run e2e`.
   Add `npm run e2e:bridge` if you touched anything the daemon or CLI reads —
   it is a separate Playwright project and `npm run e2e` does not run it.
4. Write a `changelog.d/` fragment per commit:
   `npm run changelog:new -- "type(scope): subject" <issue-id>`.
   Never hand-edit `docs/CHANGELOG.md`. Never run `npm run build` — it rewrites
   the changelog and the QA checkpoint.
5. `scripts/tracker set <id> status=done` when an issue is genuinely finished
   and verified. Not when the code is written — when the tests passed.

## What you may not touch

Do not edit `src/shared/types.ts`, the trace format under
`janus-bridge/internal/trace/`, or its golden fixtures in
`tests/fixtures/trace/`. These are cross-writer contracts that need a human
holding both ends. If an issue cannot be done without them, mark it unsafe as
above and move on. The runner also diffs your finished work against these
paths and will quarantine the whole run if it finds them, so there is no
version of this where touching them helps.

## Before you finish

Run `/code-review` against your own diff and fix what it finds, or record in
the report why you did not.

Then write a build report to
`planning-docs/feature-guidance/production-plan/BUILD-REPORT-<today>.html`,
copied from `REPORT-TEMPLATE.html` in that directory. It must state, per issue:
what changed, the verification you ran and its numbers, anything you skipped
and why, and anything you would want a human to look at first. If you marked
an issue unsafe, say so there too — that is the most useful line in the report,
because it is the one that changes what tomorrow's run does.

Do not push and do not open a pull request. The runner does that after it has
checked your diff.
