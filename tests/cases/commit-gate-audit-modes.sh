# lib/handoff-guard.sh's AUDIT MODES — `--commit <sha>` and `--range <rev>`.
#
# WHY THIS EXISTS AS ITS OWN CASE. Every other commit-gate test drives the
# guard through a real `git commit`, which is hook mode (`--message`). The
# audit modes take a different path: they recover the commit's own timestamp
# from git rather than taking "now". On 2026-08-30 a fix wrote that lookup as
# `--date=format-utc:`, which is not a git date format at all. git answered
# `fatal: date format missing colon separator`, and BOTH audit modes printed
# that error and exited 0 — a gate that passes everything, in exactly the
# modes CI would run.
#
# The whole suite stayed green through it, because nothing exercised these
# modes. That is the gap this case closes.
#
# BOTH HALVES, for the reason spelled out in
# commit-gate-idless-commit-into-open-scope.sh: a mode that refuses everything
# and a mode that passes everything both look "green" against a single
# assertion.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

mkdir -p "$REPO/unrelated"
printf 'not in any scope\n' > "$REPO/unrelated/notes.md"
commit_all "a file outside every scope"
assert_rc 0 "baseline commit lands"

run "$HARNESS/bin/dispatch" i-audit --files "src/main.c" --brief "holding main.c"
assert_rc 0 "dispatch takes the file"

# --- 1. --commit REFUSES an id-less commit inside the open scope -----------
# --no-verify so the hook does not judge it first; the audit is the thing
# under test, and it must reach the same verdict after the fact.
printf 'int sneaky(void) { return 2; }\n' >> "$REPO/src/main.c"
git -C "$REPO" add src/main.c
git -C "$REPO" commit -q --no-verify -m "chore: slipped past the hook"
bad=$(git -C "$REPO" rev-parse HEAD)

run_in "$REPO" sh "$HARNESS/lib/handoff-guard.sh" --commit "$bad"
assert_rc_nonzero "--commit must refuse an id-less commit into a held scope"
assert_no_traceback "the audit must judge, not crash"
assert_not_out "fatal:" "and must not hand git a format git rejects"
assert_out "REFUSED" "it says so"
assert_out "src/main.c" "and names the held file"
assert_out "i-audit" "and names the issue holding it"

# --- 2. --commit PASSES a commit outside the open scope --------------------
# Without this half, a mode that refused unconditionally would look identical.
printf 'another line\n' >> "$REPO/unrelated/notes.md"
git -C "$REPO" add unrelated/notes.md
git -C "$REPO" commit -q --no-verify -m "chore: my own notes"
good=$(git -C "$REPO" rev-parse HEAD)

run_in "$REPO" sh "$HARNESS/lib/handoff-guard.sh" --commit "$good"
assert_rc 0 "--commit must pass a commit outside every open scope"
assert_no_traceback "cleanly"
assert_not_out "fatal:" "with no git error"
assert_not_out "REFUSED" "and no refusal"

# --- 3. --range sees the bad commit in a span ------------------------------
run_in "$REPO" sh "$HARNESS/lib/handoff-guard.sh" --range "$bad~1..$good"
assert_rc_nonzero "--range must refuse a span containing the bad commit"
assert_no_traceback "without crashing"
assert_not_out "fatal:" "and without a git error"
assert_out "src/main.c" "naming the held file"
