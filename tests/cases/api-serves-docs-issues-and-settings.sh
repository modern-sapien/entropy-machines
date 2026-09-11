# lib/api.py's /api/* endpoints — the REST surface the React SPA (ui/) reads
# and writes through (entropy-machines-docs/PRD-006-react-migration.html,
# page p4). Exercises every route in that table against a real migrated db:
# docs, responses + replies, issues + notes, settings — both the happy path
# and the refusals (missing doc/issue/setting, malformed body, wrong method,
# duplicate id), plus the "no db yet" 503 before migration ever runs.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# migrate_db.py reads entropy-machines-docs/manifest.json as its list of docs
# to migrate, and nothing in `bin/init` writes one — a brand-new project has
# no doc history to report until something calls docstate.store() for the
# first time, which plain serving never does. That gap belongs to
# lib/migrate_db.py, not to this case; write the minimal manifest by hand so
# migrating PRD-001 does not depend on it being closed first.
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

PORT=$(free_port)
LOG="$TEST_TMP/serve.log"
SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
trap 'stop_server' EXIT INT TERM

# --- before migration: /api/* must refuse clearly, not crash or fake a 200 --
( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
wait_for_line "$LOG" "http://localhost:$PORT" 80 || {
  OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC="(still running)"; LAST_CMD="bin/serve $PORT"
  _fail "bin/serve must start" "nothing matching http://localhost:$PORT in $LOG"
}

run http_get "http://127.0.0.1:$PORT/api/docs"
assert_rc 0 "GET /api/docs before migration completes"
case "$OUT" in
  503*) ;;
  *) _fail "GET /api/docs with no db must 503, not 500 or a fake 200" \
        "first line: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "run bin/migrate-db" "the 503 names the fix"

stop_server

# --- migrate, then serve for real --------------------------------------------
run "$HARNESS/bin/migrate-db" --force
assert_rc 0 "bin/migrate-db --force builds the db"

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
wait_for_line "$LOG" "http://localhost:$PORT" 80 || {
  OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC="(still running)"; LAST_CMD="bin/serve $PORT"
  _fail "bin/serve must restart after migration" "nothing matching http://localhost:$PORT in $LOG"
}

BASE="http://127.0.0.1:$PORT"
DOC="PRD-001-orientation"
KEY="prd001-q1-suites"

# --- docs ---------------------------------------------------------------------
run http_get "$BASE/api/docs"
assert_rc 0 "GET /api/docs completes"
case "$OUT" in 200*) ;; *) _fail "GET /api/docs must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"$DOC\"" "the migrated doc is listed"
assert_out "\"counts\"" "each doc reports answered/total counts"

run http_get "$BASE/api/docs/$DOC"
assert_rc 0 "GET /api/docs/:id completes"
case "$OUT" in 200*) ;; *) _fail "GET /api/docs/:id must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"pages\"" "a single doc carries its pages"
assert_out "\"responses\"" "and its responses"

run http_get "$BASE/api/docs/no-such-doc"
assert_rc 0 "GET an unknown doc completes"
case "$OUT" in 404*) ;; *) _fail "an unknown doc must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- responses + replies -------------------------------------------------------
run http_get "$BASE/api/docs/$DOC/responses"
assert_rc 0 "GET responses list completes"
assert_out "\"$KEY\"" "a known response key is in the list"

run http_json PUT "$BASE/api/docs/$DOC/responses/$KEY" '{"value":"the owner answered here"}'
assert_rc 0 "PUT a response value completes"
case "$OUT" in 200*) ;; *) _fail "PUT a response must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "the owner answered here" "the new value comes back"

run http_get "$BASE/api/docs/$DOC/responses/$KEY"
assert_rc 0 "GET the same response completes"
assert_out "the owner answered here" "and the value round-trips from the db, not just the PUT reply"

run http_json POST "$BASE/api/docs/$DOC/responses/$KEY/reply" '{"author":"agent","content":"looks good"}'
assert_rc 0 "POST a reply completes"
case "$OUT" in 201*) ;; *) _fail "POST a reply must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "looks good" "the reply content comes back"

run http_get "$BASE/api/docs/$DOC/responses/$KEY"
assert_out "looks good" "the reply shows up nested under its response"

run http_json PUT "$BASE/api/docs/$DOC/responses/$KEY" ''
assert_rc 0 "PUT with no body completes"
case "$OUT" in 400*) ;; *) _fail "PUT with no body must 400, not 500" "$(printf '%s' "$OUT" | head -1)" ;; esac

# --- issues + notes -------------------------------------------------------------
run http_get "$BASE/api/issues"
assert_rc 0 "GET /api/issues (empty) completes"
case "$OUT" in 200*) ;; *) _fail "GET /api/issues must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/issues" '{"id":"i-test-thing","title":"a test issue","description":"what this issue is about"}'
assert_rc 0 "POST /api/issues completes"
case "$OUT" in 201*) ;; *) _fail "creating an issue must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "i-test-thing" "the created issue comes back"

run http_json POST "$BASE/api/issues" '{"id":"i-test-thing","title":"dup","description":"dup desc"}'
case "$OUT" in 409*) ;; *) _fail "creating a duplicate issue id must 409" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/issues" '{"id":"i-bad"}'
case "$OUT" in 400*) ;; *) _fail "creating an issue with no title must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/issues" '{"id":"i-no-desc","title":"has a title but no description"}'
case "$OUT" in 400*) ;; *) _fail "creating an issue with no description must 400" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "description" "the 400 names the missing field"

run http_get "$BASE/api/issues/i-test-thing"
assert_rc 0 "GET a single issue completes"
assert_out "\"status\": \"open\"" "a freshly created issue defaults to open"

run http_json PATCH "$BASE/api/issues/i-test-thing" '{"status":"progress","claimed_by":"agent-x"}'
case "$OUT" in 200*) ;; *) _fail "PATCH an issue must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "\"status\": \"progress\"" "the patched status comes back"
assert_out "agent-x" "and the patched claim"

run http_get "$BASE/api/issues/no-such-issue"
case "$OUT" in 404*) ;; *) _fail "an unknown issue must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json POST "$BASE/api/issues/i-test-thing/events" '{"content":"a note","author":"tester"}'
case "$OUT" in 201*) ;; *) _fail "adding an event must 201" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_get "$BASE/api/issues/i-test-thing/events"
assert_rc 0 "GET issue events completes"
assert_out "a note" "the event is in the list"

# --- settings ---------------------------------------------------------------------
run http_get "$BASE/api/settings/theme"
case "$OUT" in 404*) ;; *) _fail "an unset setting must 404" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_json PUT "$BASE/api/settings/theme" '{"value":"janus-dark"}'
case "$OUT" in 200*) ;; *) _fail "PUT a setting must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac

run http_get "$BASE/api/settings/theme"
case "$OUT" in 200*) ;; *) _fail "GET the setting back must 200" "$(printf '%s' "$OUT" | head -1)" ;; esac
assert_out "janus-dark" "the stored value round-trips"

stop_server
