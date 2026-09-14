# MCP dispatch/handoff end-to-end flow.
# Exercises dispatch_issue, handoff_issue, get_ready_issues, and
# get_active_claims through the MCP JSON-RPC interface: claim state,
# events, and status transitions.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

run "$HARNESS/bin/migrate-db" --force
assert_rc 0 "bin/migrate-db --force builds the db"

# Helper: send one JSON-RPC line to mcp-serve, capture the response.
mcp_call() {
  printf '%s\n' "$1" > "$TEST_TMP/.mcp_in"
  _mcp="$HARNESS/bin/mcp-serve"
  _in="$TEST_TMP/.mcp_in"
  run_in "$REPO" sh -c "exec '$_mcp' < '$_in'"
}

# --- seed: create an issue via MCP ----------------------------------------
mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"id":"i-dispatch-test","title":"dispatch test issue","description":"exercise the full dispatch/handoff cycle"}}}'
assert_rc 0 "create_issue completes"
assert_out "i-dispatch-test" "created issue id is in the response"

# --- pre-dispatch: issue appears in get_ready_issues ----------------------
mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_ready_issues","arguments":{}}}'
assert_rc 0 "get_ready_issues completes"
assert_out "i-dispatch-test" "issue is ready before dispatch"

# --- pre-dispatch: get_active_claims is empty -----------------------------
mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_active_claims","arguments":{}}}'
assert_rc 0 "get_active_claims completes"
assert_not_out "i-dispatch-test" "issue is not in active claims before dispatch"

# --- dispatch the issue ---------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"dispatch_issue","arguments":{"issue_id":"i-dispatch-test","brief":"implement the widget","files":["src/widget.py","src/widget_test.py"],"agent_id":"test-agent-42"}}}'
assert_rc 0 "dispatch_issue completes"
assert_out "progress" "dispatch sets status to progress"
assert_out "test-agent-42" "dispatch sets claimed_by to the agent id"

# --- post-dispatch: verify via get_issue ----------------------------------
mcp_call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-dispatch-test"}}}'
assert_rc 0 "get_issue after dispatch completes"
assert_out "progress" "issue status is progress after dispatch"
assert_out "test-agent-42" "claimed_by is the dispatched agent"
assert_out "claimed_at" "claimed_at timestamp is present"

# --- post-dispatch: dispatch event was recorded ---------------------------
mcp_call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_issue_events","arguments":{"issue_id":"i-dispatch-test"}}}'
assert_rc 0 "list_issue_events after dispatch completes"
assert_out "dispatch" "a dispatch event was recorded"
assert_out "implement the widget" "dispatch event contains the brief"
assert_out "src/widget.py" "dispatch event contains the file scope"

# --- post-dispatch: issue is in active claims -----------------------------
mcp_call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_active_claims","arguments":{}}}'
assert_rc 0 "get_active_claims after dispatch completes"
assert_out "i-dispatch-test" "dispatched issue appears in active claims"

# --- post-dispatch: issue is NOT in ready issues --------------------------
mcp_call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_ready_issues","arguments":{}}}'
assert_rc 0 "get_ready_issues after dispatch completes"
assert_not_out "i-dispatch-test" "dispatched issue is no longer ready"

# --- handoff the issue ----------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"handoff_issue","arguments":{"issue_id":"i-dispatch-test","changed":"added widget module with tests","verified":"ran test suite, all green","found":["logging needs work"],"assumed":["config format stays stable"],"next":"hook widget into the main pipeline"}}}'
assert_rc 0 "handoff_issue completes"
assert_out "done" "handoff sets status to done"

# --- post-handoff: verify via get_issue -----------------------------------
mcp_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-dispatch-test"}}}'
assert_rc 0 "get_issue after handoff completes"
assert_out "done" "issue status is done after handoff"

# --- post-handoff: claim is cleared --------------------------------------
# claimed_by should be null after handoff
mcp_call '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-dispatch-test"}}}'
assert_rc 0 "re-read issue to check claim"
assert_not_out "test-agent-42" "claimed_by is cleared after handoff"

# --- post-handoff: handoff event was recorded -----------------------------
mcp_call '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"list_issue_events","arguments":{"issue_id":"i-dispatch-test"}}}'
assert_rc 0 "list_issue_events after handoff completes"
assert_out "handoff" "a handoff event was recorded"
assert_out "added widget module with tests" "handoff event contains what changed"
assert_out "ran test suite, all green" "handoff event contains verification"
assert_out "logging needs work" "handoff event contains findings"
assert_out "config format stays stable" "handoff event contains assumptions"
assert_out "hook widget into the main pipeline" "handoff event contains next steps"

# --- post-handoff: issue is NOT in active claims --------------------------
mcp_call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"get_active_claims","arguments":{}}}'
assert_rc 0 "get_active_claims after handoff completes"
assert_not_out "i-dispatch-test" "handed-off issue is no longer in active claims"

# --- handoff with explicit status override --------------------------------
# Create a second issue, dispatch it, then handoff with status=review
mcp_call '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"create_issue","arguments":{"id":"i-review-test","title":"review test issue","description":"test handoff with custom status"}}}'
assert_rc 0 "create second issue"

mcp_call '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"dispatch_issue","arguments":{"issue_id":"i-review-test","brief":"spike on caching"}}}'
assert_rc 0 "dispatch second issue"

mcp_call '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"handoff_issue","arguments":{"issue_id":"i-review-test","changed":"added cache layer","verified":"benchmarks pass","status":"review"}}}'
assert_rc 0 "handoff with status=review completes"

mcp_call '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-review-test"}}}'
assert_rc 0 "get second issue after handoff"
assert_out "review" "handoff respects explicit status override"
