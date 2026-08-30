# bin/handoff must recognise the DISPATCH note bin/dispatch just wrote.
#
# The two halves of one protocol have to read the same log the same way. What
# hangs off that recognition inside bin/handoff:
#
#   - the recorded SCOPE and DENYLIST, which are what `--lift` refuses on;
#   - the INTERROGATION contract, which is only enforceable if the tool can see
#     that the agent was dispatched under it;
#   - the "hand-done work?" message, which is a real signal to the lander that
#     the id it typed is not the one that was dispatched.
#
# There is no way to observe any of that except through what the command says
# and does, which is what this asserts. If it fails, the first thing to check
# is whether the note format changed under a reader that was not updated with
# it: `bin/tracker notes --issue <id>` shows what is actually in the log.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/dispatch" i-real --files "src/main.c" --brief "the brief"
assert_rc 0 "dispatch records a DISPATCH note"

# The note really is there, in the log, under this id. Anything below that
# claims otherwise is bin/handoff failing to read it, not a missing note.
run "$HARNESS/bin/tracker" notes --issue i-real
assert_rc 0 "the note log reads back"
assert_out "DISPATCH" "and contains the DISPATCH note"
assert_out "src/main.c" "carrying the scope"

# --- 1. handoff must not call a dispatched issue hand-done work ------------
run "$HARNESS/bin/handoff" i-real --changed "did the thing" \
    --verified "I re-ran the compile in this checkout myself" \
    --clean --no-interrogation "the agent's session had already ended" --dry-run
assert_rc 0 "handoff --dry-run runs"
assert_not_out "no DISPATCH note found" \
  "bin/handoff must SEE the dispatch note bin/dispatch wrote for this id"

# --- 2. an id nobody dispatched IS hand-done work --------------------------
# The control: the message above is a real judgement, not a message that never
# prints.
run "$HARNESS/bin/handoff" i-never-dispatched --changed "did it by hand" \
    --verified "I wrote and ran the check myself" --clean --dry-run
assert_rc 0 "handoff on an undispatched id runs"
assert_out "no DISPATCH note found" "and correctly calls it hand-done work"

# --- 3. the interrogation contract is enforced -----------------------------
# bin/dispatch records `interrogation: required` and tells the agent, in its
# own brief, that it will be questioned before its work is lifted. That is
# what makes the demand fair — and it is only enforceable if bin/handoff can
# see the note. Recording with neither an interrogation nor the written reason
# for skipping it must be refused.
run "$HARNESS/bin/handoff" i-real --changed "did the thing" \
    --verified "I re-ran the compile in this checkout myself" --clean
assert_rc_nonzero "recording a dispatched issue with no interrogation is refused"
assert_out "interrogation" "and the refusal names what is missing"

# --- 4. and the written escape hatch is accepted ---------------------------
run "$HARNESS/bin/handoff" i-real --changed "did the thing" \
    --verified "I re-ran the compile in this checkout myself" --clean \
    --no-interrogation "the agent's session had already ended and could not be asked"
assert_rc 0 "saying in writing why nobody could ask is accepted"
