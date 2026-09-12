# lib/mcp_server.py — MCP protocol over stdio wrapping lib/api.py.
# Exercises tools/list, tools/call for each tool, and error paths:
# unknown tool, missing required argument, unknown method.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# Build the manifest so migrate-db has a doc to import.
cat > "$REPO/entropy-machines-docs/manifest.json" <<'JSON'
{
  "docs": {
    "prd-001": {
      "file": "PRD-001-orientation.html",
      "title": "First-run orientation",
      "status": "open",
      "version": 0
    }
  }
}
JSON

run "$HARNESS/bin/migrate-db" --force
assert_rc 0 "bin/migrate-db --force builds the db"

# Helper: send one JSON-RPC line to mcp-serve, capture the response.
# Cannot pipe into run_in (the pipe creates a subshell that discards the
# variable updates run_in makes).  Write input to a file and redirect.
mcp_call() {
  printf '%s\n' "$1" > "$TEST_TMP/.mcp_in"
  _mcp="$HARNESS/bin/mcp-serve"
  _in="$TEST_TMP/.mcp_in"
  run_in "$REPO" sh -c "exec '$_mcp' < '$_in'"
}

# --- initialize ---------------------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
assert_rc 0 "initialize completes"
assert_out '"protocolVersion"' "initialize returns protocol version"
assert_out '"capabilities"' "initialize returns capabilities"
assert_out '"tools"' "capabilities include tools"

# --- tools/list ----------------------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
assert_rc 0 "tools/list completes"
assert_out '"list_issues"' "tools/list includes list_issues"
assert_out '"get_issue"' "tools/list includes get_issue"
assert_out '"create_issue"' "tools/list includes create_issue"
assert_out '"update_issue"' "tools/list includes update_issue"
assert_out '"list_issue_events"' "tools/list includes list_issue_events"
assert_out '"add_issue_event"' "tools/list includes add_issue_event"
assert_out '"list_docs"' "tools/list includes list_docs"
assert_out '"get_doc"' "tools/list includes get_doc"
assert_out '"inputSchema"' "each tool has an inputSchema"

# --- tools/call: list_issues (empty) ------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_issues","arguments":{}}}'
assert_rc 0 "list_issues (empty) completes"
assert_out '"content"' "result has content array"
assert_out '"text"' "content has text entries"

# --- tools/call: create_issue -------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_issue","arguments":{"id":"i-mcp-test","title":"MCP test issue","description":"created via MCP"}}}'
assert_rc 0 "create_issue completes"
assert_out "i-mcp-test" "created issue id is in the response"
assert_out "MCP test issue" "created issue title is in the response"

# --- tools/call: get_issue ----------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-mcp-test"}}}'
assert_rc 0 "get_issue completes"
assert_out "i-mcp-test" "get_issue returns the issue"
assert_out "created via MCP" "get_issue includes the description"

# --- tools/call: update_issue -------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_issue","arguments":{"issue_id":"i-mcp-test","status":"progress"}}}'
assert_rc 0 "update_issue completes"
assert_out "progress" "updated status is in the response"

# --- tools/call: list_issues with status filter --------------------------------
mcp_call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_issues","arguments":{"status":"progress"}}}'
assert_rc 0 "list_issues with status filter completes"
assert_out "i-mcp-test" "filtered list includes the in-progress issue"

# --- tools/call: add_issue_event ----------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"add_issue_event","arguments":{"issue_id":"i-mcp-test","content":"an event via MCP","author":"test-agent"}}}'
assert_rc 0 "add_issue_event completes"
assert_out "an event via MCP" "the event content is in the response"

# --- tools/call: list_issue_events --------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_issue_events","arguments":{"issue_id":"i-mcp-test"}}}'
assert_rc 0 "list_issue_events completes"
assert_out "an event via MCP" "the event appears in the list"

# --- tools/call: list_docs ----------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"list_docs","arguments":{}}}'
assert_rc 0 "list_docs completes"
assert_out "PRD-001" "list_docs includes the migrated doc"

# --- tools/call: get_doc ------------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_doc","arguments":{"doc_id":"PRD-001-orientation"}}}'
assert_rc 0 "get_doc completes"
assert_out "pages" "get_doc includes pages"
assert_out "responses" "get_doc includes responses"

# --- error: unknown tool -------------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}'
assert_rc 0 "unknown tool does not crash"
assert_out "isError" "unknown tool returns isError"

# --- error: get nonexistent issue ----------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"get_issue","arguments":{"issue_id":"i-no-such"}}}'
assert_rc 0 "get nonexistent issue does not crash"
assert_out "isError" "missing issue returns isError"

# --- error: unknown method -----------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":14,"method":"not/a/method","params":{}}'
assert_rc 0 "unknown method does not crash"
assert_out '"error"' "unknown method returns an error"
assert_out "method not found" "error names the method"

# --- ping ----------------------------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":15,"method":"ping","params":{}}'
assert_rc 0 "ping completes"
assert_out '"result"' "ping returns a result"

# --- parse error ---------------------------------------------------------------
mcp_call 'not json at all'
assert_rc 0 "parse error does not crash"
assert_out "parse error" "malformed input returns a parse error"
