# lib/handoff-guard.sh, through a REAL `git commit` and the hooks
# lib/install-hooks.sh installs. Nothing here calls the guard directly: the
# thing that has broken is whether it fires at all, and calling it by hand
# cannot tell you that.
#
# BOTH HALVES, AND THEY ARE THE POINT. This gate was found on 2026-08-27
# exiting with a Python traceback instead of a verdict — so every commit naming
# an id was blocked by what read as a broken tool — and then, once that crash
# was fixed, silently PASSING EVERYTHING because its timestamp parser rejected
# every note in the store. A test that only proves the refusal fires cannot
# distinguish a working gate from one that refuses everything; a test that only
# proves a commit lands cannot distinguish a working gate from a dead one. So:
#
#   1. an id-less commit touching a HELD file is REFUSED and names the file
#   2. an id-less commit touching a file OUTSIDE that scope LANDS
#   3. naming the id, with a handoff on record, LANDS
#   4. the documented escape hatch works
#   5. none of it prints a traceback (run_in asserts that after every command)
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

mkdir -p "$REPO/unrelated"
printf 'nothing to do with the agent\n' > "$REPO/unrelated/notes.md"
commit_all "add a file outside every scope"
assert_rc 0 "baseline commit lands before any dispatch exists"
base=$(commit_count)

run "$HARNESS/bin/dispatch" i-holder --files "src/main.c" --brief "an agent is holding main.c"
assert_rc 0 "dispatch takes the file"

# --- 1. REFUSED: id-less, inside the open scope ----------------------------
printf 'int sneaky(void) { return 2; }\n' >> "$REPO/src/main.c"
commit_paths "chore: tidy up main" src/main.c
assert_rc_nonzero "an id-less commit into a held scope must be refused"
assert_no_traceback "the gate must judge, not crash"
assert_out "handoff-guard" "the refusal identifies itself"
assert_out "REFUSED" "and says so"
assert_out "src/main.c" "and names the file that is held"
assert_out "i-holder" "and names the issue holding it"
assert_out "names no issue id" "and states the rule it applied"
assert_same "$base" "$(commit_count)" "the refused commit did not land"

# --- 2. LANDS: id-less, outside the open scope -----------------------------
git -C "$REPO" reset -q
git -C "$REPO" checkout -- src/main.c
printf 'a second line\n' >> "$REPO/unrelated/notes.md"
commit_paths "chore: tidy up my own notes" unrelated/notes.md
assert_rc 0 "an id-less commit OUTSIDE the open scope must land"
assert_no_traceback "and land without a traceback"
assert_not_out "REFUSED" "with no refusal"
assert_same "$((base + 1))" "$(commit_count)" "the commit really landed"

# --- 3. LANDS: naming the id, once the handoff is on record ----------------
# Naming the id takes the commit out of THIS rule's reach ("names no issue
# id") and hands it to the id-keyed check, which wants the handoff record.
printf 'int sneaky(void) { return 2; }\n' >> "$REPO/src/main.c"
commit_paths "fix: land the agent's work (i-holder)" src/main.c
assert_rc_nonzero "naming a dispatched id with no handoff on record is refused"
assert_out "no handoff was recorded" "by the id-keyed half of the gate"
assert_same "$((base + 1))" "$(commit_count)" "and that commit did not land either"

run "$HARNESS/bin/handoff" i-holder --changed "made main.c return 2" \
    --verified "I re-read the diff in this checkout and compiled it myself" \
    --clean --no-interrogation "the agent's session had already ended"
assert_rc 0 "record the handoff"

commit_paths "fix: land the agent's work (i-holder)" src/main.c
assert_rc 0 "the same commit lands once the handoff exists"
assert_no_traceback "without a traceback"
assert_same "$((base + 2))" "$(commit_count)" "and it really landed"

# --- 4. the escape hatch ---------------------------------------------------
run "$HARNESS/bin/dispatch" i-holder2 --files "src/main.c" --brief "hold main.c again"
assert_rc 0 "a second agent takes the file"

printf 'unrelated work that happens to sit in an open scope\n' >> "$REPO/src/main.c"
commit_paths "chore: unrelated work" src/main.c
assert_rc_nonzero "still refused while the new dispatch holds it"

run sh -c "cd '$REPO' && git add -- src/main.c && git commit -q -m 'chore: unrelated work [skip handoff]'"
assert_rc 0 "the documented '[skip handoff]' marker is a way through"
assert_same "$((base + 3))" "$(commit_count)" "and the commit landed"
