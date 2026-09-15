# dispatch-run creates an isolated worktree for the worker agent, runs it
# inside the worktree (cwd = worktree), and checks for HANDOFF.md at the
# known path instead of polling all worktrees.
#
# Uses a mock agent (unattended.agent.cmd) that writes HANDOFF.md and a
# proof marker, so the pipeline completes without a real claude -p session.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/tracker" set i-wt-test title="worktree test" description="test dispatch-run worktree creation"
assert_rc 0 "file the issue"

# A mock agent: writes HANDOFF.md so the pipeline advances. When it detects
# .dispatch-issue (present only in the worktree, not the main checkout), it
# writes a proof marker. The verifier stage runs the same mock in the main
# checkout, where .dispatch-issue is absent, so only the worker leaves proof.
mock="$TEST_TMP/mock-agent.sh"
cat > "$mock" <<'MOCK'
#!/bin/sh
cat > HANDOFF.md <<'HO'
changed: test file
found: none
assumed: none
next: none
HO
if [ -f .dispatch-issue ]; then
  echo "worker" > .worker-proof
fi
MOCK
chmod +x "$mock"

# Point unattended.agent.cmd at the mock.
python3 -c '
import json, sys
cfg_path, mock_path = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = json.load(f)
cfg["unattended"] = {"agent": {"cmd": ["sh", mock_path]}}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
' "$REPO/config.json" "$mock"

# Commit so the worktree (branched from HEAD) has the config.
git -C "$REPO" add config.json .gitignore
git -C "$REPO" commit -qm "init + mock agent"

run "$HARNESS/bin/dispatch-run" i-wt-test \
  --brief "test the worktree" --files "src/main.c" \
  --force --timeout 60
assert_rc 0 "dispatch-run completes the full pipeline"
assert_out "worktree ready" "step 1.5 created the worktree"
assert_out "HANDOFF.md found" "step 3 found HANDOFF.md at the known path"
assert_out "READY FOR FOLD" "the pipeline reported ready for fold"

# The worktree must exist and carry the dispatch marker.
wt_dir=$(ls -d "$REPO/.claude/worktrees"/dispatch-i-wt-test-* 2>/dev/null | head -1)
assert_dir "$wt_dir" "a dispatch worktree was created"
assert_file "$wt_dir/.dispatch-issue" "dispatch-run pre-wrote the issue marker"

# The worker ran INSIDE the worktree (proof marker present), not in the main
# checkout (proof marker absent there — the verifier mock runs in main but
# .dispatch-issue is absent so it skips the proof).
assert_file "$wt_dir/.worker-proof" "worker ran inside the worktree"
assert_no_file "$REPO/.worker-proof" "worker did not run in the main checkout"
