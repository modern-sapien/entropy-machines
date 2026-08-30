# EVERY REFUSAL COMES BEFORE EVERY WRITE — bin/init's documented invariant,
# and the one it has already violated once.
#
# The missing-PRD check used to sit after entropy.json and .gitignore had been
# written, so a harness without its PRD left the project configured, with
# nothing to do next, and with an entropy.json that a plain re-run would then
# refuse to overwrite. Half-initialised and wedged. This pins the ordering by
# looking at the disk, not at the message.
. "$TEST_LIB/harness.sh"

fixture_new

# The one input init needs and cannot invent. Removing it from the vendored
# copy is the same condition as a harness checkout that predates the file.
rm -f "$HARNESS/lib/PRD-001-orientation.html"

run "$HARNESS/bin/init"
assert_rc_nonzero "bin/init must refuse when the orientation PRD is missing"
assert_out "REFUSED" "the refusal says so"
assert_out "PRD-001-orientation.html" "the refusal names the file it could not find"
assert_out "Nothing has been written" "the refusal states the invariant it is upholding"

# The whole point: NOTHING on disk moved.
assert_no_file "$REPO/entropy.json"  "a refused init writes no entropy.json"
assert_no_file "$REPO/.gitignore"    "a refused init writes no .gitignore"
assert_no_file "$REPO/entropy-docs"  "a refused init creates no docs directory"
assert_no_file "$REPO/.entropy"      "a refused init creates no tracker state"

# And the project is still initialisable — a half-init is not just untidy, it
# is unrecoverable without --force.
cp "$ENTROPY_SRC/lib/PRD-001-orientation.html" "$HARNESS/lib/PRD-001-orientation.html"
run "$HARNESS/bin/init"
assert_rc 0 "with the PRD restored, a plain bin/init still works — no --force needed"
assert_file "$REPO/entropy.json" "and it writes the config this time"
