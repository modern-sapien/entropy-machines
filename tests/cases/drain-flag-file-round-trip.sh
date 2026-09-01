# bin/drain's arm/disarm switch is a flag FILE, and `status` reports it
# honestly. Nothing here installs a scheduler, fires a run, or talks to a
# network — the only thing being checked is that the three commands agree with
# each other about state, which is the confusion the design exists to prevent
# ("installed but disarmed" and "armed but never installed" are different, and
# status must say which).
#
# ENTROPY_DRAIN_HOME keeps the flag file inside this case's temp directory. The
# default is ~/.entropy-machines, and a test that wrote there would be writing outside
# its own fixture.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

DRAIN_HOME="$TEST_TMP/drain-home"

run env ENTROPY_DRAIN_HOME="$DRAIN_HOME" "$HARNESS/bin/drain" status
assert_rc 0 "bin/drain status exits 0 on a fresh project"
assert_out "armed:      no" "and reports disarmed"
assert_out "scheduled:" "and reports the scheduler separately from the arming"
assert_out "last fire:  never" "and that nothing has fired"

run env ENTROPY_DRAIN_HOME="$DRAIN_HOME" "$HARNESS/bin/drain" on
assert_rc 0 "bin/drain on"
assert_out "ARMED" "says so"
assert_file "$DRAIN_HOME/armed" "and the flag file is what carries the state"

run env ENTROPY_DRAIN_HOME="$DRAIN_HOME" "$HARNESS/bin/drain" status
assert_rc 0 "status after arming"
assert_out "armed:      yes" "reports armed"

run env ENTROPY_DRAIN_HOME="$DRAIN_HOME" "$HARNESS/bin/drain" off
assert_rc 0 "bin/drain off"
assert_out "DISARMED" "says so"
assert_no_file "$DRAIN_HOME/armed" "and removes the flag"

run env ENTROPY_DRAIN_HOME="$DRAIN_HOME" "$HARNESS/bin/drain" status
assert_out "armed:      no" "and status agrees"
