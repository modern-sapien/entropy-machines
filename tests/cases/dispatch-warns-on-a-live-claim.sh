# Dispatching a second agent over a file another LIVE dispatch is holding.
#
# READ THIS BEFORE "FIXING" THE ASSERTION. bin/dispatch WARNS here; it does not
# refuse, and that is deliberate and documented in its own header: re-dispatching
# an issue over its predecessor's files is legitimate, and only the lander can
# tell that from a genuine collision. The enforcement lives at the other end —
# `bin/handoff --lift` refuses a claimed file, and the commit-msg gate refuses
# an id-less commit into an open scope (see the commit-gate cases).
#
# So what is pinned here is: the warning FIRES, it NAMES the file and the
# holder, and it does not fire when there is no overlap. If this ever becomes a
# refusal, that is a deliberate design change and this case should be changed
# with it — not silently loosened.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

mkdir -p "$REPO/other"
printf 'x\n' > "$REPO/other/thing.txt"
commit_all "add a second file"
assert_rc 0 "baseline commit"

# File the issues first: `claim` does not auto-vivify, and an unclaimable id
# makes bin/dispatch print a WARNING of its own, which would muddy the
# assertions below about the live-claim warning.
for i in i-holder i-collider i-elsewhere i-after; do
  run "$HARNESS/bin/tracker" set "$i" title="$i"
  assert_rc 0 "file $i"
done

run "$HARNESS/bin/dispatch" i-holder --files "src/main.c" --brief "the first agent"
assert_rc 0 "the first dispatch takes the file"

# --- overlapping -----------------------------------------------------------
run "$HARNESS/bin/dispatch" i-collider --files "src/main.c" --brief "the second agent"
assert_out "WARNING" "an overlapping dispatch is flagged"
assert_out "LIVE claim" "as a live claim"
assert_out "src/main.c" "and the contended file is named"
assert_out "serialize" "with the reason stated"

# The agent's own brief must carry the denylist, because that is the channel
# that actually reaches it.
CTX="$REPO/.dispatch-context/i-collider.md"
assert_file "$CTX" "the collider still gets a context file"
run grep -qF "src/main.c" "$CTX"
assert_rc 0 "the context file names the file the other agent is holding"

# --- NOT overlapping -------------------------------------------------------
# The control: the warning is a judgement about overlap, not a thing printed
# whenever any dispatch is live.
run "$HARNESS/bin/dispatch" i-elsewhere --files "other/thing.txt" --brief "a third agent, elsewhere"
assert_rc 0 "a non-overlapping dispatch succeeds"
assert_not_out "LIVE claim" "and raises no live-claim warning"

# --- and a claim is released by a handoff ----------------------------------
# DISPATCH claims, HANDOFF releases; the claim set is derived from that pair
# and needs no separate registry. BOTH holders of src/main.c have to be handed
# off for it to be free — which is itself the assertion that the release is
# per-issue and not a global "somebody handed something off" flag.
run "$HARNESS/bin/handoff" i-holder --changed "made main.c return 1" \
    --verified "I re-ran the build in this checkout myself and read the diff" \
    --clean --no-interrogation "the agent's session had already ended"
assert_rc 0 "record the handoff for i-holder"

run "$HARNESS/bin/dispatch" i-probe --files "src/main.c" --brief "probe" --dry-run
assert_rc 0 "a dry-run dispatch after only ONE of two holders handed off"
assert_out "LIVE claim" "still warns — the release is per-issue, not a global flag"

run "$HARNESS/bin/handoff" i-collider --changed "made main.c return 1" \
    --verified "I re-ran the build in this checkout myself and read the diff" \
    --clean --no-interrogation "the agent's session had already ended"
assert_rc 0 "record the handoff for i-collider"

run "$HARNESS/bin/dispatch" i-after --files "src/main.c" --brief "after the handoff"
assert_rc 0 "dispatching over a released file succeeds"
assert_not_out "LIVE claim" "and no longer warns about a claim that was handed off"
