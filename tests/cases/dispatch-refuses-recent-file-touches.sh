# bin/dispatch refuses when declared files were touched in the last 5 commits
# on any branch.
#
# A file that shows up in recent git history on any branch is hot — the change
# may still be landing, or the agent would be re-doing work that already
# shipped. Check 4, overridable with --force.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

# File the issue so the claim step can proceed.
run "$HARNESS/bin/tracker" set i-hot title="hot file issue" description="hot file issue"
assert_rc 0 "file the issue"

# --- a file touched in a recent commit: refused without --force -----------
# src/main.c was committed in the initial fixture_new commit, so it already
# appears in the last 5 commits. Dispatching over it should refuse.
run "$HARNESS/bin/dispatch" i-hot --files "src/main.c" --brief "work on main.c"
assert_rc_nonzero "dispatch over a recently-touched file must refuse"
assert_out "declared files were touched" "the refusal names the check"
assert_out "src/main.c" "and names the hot file"
assert_out "--force" "and tells the user how to override"

# Nothing was recorded.
run "$HARNESS/bin/tracker" notes --issue i-hot
assert_same "" "$OUT" "a refused dispatch records nothing"

# --- --force overrides the check ------------------------------------------
run "$HARNESS/bin/dispatch" i-hot --files "src/main.c" --brief "work on main.c" --force
assert_rc 0 "--force overrides the recently-touched refusal"
assert_out "declared files were touched" "the commits are still printed even with --force"

# --- a file NOT in recent history: allowed --------------------------------
run "$HARNESS/bin/tracker" set i-cold title="cold file issue" description="cold file issue"
assert_rc 0 "file the cold issue"

run "$HARNESS/bin/dispatch" i-cold --files "src/never-existed.c" --brief "work on a new file"
assert_rc 0 "a file with no recent history passes check 4"
assert_not_out "declared files were touched" "no file-history warning for a cold file"

# --- a file touched on another branch: still caught ----------------------
git -C "$REPO" checkout -q -b side-branch
mkdir -p "$REPO/lib"
printf 'side work\n' > "$REPO/lib/side.c"
git -C "$REPO" add lib/side.c
git -C "$REPO" commit -qm "add side.c on a side branch"
git -C "$REPO" checkout -q main

run "$HARNESS/bin/tracker" set i-side title="side branch issue" description="side branch issue"
assert_rc 0 "file the side issue"

run "$HARNESS/bin/dispatch" i-side --files "lib/side.c" --brief "work on side.c"
assert_rc_nonzero "a file touched on another branch is still caught by --all"
assert_out "lib/side.c" "and the side-branch file is named"
