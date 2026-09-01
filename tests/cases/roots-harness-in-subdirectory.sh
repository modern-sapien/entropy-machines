# The harness vendored INTO A SUBDIRECTORY (tools/entropy-machines/), which is the other
# supported layout. The distinction that matters:
#
#   ENTROPY_MACHINES_HOME  where bin/ and lib/ are          -> tools/entropy
#   ENTROPY_MACHINES_ROOT  the repository's main checkout   -> the repo root
#
# config.json belongs to the HARNESS directory; .entropy-machines/ and the docs
# directory belong to the ROOT. A tool that confused the two would write
# tracker state beside its own bin/ and every other tool would read an empty
# project.
. "$TEST_LIB/harness.sh"

fixture_new "tools/entropy-machines"

assert_same "$REPO/tools/entropy-machines" "$HARNESS" "this case is the subdirectory layout"

run_in "$REPO" "$HARNESS/bin/init"
assert_rc 0 "bin/init with the harness in a subdirectory"

assert_file    "$HARNESS/config.json"             "config.json belongs to the HARNESS directory"
assert_no_file "$REPO/config.json"                "and NOT to the repo root"
assert_file    "$REPO/entropy-machines-docs/PRD-001-orientation.html" "the PRD lands in the root's docs dir"
assert_no_file "$HARNESS/entropy-machines-docs"             "and not inside the harness directory"

run_in "$REPO" "$HARNESS/bin/tracker" set i-sub title="subdir layout"
assert_rc 0 "tracker set with a subdirectory harness"
assert_file    "$REPO/.entropy-machines/issues.json" "tracker state belongs to the ROOT"
assert_no_file "$HARNESS/.entropy-machines"          "and NOT to the harness directory"

# Invoked from inside the harness directory itself — the cwd most likely to
# make a tool answer with the harness instead of the project.
run_in "$HARNESS" "$HARNESS/bin/tracker" ready
assert_rc 0 "tracker ready invoked from inside the harness directory"
assert_out "i-sub" "it still reads the PROJECT's tracker"

# Hooks: the shim's baked-in ENTROPY_MACHINES_HOME has to be the subdirectory while the
# hooks directory is the root repo's. install-hooks verifies its own install,
# so a wrong answer here is a non-zero exit, not a silent one.
run_in "$REPO" "$HARNESS/lib/install-hooks.sh"
assert_rc 0 "install-hooks with a subdirectory harness"
assert_out "ENTROPY_MACHINES_HOME) = $HARNESS" "the shim bakes in the HARNESS directory"
assert_out "ENTROPY_MACHINES_ROOT) = $REPO"    "and resolves the ROOT separately"
assert_file "$REPO/.git/hooks/commit-msg" "the shim lands in the root repo's hooks directory"
