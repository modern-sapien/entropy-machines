# bin/handoff --verified must be a first-person claim, not a relay of the
# agent's own report.
#
# Dispatch rule 5 — "verify before committing, independently" — was enforced by
# nothing. Subagents have reported passing work that was wrong: an assertion
# that proved nothing; a test titled "regression guard" that passed on the
# unfixed code. This gate cannot tell whether you really ran the command. It
# can refuse a sentence that admits you did not, and that is what is pinned
# here — together with the control that an honest sentence is accepted, because
# a --verified that refused everything would satisfy the first half alone.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/dispatch" i-lander --files "src/main.c" --brief "do the thing"
assert_rc 0 "dispatch the agent"

# --- the relays ------------------------------------------------------------
for phrase in \
  "agent reports the suite is green" \
  "the agent says it ran the tests" \
  "as reported by the worker, tests pass" \
  "I trust the agent's summary"
do
  run "$HARNESS/bin/handoff" i-lander --changed "made the change" --verified "$phrase" --clean \
      --no-interrogation "the agent's session had already ended"
  assert_rc_nonzero "--verified must refuse: $phrase"
  assert_out "REFUSED" "the refusal says so"
  assert_out "relays the agent" "and names what is wrong with it"
  assert_out "$phrase" "and quotes the sentence back"
done

# Nothing was recorded by any of those.
run "$HARNESS/bin/tracker" notes --issue i-lander
assert_not_out "HANDOFF" "a refused handoff records nothing"

# --- THE CONTROL: a first-person claim is accepted -------------------------
run "$HARNESS/bin/handoff" i-lander \
    --changed "made main.c return 1" \
    --verified "I ran cc -c src/main.c in this checkout and read the diff line by line" \
    --clean --no-interrogation "the agent's session had already ended"
assert_rc 0 "an honest first-person --verified is accepted"

run "$HARNESS/bin/tracker" notes --issue i-lander
assert_out "HANDOFF" "and the handoff is recorded"
assert_out "I ran cc -c src/main.c" "with the verification text on the record"

# --- --verified is mandatory ----------------------------------------------
run "$HARNESS/bin/handoff" i-lander --changed "something" --clean
assert_rc 2 "handoff with no --verified is a usage error"
assert_out "usage" "with a usage line"

# --- silence about findings must be deliberate ----------------------------
# --found and --next are the two fields with real salvage value and the two an
# author in a hurry omits, so omitting both is refused unless --clean says so
# on purpose.
run "$HARNESS/bin/handoff" i-lander --changed "something" \
    --verified "I re-ran the compile myself and it succeeded" \
    --no-interrogation "the agent's session had already ended"
assert_rc_nonzero "omitting both --found and --next without --clean is refused"
assert_out "no --found and no --next" "and the refusal names both fields"
