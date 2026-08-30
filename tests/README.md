# tests

```sh
tests/run                    # everything
tests/run tracker serve      # only cases whose name contains "tracker" or "serve"
tests/run -v                 # print each case's output even when it passes
tests/run -k                 # keep the temp directories, and print where they are
tests/run -l                 # list the cases
```

Exit 0 means every case passed. No install step, no dependencies beyond what
the harness itself already requires: POSIX `sh`, `git`, and Python 3.

## Adding a case

One file, `tests/cases/<name>.sh`. Exit 0 is a pass; the assertions exit
non-zero for you. The name is what shows up in the report and what `tests/run
<pattern>` matches on, so make it a sentence about the behaviour
(`tracker-ready-excludes-held-and-gated`), not a file name (`tracker2`).

```sh
# One line saying what behaviour this pins, and — where there is one — the
# failure that made it worth pinning.
. "$TEST_LIB/harness.sh"

fixture_new            # a throwaway git repo with the harness vendored in
fixture_init           # ...and bin/init run in it
fixture_hooks          # ...and the git hooks installed

run "$HARNESS/bin/tracker" set i-thing status=held
assert_rc_nonzero "status=held must be refused"
assert_out "heldWhy" "and the refusal must name the field that works"
```

`run` (and `run_in <dir>`) capture `RC`, `OUT`, `ERR` and `ALL`, and never
return non-zero themselves — a refusal is usually the thing under test, so the
case has to stay alive to assert on it. `fixture_new "tools/entropy"` vendors
the harness into a subdirectory instead of the repo root; both layouts are
supported and both are exercised. Everything else is in `tests/lib/harness.sh`,
which is short enough to read.

Two rules that are not negotiable, because both have already cost this project
a bug that shipped:

- **Assert the exit code explicitly, every time.** Several failures here hid
  behind a command that printed the right thing and exited non-zero, or crashed
  and exited zero. `assert_rc 0` is not noise.
- **Test both halves of every gate.** A case that only proves a refusal fires
  cannot tell a working gate from one that refuses everything; a case that only
  proves the happy path cannot tell a working gate from a dead one. Every
  refusal case here carries a control that must pass.

`run` also fails any case whose command printed a Python traceback. A gate that
dies is not a gate — `lib/handoff-guard.sh` was found exiting on a traceback
instead of a verdict, which reads to the caller as a broken tool rather than as
a rule, and the fix for that crash then turned it into a gate that silently
passed everything.

## Why these are black-box scenario tests

Everything here drives a real command-line entry point (`bin/init`,
`bin/tracker`, `bin/dispatch`, `bin/handoff`, `bin/status`, `bin/serve`,
`bin/drain`, `lib/install-hooks.sh`) inside a throwaway git repository built
from scratch, and asserts only on what a user can see: exit codes, what was
printed, and what is on disk. Nothing imports a Python module, sources a shell
library, or calls an internal function. That is deliberate for two reasons.
First, the harness's value proposition is not that its code is a particular
shape — it is that its rules have mechanisms behind them, and "does this
refusal actually fire, through a real `git commit`, with the hooks a real user
installed" is a question a unit test of the guard's parser cannot answer; three
separate gates were found dead on 2026-08-29, and all three would have passed a
test that called them directly. Second, the internals move: the files under
`lib/` are edited constantly and often by several agents at once, so a test
coupled to a helper's signature is broken before anyone runs it, while a test
coupled to the CLI contract survives the refactor and is the thing worth
keeping stable anyway.

The cost is honest: these tests are slower than unit tests, they cannot tell
you *which line* broke, and a genuine change of contract means editing them.
Read the failure message, then reproduce it by hand — `tests/run -k` keeps the
fixture and prints the path, and every case is a sequence of commands you can
retype in that directory.

Each case builds its own repository and cleans up after itself. There is no
shared state, no ordering, no setup step to run first, and no case depends on
another having run — so a single case can be run alone and a failure is never
someone else's leftovers.

## Checking that the suite can fail

A suite nobody has seen fail is not known to test anything. `ENTROPY_SRC`
points the whole run at a different harness checkout, so the way to check is to
break a copy:

```sh
cp -R <harness> /tmp/broken
# e.g. make `ready` ignore heldWhy, or delete the scope check from handoff-guard
ENTROPY_SRC=/tmp/broken tests/run
```

The real checkout is never modified by a run: fixtures are copies, and every
path the runner writes to is under a temp directory it created.
