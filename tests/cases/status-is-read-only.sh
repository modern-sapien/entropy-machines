# bin/status prints live state and WRITES NOTHING. It is meant to be safe to
# run at the top of any session, on a shared checkout, in a loop — so "reads
# only" is a contract, not a description, and it is checked by diffing the
# whole repository around the call rather than by reading the source.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

T="$HARNESS/bin/tracker"
run "$T" set i-ready title="ready to work on"
assert_rc 0 "file a ready issue"
run "$T" set i-held title="held" heldWhy="owner has not ruled"
assert_rc 0 "file a held issue"
run "$HARNESS/bin/dispatch" i-flying --files "src/main.c" --brief "in flight"
assert_rc 0 "dispatch an issue so there is something in flight"

# Fingerprint everything status could plausibly touch.
fingerprint() {
  ( cd "$REPO" && git status --porcelain; cksum < "$REPO/.entropy-machines/issues.json" ) | cksum
}
before=$(fingerprint)

run "$HARNESS/bin/status"
assert_rc 0 "bin/status exits 0"

after=$(fingerprint)
assert_same "$before" "$after" "bin/status changed nothing on disk"

# --- and it answers the three questions it claims to ------------------------
assert_out "i-ready"   "it lists what is ready"
assert_not_out "i-held" "and excludes what is held"
assert_out "in flight" "it reports what is dispatched and not handed off"
assert_out "i-flying"  "by id"
assert_out "unanswered" "it counts the open questions in the docs directory"
assert_out "PRD-001-orientation.html" "naming the doc"

# --- an unexpected argument is a usage error, not a silent success ----------
run "$HARNESS/bin/status" --wat
assert_rc 2 "an unknown argument exits 2"
assert_out "usage" "with a usage line"
