# HELD AND GATED ARE NOT STATUS VALUES. `status` only ever holds notstarted,
# progress or done; held-ness is the PRESENCE of heldWhy.
#
# That is not a naming preference — it is what makes "a hold must carry a
# reason" structural. There is no way to become held without supplying the
# reason in the same call, because held-ness has no existence apart from the
# field. So `status=held` has to be refused, and the refusal has to name the
# field that actually does the job, or the caller just tries a synonym.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

T="$HARNESS/bin/tracker"
run "$T" set i-thing title="a thing"
assert_rc 0 "file an issue"

run "$T" set i-thing status=held
assert_rc_nonzero "status=held must be refused"
assert_out "REFUSED" "the refusal says so"
assert_out "heldWhy" "and names the field that expresses a hold"
run "$T" show i-thing
assert_out "notstarted" "the refused set changed nothing"

run "$T" set i-thing status=gated
assert_rc_nonzero "status=gated must be refused too"
assert_out "gate" "and the refusal names the gate field"

run "$T" set i-thing statuss=done
assert_rc_nonzero "an unknown FIELD is refused, not silently stored"
assert_out "REFUSED" "the refusal says so"
assert_out "status"  "and lists the fields that do exist"

# THE CONTROL — the three real statuses are accepted. Without this, a `set`
# that refused everything would pass every assertion above.
for s in notstarted progress done; do
  run "$T" set i-thing status="$s"
  assert_rc 0 "status=$s is accepted"
  run "$T" show i-thing
  assert_out "\"status\": \"$s\"" "and is what show reports"
done

# A hold with its reason attached is accepted, which is the shape the refusal
# was steering the caller towards.
run "$T" set i-thing heldWhy="waiting on the owner's ruling"
assert_rc 0 "heldWhy with a reason is accepted"
assert_out "waiting on the owner's ruling" "and the reason is stored"
assert_out "heldAt" "with a timestamp beside it"
