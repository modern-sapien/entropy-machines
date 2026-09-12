# bin/worktree-gc removes orphaned agent worktrees and leaves active ones.
#
# An agent worktree is orphaned if:
#   1. It has a HANDOFF.md (the agent finished)
#   2. It is older than the age threshold AND has no .dispatch-issue marker
#
# This test verifies:
#   1. A worktree with HANDOFF.md is removed
#   2. A young worktree with .dispatch-issue is kept
#   3. --dry-run lists but does not remove
#   4. --all removes everything including active worktrees
#   5. Non-agent worktrees are never touched
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

wt_dir="$REPO/.claude/worktrees"
mkdir -p "$wt_dir"

# --- fixture: create three agent worktrees --------------------------------

# 1. Finished agent (has HANDOFF.md) — should be removed
wt_finished="$wt_dir/agent-gc-finished"
run git -C "$REPO" worktree add -q "$wt_finished" -b worktree-agent-gc-finished
assert_rc 0 "finished worktree created"
cat > "$wt_finished/HANDOFF.md" << 'EOF'
changed: src/main.c
found: none
assumed: none
next: none
EOF

# 2. Active agent (has .dispatch-issue, no HANDOFF.md) — should be kept
wt_active="$wt_dir/agent-gc-active"
run git -C "$REPO" worktree add -q "$wt_active" -b worktree-agent-gc-active
assert_rc 0 "active worktree created"
printf 'i-some-issue\n' > "$wt_active/.dispatch-issue"

# 3. Orphan agent (no .dispatch-issue, no HANDOFF.md, but too young by default)
wt_orphan="$wt_dir/agent-gc-orphan"
run git -C "$REPO" worktree add -q "$wt_orphan" -b worktree-agent-gc-orphan
assert_rc 0 "orphan worktree created"

# 4. A non-agent worktree — never touched
wt_human="$wt_dir/my-feature"
run git -C "$REPO" worktree add -q "$wt_human" -b feature-branch
assert_rc 0 "non-agent worktree created"

# --- 1. dry-run lists what would be removed --------------------------------
run "$HARNESS/bin/worktree-gc" --dry-run
assert_rc 0 "dry-run succeeds"
assert_out "agent-gc-finished" "dry-run lists the finished worktree"
assert_out "HANDOFF.md present" "dry-run explains why (HANDOFF.md)"
assert_not_out "agent-gc-active" "dry-run does not list the active worktree"
# The orphan is too young (created just now, default threshold is 24h)
assert_not_out "agent-gc-orphan" "dry-run does not list the too-young orphan"
assert_not_out "my-feature" "dry-run does not list the non-agent worktree"

# Everything still exists after dry-run.
assert_dir "$wt_finished" "finished worktree still exists after dry-run"
assert_dir "$wt_active" "active worktree still exists after dry-run"
assert_dir "$wt_orphan" "orphan worktree still exists after dry-run"
assert_dir "$wt_human" "non-agent worktree still exists after dry-run"

# --- 2. real run removes the finished one, keeps the rest ------------------
run "$HARNESS/bin/worktree-gc"
assert_rc 0 "gc succeeds"
assert_out "agent-gc-finished" "gc reports removing the finished worktree"

# Finished is gone.
if [ -d "$wt_finished" ]; then
  echo "  ASSERTION FAILED: finished worktree should be removed"
  exit 1
fi

# Branch is gone.
if git -C "$REPO" rev-parse --verify worktree-agent-gc-finished >/dev/null 2>&1; then
  echo "  ASSERTION FAILED: finished worktree's branch should be deleted"
  exit 1
fi

# Active is kept.
assert_dir "$wt_active" "active worktree is kept"

# Orphan is kept (too young).
assert_dir "$wt_orphan" "young orphan is kept"

# Non-agent is kept.
assert_dir "$wt_human" "non-agent worktree is kept"

# --- 3. --max-age 0 removes old orphans (the just-created one counts) ------
run "$HARNESS/bin/worktree-gc" --max-age 0
assert_rc 0 "gc with --max-age 0 succeeds"
assert_out "agent-gc-orphan" "orphan is reported removed"
assert_out "no .dispatch-issue" "explains why (no dispatch-issue marker)"

if [ -d "$wt_orphan" ]; then
  echo "  ASSERTION FAILED: orphan should be removed with --max-age 0"
  exit 1
fi

# Active is STILL kept (has .dispatch-issue).
assert_dir "$wt_active" "active worktree survives --max-age 0"

# --- 4. --all removes everything including active worktrees ----------------
run "$HARNESS/bin/worktree-gc" --all
assert_rc 0 "gc --all succeeds"
assert_out "agent-gc-active" "active worktree is reported removed with --all"

if [ -d "$wt_active" ]; then
  echo "  ASSERTION FAILED: active worktree should be removed with --all"
  exit 1
fi

# Non-agent is STILL kept even with --all.
assert_dir "$wt_human" "non-agent worktree survives even --all"

# Clean up the non-agent worktree.
git -C "$REPO" worktree remove --force "$wt_human" 2>/dev/null || true
