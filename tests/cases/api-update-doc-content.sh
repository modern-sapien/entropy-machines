# PUT /api/docs/:id/content — REST route for update_doc_content.
# Verifies the route accepts sections, rejects response-box content,
# rejects nonexistent pages, and rejects nonexistent docs.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

PORT=$(free_port)
LOG="$TEST_TMP/serve.log"
SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
trap 'stop_server' EXIT INT TERM

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
wait_for_line "$LOG" "http://localhost:$PORT" 80 || {
  OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC="(still running)"; LAST_CMD="bin/serve $PORT"
  _fail "bin/serve must start" "nothing matching http://localhost:$PORT in $LOG"
}

BASE="http://127.0.0.1:$PORT"

# Create a doc with two pages so we have known content to update.
run http_json POST "$BASE/api/docs" '{"id":"content-test","title":"Content Test","type":"doc","pages":[{"id":"p0","position":0,"heading":"Page Zero","content":"<h2>Original</h2><p>original content</p>"},{"id":"p1","position":1,"heading":"Page One","content":"<p>page one original</p>"}],"responses":[{"page_id":"p0","resp_key":"ct-q1","label":"A question"}]}'
assert_rc 0 "POST /api/docs creates the test doc"
case "$OUT" in 201*) ;; *) _fail "creating the doc must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- PUT /api/docs/:id/content — update one page ---------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{"p0":"<h2>Updated</h2><p>new content</p>"}}'
assert_rc 0 "PUT /api/docs/:id/content completes"
case "$OUT" in 200*) ;; *) _fail "updating doc content must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "new content" "updated content is in the response"

# --- verify the update persisted via GET ------------------------------------------
run http_get "$BASE/api/docs/content-test"
assert_rc 0 "GET the doc after content update completes"
assert_out "new content" "updated content round-trips from the db"
assert_out "page one original" "the untouched page is unchanged"

# --- update multiple pages --------------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{"p0":"<p>both updated p0</p>","p1":"<p>both updated p1</p>"}}'
assert_rc 0 "PUT /api/docs/:id/content with multiple pages completes"
case "$OUT" in 200*) ;; *) _fail "multi-page content update must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "both updated p0" "p0 content was updated"
assert_out "both updated p1" "p1 content was updated"

# --- reject content with response box markup --------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{"p0":"<div class=\"response\" data-resp=\"sneaky\"><textarea></textarea></div>"}}'
case "$OUT" in 400*) ;; *) _fail "response box content must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "response box" "error mentions response box"

# --- reject nonexistent page ------------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{"p99":"<p>ghost</p>"}}'
case "$OUT" in 404*) ;; *) _fail "nonexistent page must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "no such page" "error names the missing page"

# --- reject nonexistent doc -------------------------------------------------------
run http_json PUT "$BASE/api/docs/no-such-doc/content" '{"sections":{"p0":"<p>hello</p>"}}'
case "$OUT" in 404*) ;; *) _fail "nonexistent doc must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- reject empty sections --------------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{}}'
case "$OUT" in 400*) ;; *) _fail "empty sections must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- reject missing sections key --------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"content":"<p>wrong key</p>"}'
case "$OUT" in 400*) ;; *) _fail "missing sections key must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- reject non-string content ----------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '{"sections":{"p0":42}}'
case "$OUT" in 400*) ;; *) _fail "non-string content must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- reject non-object body -------------------------------------------------------
run http_json PUT "$BASE/api/docs/content-test/content" '"just a string"'
case "$OUT" in 400*) ;; *) _fail "non-object body must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

stop_server
