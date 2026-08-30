# `ready` is what an unattended run and every orienting session read to decide
# what may be worked on. Three things must keep an issue out of it — held,
# gated, blocked — and a CONTROL issue must stay in it throughout.
#
# The control is the whole point. "ready prints nothing" satisfies every
# exclusion assertion at once and means the filter is broken, not strict.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

T="$HARNESS/bin/tracker"

run "$T" set i-control title="plain, nothing wrong with it"
assert_rc 0 "file the control issue"
run "$T" set i-held title="held" heldWhy="the owner has not ruled on the shape yet"
assert_rc 0 "file a held issue"
run "$T" set i-gated title="gated" gate="q-4"
assert_rc 0 "file a gated issue"
run "$T" set i-dep title="the dependency"
assert_rc 0 "file a dependency"
run "$T" set i-blocked title="blocked" blockedBy="i-dep"
assert_rc 0 "file a blocked issue"

run "$T" ready
assert_rc 0 "ready"
# Matched on the id FIELD, not on the bare id: `i-dep` also appears inside
# i-blocked's own blockedBy list, so a bare substring search would report the
# dependency as ready when it is only being referred to.
assert_out     '"id": "i-control"' "THE CONTROL: a plain issue IS listed"
assert_out     '"id": "i-dep"'     "and so is the unblocked dependency"
assert_not_out '"id": "i-held"'    "an issue with heldWhy is excluded"
assert_not_out '"id": "i-gated"'   "an issue with gate is excluded"
assert_not_out '"id": "i-blocked"' "an issue blocked by an unfinished dependency is excluded"

# --- and each exclusion is reversible, which proves it is a filter on that
# --- field and not on the issue.
run "$T" set i-held heldWhy=
assert_rc 0 "clear heldWhy with an empty value"
run "$T" show i-held
assert_not_out "heldAt" "clearing heldWhy also clears heldAt — held-ness has no residue"

run "$T" set i-gated gate=
assert_rc 0 "clear gate with an empty value"

run "$T" set i-dep status=done
assert_rc 0 "finish the dependency"

run "$T" ready
assert_rc 0 "ready after clearing all three"
assert_out     '"id": "i-held"'    "the un-held issue is ready again"
assert_out     '"id": "i-gated"'   "the un-gated issue is ready again"
assert_out     '"id": "i-blocked"' "the unblocked issue is ready again"
assert_not_out '"id": "i-dep"'     "and the done dependency is not ready work"
