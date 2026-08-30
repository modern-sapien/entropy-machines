# A HANDOFF releases the scope a DISPATCH claimed.
#
# That pair IS the claim set — lib/handoff-guard.sh's own header defines a live
# claim as "a DISPATCH note with no later HANDOFF", and bin/dispatch derives
# its denylist the same way precisely so there is no separate registry to keep
# in sync. So once an issue is handed off, an ordinary id-less commit touching
# what it used to hold must land again.
#
# The failure mode this pins is the expensive one: a claim that never releases
# turns the gate from a rule into a 24-hour wall on a file, and the only way
# past it is the escape hatch — which trains everyone to use the escape hatch.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

commit_all "baseline"
base=$(commit_count)

run "$HARNESS/bin/dispatch" i-agent --files "src/main.c" --brief "hold main.c"
assert_rc 0 "dispatch takes the file"

# The claim is live: this is the control that proves the assertion below is
# about the RELEASE and not about the gate being off.
printf 'int a(void) { return 1; }\n' >> "$REPO/src/main.c"
commit_paths "chore: touch main while it is held" src/main.c
assert_rc_nonzero "while the dispatch is open, an id-less commit is refused"
assert_out "i-agent" "by that issue's claim"

run "$HARNESS/bin/handoff" i-agent --changed "made main.c return 1" \
    --verified "I re-ran the compile in this checkout and read the diff myself" \
    --clean --no-interrogation "the agent's session had already ended"
assert_rc 0 "record the handoff"

# bin/dispatch agrees the claim is released — it reads the same log through
# lib/notes.py's live_claims(). Stashed around the call only because dispatch's
# OTHER check (uncommitted edits in the agent's scope) would fire first on the
# edit this case is holding, and that is not what is being asked here.
git -C "$REPO" stash -q --include-untracked
run "$HARNESS/bin/dispatch" i-next --files "src/main.c" --brief "the next agent" --dry-run
assert_rc 0 "dispatch runs"
assert_not_out "LIVE claim" "bin/dispatch sees the claim as released"
git -C "$REPO" stash pop -q

# ...and so must the commit gate, which reads the same log through its own
# reader. Two readers of one log that disagree about who holds what is the
# defect; this is the assertion that catches it.
commit_paths "chore: touch main after the handoff" src/main.c
assert_no_traceback "the gate must judge, not crash"
assert_rc 0 "after the handoff, an id-less commit into that scope lands again"
assert_same "$((base + 1))" "$(commit_count)" "and it really landed"
