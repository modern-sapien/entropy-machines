# create_report MCP tool — generates HTML sprint reports and dialogue docs,
# registers them in manifest.json and SQLite.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# bin/init seeds the PRD directly into SQLite — no migrate-db needed.

# Helper: send one JSON-RPC line to mcp-serve, capture the response.
mcp_call() {
  printf '%s\n' "$1" > "$TEST_TMP/.mcp_in"
  _mcp="$HARNESS/bin/mcp-serve"
  _in="$TEST_TMP/.mcp_in"
  run_in "$REPO" sh -c "exec '$_mcp' < '$_in'"
}

# --- tools/list includes create_report ----------------------------------------
mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
assert_rc 0 "tools/list completes"
assert_out '"create_report"' "tools/list includes create_report"

# --- create a sprint report ---------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_report","arguments":{"doc_type":"sprint-report","title":"Sprint Report: MCP Test","slug":"mcp-test","subtitle":"2026-09-14","sections":[{"nav_title":"0 · Summary","heading":"Sprint Report: MCP Test","subtitle":"2026-09-14 · Test sprint","content":"<p>Summary content.</p>","response":{"key":"s-summary","label":"On the sprint","discuss":"Any thoughts?"}},{"nav_title":"1 · Delivered","heading":"Delivered","content":"<p>Items delivered.</p>"}]}}}'
assert_rc 0 "create_report sprint-report completes"
assert_out "SPRINT-REPORT-mcp-test.html" "result names the generated file"
assert_out "manifest_registered" "result confirms manifest registration"
assert_out "db_created" "result confirms SQLite creation"

# --- verify the HTML file exists and has correct structure --------------------
[ -f "$REPO/entropy-machines-docs/SPRINT-REPORT-mcp-test.html" ] || \
  _fail "HTML file must exist on disk" "file not found"

_html=$(cat "$REPO/entropy-machines-docs/SPRINT-REPORT-mcp-test.html")
case "$_html" in
  *'<title>Sprint Report: MCP Test</title>'*) ;;
  *) _fail "HTML must have correct title tag" "title tag not found" ;;
esac
case "$_html" in
  *'data-resp="s-summary"'*) ;;
  *) _fail "HTML must have response box" "data-resp not found" ;;
esac
case "$_html" in
  *'__disk-save-patch'*) ;;
  *) _fail "HTML must have disk save patch" "disk-save-patch not found" ;;
esac
case "$_html" in
  *'__livereload-patch'*) ;;
  *) _fail "HTML must have live reload patch" "livereload-patch not found" ;;
esac
case "$_html" in
  *'__theme-options-patch'*) ;;
  *) _fail "HTML must have theme options" "theme-options-patch not found" ;;
esac
case "$_html" in
  *'TRACKER.html'*) ;;
  *) _fail "HTML must have category nav links" "TRACKER.html link not found" ;;
esac

# --- verify manifest.json was updated ----------------------------------------
_manifest=$(cat "$REPO/entropy-machines-docs/manifest.json")
case "$_manifest" in
  *'"sprint-report-mcp-test"'*) ;;
  *) _fail "manifest.json must contain the new doc id" "sprint-report-mcp-test not found" ;;
esac
case "$_manifest" in
  *'"SPRINT-REPORT-mcp-test.html"'*) ;;
  *) _fail "manifest.json must have correct filename" "filename not found" ;;
esac

# --- verify doc exists in SQLite via get_doc ----------------------------------
mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_doc","arguments":{"doc_id":"sprint-report-mcp-test"}}}'
assert_rc 0 "get_doc for the created report completes"
assert_out "Sprint Report: MCP Test" "get_doc returns the report title"
assert_out "report" "doc type is report"
assert_out "pages" "get_doc includes pages"
assert_out "responses" "get_doc includes responses"

# --- duplicate detection: creating the same report again must fail ------------
mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_report","arguments":{"doc_type":"sprint-report","title":"Sprint Report: MCP Test","slug":"mcp-test","sections":[{"nav_title":"0 · Summary","heading":"Summary","content":"<p>Dupe.</p>"}]}}}'
assert_rc 0 "duplicate create does not crash"
assert_out "isError" "duplicate file returns isError"
assert_out "already exists" "error message says file already exists"

# --- create a dialogue doc ----------------------------------------------------
mcp_call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_report","arguments":{"doc_type":"dialogue","title":"Design: Widget System","slug":"design-widgets","sections":[{"nav_title":"0 · Context","heading":"Context","content":"<p>Widget context.</p>","response":{"key":"q-context","label":"Your read","discuss":"Is this right?"}}]}}}'
assert_rc 0 "create_report dialogue completes"
assert_out "design-widgets.html" "dialogue result names the file"
assert_out "db_created" "dialogue doc created in SQLite"

[ -f "$REPO/entropy-machines-docs/design-widgets.html" ] || \
  _fail "dialogue HTML file must exist" "file not found"

mcp_call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_doc","arguments":{"doc_id":"design-widgets"}}}'
assert_rc 0 "get_doc for dialogue doc completes"
assert_out "doc" "dialogue doc type is doc"

# --- validation: missing required fields must fail ----------------------------
mcp_call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"create_report","arguments":{"doc_type":"sprint-report","title":"No Sections","slug":"no-sections","sections":[]}}}'
assert_rc 0 "empty sections does not crash"
assert_out "isError" "empty sections returns isError"
