# The harness vendored AT THE REPO ROOT: every entry point resolves the same
# root whether it is invoked from the root or from a subdirectory of the
# project.
#
# "Which root am I in" is the question that has cost this project the most —
# three lost agents to a cwd that resolved to the wrong repository. It is
# asserted on the OBSERVABLE consequence (state lands in one place and reads
# back from anywhere), never on an internal helper.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

assert_same "$REPO" "$HARNESS" "this case is the root layout"

run_in "$REPO" "$HARNESS/bin/tracker" set i-root title="filed from the root"
assert_rc 0 "tracker set from the repo root"

# .entropy/ lands at the root, not next to whatever directory we happened to
# be standing in.
assert_file "$REPO/.entropy/issues.json" "tracker state lands at the repo root"

run_in "$REPO/src" "$HARNESS/bin/tracker" ready
assert_rc 0 "tracker ready from a subdirectory of the project"
assert_out "i-root" "a subdirectory sees the SAME tracker, not an empty one"
assert_no_file "$REPO/src/.entropy" "and it did not create a second store beside itself"

run_in "$REPO/src" "$HARNESS/bin/status"
assert_rc 0 "bin/status from a subdirectory"
assert_out "1 issue(s) ready" "status reads the project's real state from a subdirectory"
