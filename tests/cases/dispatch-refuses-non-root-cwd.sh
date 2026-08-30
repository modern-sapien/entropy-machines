# bin/dispatch refuses to run from anywhere but the project root.
#
# A worktree is created in whatever repo the dispatching shell's cwd belongs
# to. A session parked one directory off has handed agents a worktree of the
# WRONG repository more than once — three agents lost in one day — and the
# symptom is not an error, it is an agent that cannot find its own files. This
# is check 1 and it has no override.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run_in "$REPO/src" "$HARNESS/bin/dispatch" i-somewhere --files "src/main.c" --brief "b"
assert_rc_nonzero "dispatch from a subdirectory must refuse"
assert_out "REFUSED" "the refusal says so"
assert_out "$REPO/src" "it names the cwd it was actually in"
assert_out "$REPO"     "and the root it wanted"
assert_out "cd $REPO"  "and the exact command that fixes it"

# Nothing recorded. A refusal that has already written a DISPATCH note leaves
# a phantom claim that reads to every later session as an unlanded agent, and
# the note log is append-only with no delete.
run "$HARNESS/bin/tracker" notes --issue i-somewhere
assert_rc 0 "reading the note log"
assert_same "" "$OUT" "a refused dispatch records nothing"
assert_no_file "$REPO/.dispatch-context/i-somewhere.md" "and writes no context file"

# THE CONTROL — from the root, the same dispatch is fine. Without this the
# assertions above are also satisfied by a dispatch that refuses everything.
run_in "$REPO" "$HARNESS/bin/dispatch" i-somewhere --files "src/main.c" --brief "b"
assert_rc 0 "the same dispatch from the project root succeeds"
