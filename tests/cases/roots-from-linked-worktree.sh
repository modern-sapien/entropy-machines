# FROM INSIDE A LINKED GIT WORKTREE, commands must still resolve to the MAIN
# checkout. This is the single most load-bearing root rule in the harness and
# it has broken before.
#
# WHY IT BREAKS. `git rev-parse --show-toplevel` prints the WORKTREE's own
# path. .entropy-machines/ is gitignored, so it exists in the main checkout and in no
# worktree at all. Resolve the root that way and a dispatched worker reads an
# EMPTY tracker — which reports as "no issues ready" rather than as an error,
# so nothing anywhere says a word. --git-common-dir is the fix and this is the
# test that keeps it.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/tracker" set i-mainline title="filed in the main checkout"
assert_rc 0 "file an issue in the main checkout"
run "$HARNESS/bin/tracker" remember --issue i-mainline "a note only the main checkout has"
assert_rc 0 "record a note in the main checkout"

WT="$TEST_TMP/worktree"
run git -C "$REPO" worktree add -q "$WT" -b worker-branch
assert_rc 0 "git worktree add"
assert_dir "$WT" "the worktree exists"

# The premise of the whole test: the worktree really has no tracker state of
# its own. If this ever stops being true the test below proves nothing.
assert_no_file "$WT/.entropy-machines/issues.json" "a linked worktree has no .entropy-machines/ of its own"

# 1. The main checkout's harness, invoked with a worktree cwd.
run_in "$WT" "$HARNESS/bin/tracker" ready
assert_rc 0 "tracker ready from inside a linked worktree"
assert_out "i-mainline" "it reads the MAIN checkout's tracker, not an empty one"

# 2. The worktree's OWN checked-in copy of the harness — the one a dispatched
#    worker actually has in front of it.
run_in "$WT" "$WT/bin/tracker" ready
assert_rc 0 "the worktree's own bin/tracker"
assert_out "i-mainline" "it too resolves to the main checkout's state"

run_in "$WT" "$WT/bin/tracker" notes --issue i-mainline
assert_rc 0 "notes from inside a worktree"
assert_out "a note only the main checkout has" "the note log resolves to the main checkout"

# 3. And it did not silently create a second store on the way.
assert_no_file "$WT/.entropy-machines/issues.json" "reading from a worktree creates no second tracker there"

# 4. bin/status resolves the same way. Its docstring says so explicitly, and it
#    reimplements the rule in Python rather than sourcing lib/roots.sh — two
#    implementations of one rule is exactly where drift lives.
run_in "$WT" "$WT/bin/status"
assert_rc 0 "bin/status from inside a linked worktree"
assert_out "i-mainline" "status reports the main checkout's issues, not zero"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
