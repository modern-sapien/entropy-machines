# THE POSITIVE HALF. A clean dispatch exits 0, records the brief and the scope
# on the issue, claims the issue, and writes the agent's context file.
#
# Without this every refusal test above is also satisfied by a bin/dispatch
# that refuses unconditionally.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/dispatch" i-worker --files "src/main.c" --brief "make main.c return 1"
assert_rc 0 "a clean dispatch succeeds"
assert_out "i-worker claimed" "it claims the issue in the same act"
assert_out "context written" "it writes the agent's context file"

# --- the note ---------------------------------------------------------------
run "$HARNESS/bin/tracker" notes --issue i-worker
assert_rc 0 "the note log reads back"
assert_out "DISPATCH"                "a DISPATCH note was recorded"
assert_out "make main.c return 1"    "carrying the brief verbatim"
assert_out "src/main.c"              "and the declared scope"

# --- the claim --------------------------------------------------------------
run "$HARNESS/bin/tracker" show i-worker
assert_out "progress" "the issue is claimed, so no other session reads it as free work"

run "$HARNESS/bin/tracker" ready
assert_not_out "i-worker" "and it is out of the ready list"

# --- the context file -------------------------------------------------------
# The measured finding behind this file: a rule PASTED into a brief is followed
# ~96% of the time; the same rule sitting in a file the agent is told to read,
# ~38%. So the content has to be IN the file, not referenced from it.
CTX="$REPO/.dispatch-context/i-worker.md"
assert_file "$CTX" "the per-issue context file exists"
run grep -qF "make main.c return 1" "$CTX"
assert_rc 0 "the context file contains the brief"
run grep -qF "src/main.c" "$CTX"
assert_rc 0 "and the scope"

# Per-issue, not one shared file: a dispatch round briefs N agents back to back
# and a fixed filename means agent A reads agent B's brief as its own.
run "$HARNESS/bin/dispatch" i-second --files "docs/CONFIG.md" --brief "a different job"
assert_rc 0 "a second dispatch in the same round"
assert_file "$REPO/.dispatch-context/i-second.md" "gets its own context file"
run grep -qF "make main.c return 1" "$CTX"
assert_rc 0 "and the first agent's file is untouched"

# --- --dry-run records nothing ---------------------------------------------
run "$HARNESS/bin/dispatch" i-phantom --files "src/main.c" --brief "just looking" --dry-run
assert_rc 0 "--dry-run runs every check"
assert_out "nothing recorded" "and says it recorded nothing"
run "$HARNESS/bin/tracker" notes --issue i-phantom
assert_same "" "$OUT" "a --dry-run leaves no phantom claim behind"
