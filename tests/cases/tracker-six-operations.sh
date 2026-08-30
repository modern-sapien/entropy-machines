# The six operations bin/tracker promises: show, notes, remember, claim, ready,
# set. Driven through bin/tracker, never through lib/tracker-file — the adapter
# contract is the thing with consumers, and a `command` backend would have to
# satisfy the same assertions.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# --- set auto-vivifies -----------------------------------------------------
# There is no `create`. `set` on an id nobody has ever mentioned brings it into
# existence, because every caller in this harness files by writing a field.
run "$HARNESS/bin/tracker" show i-ghost
assert_rc_nonzero "show on an unknown id must fail, not print an empty issue"
assert_out "no such issue" "and say which id"

run "$HARNESS/bin/tracker" set i-ghost title="materialised by set"
assert_rc 0 "set auto-vivifies an unknown issue"
assert_out "i-ghost" "and echoes the issue back"

run "$HARNESS/bin/tracker" show i-ghost
assert_rc 0 "show finds the auto-vivified issue"
assert_out "materialised by set" "with the title that created it"
assert_out "notstarted" "and a default status"

# --- ready -----------------------------------------------------------------
run "$HARNESS/bin/tracker" ready
assert_rc 0 "ready"
assert_out "i-ghost" "a plain notstarted issue is ready"

# --- remember / notes ------------------------------------------------------
run "$HARNESS/bin/tracker" remember --issue i-ghost "the thing worth remembering"
assert_rc 0 "remember"

run "$HARNESS/bin/tracker" notes --issue i-ghost
assert_rc 0 "notes --issue"
assert_out "the thing worth remembering" "the note reads back"

run "$HARNESS/bin/tracker" set i-other title="unrelated"
assert_rc 0 "file a second issue"
run "$HARNESS/bin/tracker" notes --issue i-other
assert_rc 0 "notes --issue on an issue with no notes"
assert_not_out "the thing worth remembering" "--issue really filters; it is not just printing everything"

run "$HARNESS/bin/tracker" notes
assert_rc 0 "notes with no filter"
assert_out "the thing worth remembering" "the unfiltered log contains it"

# --- claim -----------------------------------------------------------------
run env ENTROPY_ACTOR=agent-one "$HARNESS/bin/tracker" claim i-ghost
assert_rc 0 "claim an unclaimed issue"
assert_out "agent-one" "the claim records who took it"

run "$HARNESS/bin/tracker" show i-ghost
assert_out "progress" "claiming moves the issue to progress"

run "$HARNESS/bin/tracker" ready
assert_rc 0 "ready after the claim"
assert_not_out "i-ghost" "a claimed issue is no longer ready work"
assert_out "i-other" "but the other issue still is — ready did not just go empty"

# A second actor must not be handed an issue somebody is already inside.
run env ENTROPY_ACTOR=agent-two "$HARNESS/bin/tracker" claim i-ghost
assert_rc_nonzero "a second actor's claim on a held issue must be refused"
assert_out "REFUSED" "the refusal says so"
assert_out "agent-one" "and names who holds it"

# The same actor re-claiming is idempotent, not an error — a resumed session
# must not be told it lost its own issue.
run env ENTROPY_ACTOR=agent-one "$HARNESS/bin/tracker" claim i-ghost
assert_rc 0 "the holding actor may re-claim its own issue"
