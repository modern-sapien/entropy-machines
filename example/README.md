# example — a project to run the harness against

Deliberately written in POSIX shell with **zero dependencies**. No package
manager, no runtime to install. The harness needs Python and Node for its own
implementation; your project does not have to be either, and this example is
here to prove it. Its whole toolchain surface is six lines of `entropy.json`:

```json
"suites": [ { "name": "unit", "cmd": ["sh", "tests/run.sh"] } ]
```

## What it is

`src/validate.sh` checks a username against two **independent** rules:

- **Rule A — length.** Between 3 and 16 characters.
- **Rule B — charset.** Lowercase, digits and underscore only.

`tests/run.sh` has six tests, three per rule. That independence is the point.

## Watching the mutation proof work

The harness's central claim is that re-running a worker's own revert proves
almost nothing — it only shows the test notices *that* revert. What shows a
test is pinned to behaviour is blinding one half of the code at a time and
checking the failure set is the one that half owns.

You can watch it here. Blind rule A:

```
$ sh tests/run.sh
FAIL: length/too-short (rc=0 out='ok')
FAIL: length/too-long (rc=0 out='ok')
PASS 4 / FAIL 2
```

Restore it, blind rule B instead:

```
$ sh tests/run.sh
FAIL: charset/uppercase (rc=0 out='ok')
FAIL: charset/hyphen (rc=0 out='ok')
PASS 4 / FAIL 2
```

**Two disjoint mutations, two disjoint failure sets.** Neither mutation
reddens the other's tests. That is the signal — and it is cheap enough to get
on any change you are unsure about.

## The lesson hiding in the numbers

Each mutation reddens **two** tests, not three. The third test in each group —
`length/minimum` and `charset/underscore` — passes happily with its rule
removed, because both are positive cases and a valid input stays valid when
you delete a guard.

That is not a bug in the example. It is the thing to notice: **a positive test
cannot detect a missing guard.** A suite made only of happy paths goes fully
green against code with every check stripped out, and it will report that as
success. If a mutation reddens nothing, you have not proved your fix is
guarded — you have found out your tests do not discriminate.

## Try it

```sh
cd example
sh tests/run.sh                 # green: PASS 6 / FAIL 0
# edit src/validate.sh, comment out one of the two rule calls at the bottom
sh tests/run.sh                 # exactly that rule's tests go red
```
