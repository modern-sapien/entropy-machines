# After a successful --verified record with --from pointing at an agent
# worktree, bin/handoff should remove the source worktree automatically.
#
# This is best-effort: a cleanup failure must not turn a green landing red.
# The test verifies:
#   1. The worktree IS removed after a successful record
#   2. The per-worktree branch IS deleted
#   3. --no-cleanup suppresses the cleanup
#   4. A --from pointing at a NON-agent path is left alone
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

# Commit the harness init changes (especially .gitignore with .scratch) so
# that worktrees inherit the gitignore and the post-checkout hook's .scratch
# symlink does not show up as an untracked file in `git status`.
commit_all "harness init"
assert_rc 0 "commit init changes"

# --- set up: dispatch an issue so the handoff gates are satisfied -----------
run "$HARNESS/bin/dispatch" i-cleanup-test --files "src/main.c" --brief "test cleanup" --force
assert_rc 0 "dispatch records"

# --- set up: create an agent worktree the way the real flow does -----------
wt_dir="$REPO/.claude/worktrees"
mkdir -p "$wt_dir"
wt_path="$wt_dir/agent-cleanup-test-001"
run git -C "$REPO" worktree add -q "$wt_path" -b worktree-agent-cleanup-test-001
assert_rc 0 "worktree created"
assert_dir "$wt_path" "worktree directory exists"

# The agent writes a file in its worktree (uncommitted).
printf 'int foo(void) { return 1; }\n' > "$wt_path/src/main.c"

# Write the HANDOFF.md the agent would leave.
cat > "$wt_path/HANDOFF.md" << 'EOF'
changed: src/main.c
found: none
assumed: none
next: none
EOF

# Record the interrogation (required by the dispatch contract).
run "$HARNESS/bin/handoff" i-cleanup-test --record-interrogation \
  --answer "did not run the full suite" \
  --answer "the weakest assertion is the trivial return value" \
  --answer "took the dispatch scope as given" \
  --answer "nothing skipped" \
  --answer "would check edge cases"
assert_rc 0 "interrogation recorded"

# --- 1. lift the files first -----------------------------------------------
run "$HARNESS/bin/handoff" i-cleanup-test --from "$wt_path" --lift
assert_rc 0 "lift succeeds"

# --- 2. record with --verified — the worktree should be removed ------------
run "$HARNESS/bin/handoff" i-cleanup-test --from "$wt_path" \
    --verified "I ran the compile in this checkout and it succeeded" --clean
assert_rc 0 "record succeeds"
assert_out "cleaned up worktree" "reports that the worktree was removed"

# The directory is gone.
assert_no_file "$wt_path/HANDOFF.md" "worktree files are gone"
if [ -d "$wt_path" ]; then
  echo "  ASSERTION FAILED: worktree directory should not exist after cleanup"
  exit 1
fi

# The branch is gone.
if git -C "$REPO" rev-parse --verify worktree-agent-cleanup-test-001 >/dev/null 2>&1; then
  echo "  ASSERTION FAILED: the per-worktree branch should be deleted"
  exit 1
fi

# --- 3. --no-cleanup suppresses the cleanup --------------------------------
# Commit the lifted changes first so the next dispatch does not refuse dirty scope.
commit_all "i-cleanup-test: land the first agent's work"
assert_rc 0 "commit lifted changes"

run "$HARNESS/bin/dispatch" i-noclean-test --files "src/main.c" --brief "test no-cleanup" --force --anyway
assert_rc 0 "second dispatch"

wt_path2="$wt_dir/agent-cleanup-test-002"
run git -C "$REPO" worktree add -q "$wt_path2" -b worktree-agent-cleanup-test-002
assert_rc 0 "second worktree created"
printf 'int bar(void) { return 2; }\n' > "$wt_path2/src/main.c"
cat > "$wt_path2/HANDOFF.md" << 'EOF'
changed: src/main.c
found: none
assumed: none
next: none
EOF

run "$HARNESS/bin/handoff" i-noclean-test --record-interrogation \
  --answer "did not run the full suite" \
  --answer "trivial" \
  --answer "dispatch scope" \
  --answer "nothing" \
  --answer "edge cases"
assert_rc 0 "second interrogation"

run "$HARNESS/bin/handoff" i-noclean-test --from "$wt_path2" --lift
assert_rc 0 "second lift"

run "$HARNESS/bin/handoff" i-noclean-test --from "$wt_path2" \
    --verified "compiled it" --clean --no-cleanup
assert_rc 0 "record with --no-cleanup succeeds"
assert_not_out "cleaned up worktree" "no cleanup message when --no-cleanup is passed"

# The worktree is still there.
assert_dir "$wt_path2" "worktree is preserved with --no-cleanup"

# --- 4. --from pointing at a non-agent path is left alone ------------------
# Commit the lifted changes first.
commit_all "i-noclean-test: land"
assert_rc 0 "commit before non-agent test"

non_agent="$TEST_TMP/manual-worktree"
run git -C "$REPO" worktree add -q "$non_agent" -b manual-branch
assert_rc 0 "non-agent worktree created"

run "$HARNESS/bin/dispatch" i-manual-test --files "src/main.c" --brief "test manual" --force --anyway
assert_rc 0 "third dispatch"

printf 'int baz(void) { return 3; }\n' > "$non_agent/src/main.c"
cat > "$non_agent/HANDOFF.md" << 'EOF'
changed: src/main.c
found: none
assumed: none
next: none
EOF

run "$HARNESS/bin/handoff" i-manual-test --record-interrogation \
  --answer "did not run suite" \
  --answer "trivial" \
  --answer "scope" \
  --answer "nothing" \
  --answer "edge cases"
assert_rc 0 "third interrogation"

run "$HARNESS/bin/handoff" i-manual-test --from "$non_agent" --lift
assert_rc 0 "third lift"

run "$HARNESS/bin/handoff" i-manual-test --from "$non_agent" \
    --verified "compiled" --clean
assert_rc 0 "record with non-agent --from"
assert_not_out "cleaned up worktree" "non-agent worktree is not cleaned up"
assert_dir "$non_agent" "non-agent worktree still exists"

# Clean up manually so the temp dir removal succeeds.
git -C "$REPO" worktree remove --force "$wt_path2" 2>/dev/null || true
git -C "$REPO" worktree remove --force "$non_agent" 2>/dev/null || true
