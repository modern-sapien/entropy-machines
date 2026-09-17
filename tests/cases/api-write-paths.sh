# lib/api.py's write paths — POST/PUT/PATCH — against a real migrated db.
# api-serves-docs-issues-and-settings.sh already exercises PUT responses,
# POST issues, PATCH issues and PUT settings on their happy paths; this case
# fills the gap it leaves: POST /api/docs (create_doc) and PUT /api/docs/:id
# (update_doc, including status transitions) are not touched there at all,
# and this case also adds edge cases the other one doesn't: value-type
# validation on a response PUT, a PATCH against an unknown issue, a
# multi-step issue status transition, and a null settings value.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# bin/init seeds the PRD directly into SQLite — no migrate-db needed.

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
DOC="PRD-001-orientation"
KEY="prd001-q1-suites"
NEWDOC="wtest-doc-1"

# --- POST /api/docs — create_doc -----------------------------------------------
run http_json POST "$BASE/api/docs" '{"id":"'"$NEWDOC"'","title":"A write-path test doc","type":"doc","pages":[{"id":"p0","content":"<p>hello</p>"}],"responses":[{"resp_key":"wt1-q1","label":"first question"}]}'
assert_rc 0 "POST /api/docs completes"
case "$OUT" in 201*) ;; *) _fail "creating a doc must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"$NEWDOC\"" "the created doc comes back"
assert_out "\"p0\"" "its page comes back"
assert_out "\"wt1-q1\"" "its response box comes back"

run http_get "$BASE/api/docs/$NEWDOC"
assert_rc 0 "GET the new doc completes"
case "$OUT" in 200*) ;; *) _fail "GET a freshly created doc must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "<p>hello</p>" "the page content round-trips from the db, not just the POST reply"

run http_get "$BASE/api/docs"
assert_out "\"$NEWDOC\"" "the new doc shows up in the doc list"

run http_json POST "$BASE/api/docs" '{"id":"'"$NEWDOC"'","title":"dup","type":"doc","pages":[]}'
case "$OUT" in 409*) ;; *) _fail "creating a duplicate doc id must 409" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/docs" '{"id":"wtest-doc-bad"}'
case "$OUT" in 400*) ;; *) _fail "creating a doc with no title/type must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/docs" '{"id":"wtest-doc-bad","title":"t","type":"doc","pages":"nope"}'
case "$OUT" in 400*) ;; *) _fail "\"pages\" must be an array, not a string, must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/docs" '{"id":"wtest-doc-bad","title":"t","type":"doc","pages":[{"id":"p0"}]}'
case "$OUT" in 400*) ;; *) _fail "a page missing content must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_get "$BASE/api/docs/wtest-doc-bad"
case "$OUT" in 404*) ;; *) _fail "a doc that failed validation must not have been partially created" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- PUT /api/docs/:id — update_doc, including status transitions -------------
run http_get "$BASE/api/docs/$NEWDOC"
assert_out "\"status\": \"open\"" "a freshly created doc defaults to open"

run http_json PUT "$BASE/api/docs/$NEWDOC" '{"status":"in-review"}'
assert_rc 0 "PUT a doc status completes"
case "$OUT" in 200*) ;; *) _fail "PUT a doc status must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"in-review\"" "the patched status comes back"

run http_get "$BASE/api/docs/$NEWDOC"
assert_out "\"status\": \"in-review\"" "and the status round-trips from the db"

run http_json PUT "$BASE/api/docs/$NEWDOC" '{"status":"closed","title":"A write-path test doc, closed out"}'
case "$OUT" in 200*) ;; *) _fail "a second status transition must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"closed\"" "the doc transitioned again"
assert_out "closed out" "and another field updated in the same PUT"

run http_json PUT "$BASE/api/docs/no-such-doc" '{"status":"closed"}'
case "$OUT" in 404*) ;; *) _fail "PUT an unknown doc must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json PUT "$BASE/api/docs/$NEWDOC" '{}'
case "$OUT" in 400*) ;; *) _fail "PUT a doc with no recognized fields must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- PUT a response value — saving a response box answer -----------------------
run http_json PUT "$BASE/api/docs/$DOC/responses/$KEY" '{"value":"write-path test answer"}'
assert_rc 0 "PUT a response value completes"
case "$OUT" in 200*) ;; *) _fail "PUT a response must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "write-path test answer" "the new value comes back"

run http_get "$BASE/api/docs/$DOC/responses/$KEY"
assert_out "write-path test answer" "and the value round-trips from the db, not just the PUT reply"

run http_json PUT "$BASE/api/docs/$DOC/responses/$KEY" '{"value":123}'
case "$OUT" in 400*) ;; *) _fail "a non-string response value must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- PATCH issue status transitions --------------------------------------------
run http_json POST "$BASE/api/issues" '{"id":"i-write-test","title":"a write-path test issue","description":"exercising PATCH transitions"}'
case "$OUT" in 201*) ;; *) _fail "creating the test issue must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"notstarted\"" "a freshly created issue defaults to notstarted"

run http_json PATCH "$BASE/api/issues/i-write-test" '{"status":"progress","claimed_by":"agent-write-test"}'
case "$OUT" in 200*) ;; *) _fail "PATCH to progress must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"progress\"" "the issue moved to progress"
assert_out "agent-write-test" "and the claim landed with it"

run http_json PATCH "$BASE/api/issues/i-write-test" '{"status":"done"}'
case "$OUT" in 200*) ;; *) _fail "PATCH to done must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"done\"" "the issue moved to done"

run http_get "$BASE/api/issues/i-write-test"
assert_out "\"status\": \"done\"" "and the final status round-trips from the db"

run http_json PATCH "$BASE/api/issues/no-such-issue" '{"status":"progress"}'
case "$OUT" in 404*) ;; *) _fail "PATCH an unknown issue must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json PATCH "$BASE/api/issues/i-write-test" '{"blocked_by":"not-a-list"}'
case "$OUT" in 400*) ;; *) _fail "\"blocked_by\" must be an array, not a string, must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json PATCH "$BASE/api/issues/i-write-test" '{}'
case "$OUT" in 400*) ;; *) _fail "PATCH an issue with no recognized fields must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- PUT /api/settings — including a null value --------------------------------
run http_json PUT "$BASE/api/settings/write-test-flag" '{"value":"on"}'
case "$OUT" in 200*) ;; *) _fail "PUT a setting must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_get "$BASE/api/settings/write-test-flag"
assert_out "\"value\": \"on\"" "the stored value round-trips"

run http_json PUT "$BASE/api/settings/write-test-flag" '{"value":null}'
case "$OUT" in 200*) ;; *) _fail "PUT a null setting value must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"value\": null" "a null value is accepted and echoed back"

run http_get "$BASE/api/settings/write-test-flag"
assert_out "\"value\": null" "and a null value round-trips from the db"

run http_json PUT "$BASE/api/settings/write-test-flag" '{}'
case "$OUT" in 400*) ;; *) _fail "PUT a setting with no \"value\" key must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json PUT "$BASE/api/settings/write-test-flag" '{"value":42}'
case "$OUT" in 400*) ;; *) _fail "a non-string, non-null setting value must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

stop_server
