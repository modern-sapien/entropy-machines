# lib/mcp_server.py — update_doc MCP tool: writes data-informational
# sections into the pages table, rejects response-box content.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# Build a manifest so migrate-db has a doc to import.
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
mcp_call() {
  printf '%s\n' "$1" > "$TEST_TMP/.mcp_in"
  _mcp="$HARNESS/bin/mcp-serve"
  _in="$TEST_TMP/.mcp_in"
  run_in "$REPO" sh -c "exec '$_mcp' < '$_in'"
}

# Create a doc with two pages so we have known content to update.
mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_doc","arguments":{"id":"test-doc","title":"Test Doc","type":"doc","pages":[{"id":"p0","position":0,"heading":"Page Zero","content":"<h2 data-informational>Original</h2><p>original content</p>"},{"id":"p1","position":1,"heading":"Page One","content":"<p>page one original</p>"}],"responses":[{"page_id":"p0","resp_key":"p0-q1","label":"Your answer","discuss":"What do you think?"}]}}}'
assert_rc 0 "create_doc completes"
assert_out "test-doc" "created doc id is in the response"

# --- tools/list includes update_doc -------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
assert_rc 0 "tools/list completes"
assert_out '"update_doc"' "tools/list includes update_doc"

# --- update_doc: update one page ----------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{"p0":"<h2 data-informational>Updated</h2><p>new content</p>"}}}}'
assert_rc 0 "update_doc completes"
assert_out "new content" "updated content is in the response"
assert_not_out "isError" "update_doc did not return an error"

# --- update_doc: update multiple pages ----------------------------------------
mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{"p0":"<p>both updated p0</p>","p1":"<p>both updated p1</p>"}}}}'
assert_rc 0 "update_doc multiple pages completes"
assert_out "both updated p0" "p0 content was updated"
assert_out "both updated p1" "p1 content was updated"

# --- verify via get_doc that content persisted --------------------------------
mcp_call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_doc","arguments":{"doc_id":"test-doc"}}}'
assert_rc 0 "get_doc after update completes"
assert_out "both updated p0" "p0 content persisted in get_doc"
assert_out "both updated p1" "p1 content persisted in get_doc"

# --- update_doc: reject content with response box ----------------------------
mcp_call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{"p0":"<div class=\"response\" data-resp=\"sneaky\"><textarea></textarea></div>"}}}}'
assert_rc 0 "update_doc with response box does not crash"
assert_out "isError" "response box content returns isError"
assert_out "response box" "error mentions response box"

# --- update_doc: reject nonexistent page --------------------------------------
mcp_call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{"p99":"<p>ghost</p>"}}}}'
assert_rc 0 "update_doc with missing page does not crash"
assert_out "isError" "missing page returns isError"
assert_out "no such page" "error names the missing page"

# --- update_doc: reject nonexistent doc ---------------------------------------
mcp_call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"no-such-doc","sections":{"p0":"<p>hello</p>"}}}}'
assert_rc 0 "update_doc with missing doc does not crash"
assert_out "isError" "missing doc returns isError"

# --- update_doc: reject empty sections ----------------------------------------
mcp_call '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{}}}}'
assert_rc 0 "update_doc with empty sections does not crash"
assert_out "isError" "empty sections returns isError"

# --- update_doc: reject non-string content ------------------------------------
mcp_call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_doc","arguments":{"doc_id":"test-doc","sections":{"p0":42}}}}'
assert_rc 0 "update_doc with non-string content does not crash"
assert_out "isError" "non-string content returns isError"
