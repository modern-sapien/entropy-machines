# bin/serve renders TRACKER.html dynamically from live issues.json, without
# needing a manual `bin/tracker render` step.
#
# WHAT THIS GUARDS: the page the server hands back for GET /TRACKER.html
# reflects the CURRENT state of the issue store, not whatever was last
# rendered to disk by `bin/tracker render`. Changing an issue and immediately
# requesting the page must show the change — no render step in between.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

PORT=$(free_port)
LOG="$TEST_TMP/serve.log"
SERVED=0

stop_server() {
  [ "$SERVED" -eq 0 ] && return 0
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVED=0
  return 0
}
trap 'stop_server' EXIT INT TERM

# File an issue BEFORE starting the server, without rendering.
run "$HARNESS/bin/tracker" set i-alpha title="Alpha issue" effort=S description="alpha issue"
assert_rc 0 "file the first issue"

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
SERVED=1

if ! wait_for_line "$LOG" "http://localhost:$PORT" 80; then
  OUT=$(cat "$LOG" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT (backgrounded)"
  _fail "bin/serve must print its URL within 8s" \
        "nothing matching http://localhost:$PORT appeared in $LOG"
fi

# --- GET /TRACKER.html without ever running bin/tracker render ---------------
run http_get "http://127.0.0.1:$PORT/TRACKER.html"
assert_rc 0 "GET /TRACKER.html completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /TRACKER.html must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac

# The page must contain the issue we filed — proof it read the live store.
assert_out "i-alpha" "the live-rendered page contains the issue filed before serve started"
assert_out "Alpha issue" "with its title"

# --- file a SECOND issue while the server is running — no render step --------
run "$HARNESS/bin/tracker" set i-beta title="Beta issue" effort=M description="beta issue"
assert_rc 0 "file a second issue while the server is running"

# Request again — the new issue must appear WITHOUT running bin/tracker render.
run http_get "http://127.0.0.1:$PORT/TRACKER.html"
assert_rc 0 "second GET /TRACKER.html completes"
case "$OUT" in
  200*) ;;
  *) _fail "second GET must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "i-beta" "the new issue appears on the NEXT request — no render step needed"
assert_out "Beta issue" "with its title"
# The first issue must still be there too.
assert_out "i-alpha" "the first issue is still present"

# --- the page is the tracker view, not the dashboard -------------------------
assert_out "issue tracker" "it is the tracker view, not the dashboard"
# The tracker page carries its data in a JSON payload, not in rendered rows.
assert_out "tracker-data" "the page carries the tracker-data JSON block"

# --- a status change is reflected live ----------------------------------------
run "$HARNESS/bin/tracker" set i-alpha status=done
assert_rc 0 "mark the first issue done"

run http_get "http://127.0.0.1:$PORT/TRACKER.html"
assert_rc 0 "third GET after status change"

# Extract the flags for i-alpha from the payload to verify it shows as done.
# The payload is JSON inside a <script> tag; parse it the same way the
# tracker-render test does.
printf '%s' "$OUT" > "$TEST_TMP/tracker-body.html"
DONE_CHECK=$(python3 -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Drop the HTTP status line (first line from http_get).
text = text.split("\n", 1)[1] if "\n" in text else text
m = re.search(r"<script id=\"tracker-data\" type=\"application/json\">(.*?)</script>",
              text, re.S)
if not m:
    print("PAYLOAD-MISSING")
    sys.exit(0)
data = json.loads(m.group(1).replace("<\\/", "</"))
flags = data["issues"].get("i-alpha", {}).get("flags", [])
print("done" if "done" in flags else "NOT-DONE")
' "$TEST_TMP/tracker-body.html")
OUT="done-check= $DONE_CHECK"; ERR=""; ALL="$OUT"; RC=0
LAST_CMD="check i-alpha flags in live payload"
assert_out "done-check= done" \
  "marking an issue done is visible on the next request — no render step"

stop_server
