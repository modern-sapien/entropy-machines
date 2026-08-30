# bin/dispatch refuses to brief an agent over files you are mid-edit in.
#
# A worker's worktree branches from local HEAD, so unpushed commits are
# visible; uncommitted edits are not. Hand an agent a file you are editing and
# it works from the committed version, and its result silently drops your
# changes. Check 2, no override.
#
# The other half matters as much: a dirty tree OUTSIDE the declared scope is
# normal and must NOT refuse. A gate that fires on any dirty tree is a gate
# nobody can dispatch through.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

mkdir -p "$REPO/docs-of-mine"
printf 'notes\n' > "$REPO/docs-of-mine/scratch.md"
commit_all "add a second file to be dirty in"
assert_rc 0 "baseline commit"

# --- dirty INSIDE the scope: refused ---------------------------------------
printf 'int extra(void) { return 1; }\n' >> "$REPO/src/main.c"

run "$HARNESS/bin/dispatch" i-dirty --files "src/main.c" --brief "b"
assert_rc_nonzero "dispatch over an uncommitted file in the agent's own scope must refuse"
assert_out "REFUSED" "the refusal says so"
assert_out "src/main.c" "and names the file it collided with"
assert_out "Commit them first" "and says what to do"

run "$HARNESS/bin/tracker" notes --issue i-dirty
assert_same "" "$OUT" "a refused dispatch records nothing"

# --- dirty OUTSIDE the scope: allowed --------------------------------------
git -C "$REPO" checkout -- src/main.c
printf 'more of my own notes\n' >> "$REPO/docs-of-mine/scratch.md"

run "$HARNESS/bin/dispatch" i-clean --files "src/main.c" --brief "b"
assert_rc 0 "a dirty tree OUTSIDE the agent's scope is none of its business"
assert_not_out "REFUSED" "and produces no refusal"

# --- a directory-shaped scope entry still catches a file under it ----------
git -C "$REPO" checkout -- docs-of-mine/scratch.md
printf 'dirty again\n' >> "$REPO/docs-of-mine/scratch.md"
run "$HARNESS/bin/dispatch" i-dirdir --files "docs-of-mine/" --brief "b"
assert_rc_nonzero "a directory scope entry covers the files under it"
assert_out "docs-of-mine/scratch.md" "and the refusal names the specific file"
