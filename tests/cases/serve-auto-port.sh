# bin/serve finds an open port automatically when the requested one is busy.
#
# Uses a bare python server as the blocker rather than a second bin/serve — that
# isolates the test to the scanning logic itself without depending on two
# full-stack servers.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
BLOCKER_PIDS=""

# block_port <port> — start a bare TCP listener on <port>.
block_port() {
  python3 -c '
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
s.serve_forever()
' "$1" &
  BLOCKER_PIDS="$BLOCKER_PIDS $!"
}

SERVER_PID=""
cleanup() {
  for _p in $BLOCKER_PIDS; do
    kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null
  done
  BLOCKER_PIDS=""
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
  fi
}
trap 'cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Single blocked port — serve lands on port+1
# ---------------------------------------------------------------------------
PORT=$(free_port)
block_port "$PORT"
# Give the blocker a moment to bind.
sleep 0.3

LOG="$TEST_TMP/serve-single.log"
( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!

if ! wait_for_line "$LOG" "http://localhost:" 80; then
  OUT=$(cat "$LOG" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve --no-open $PORT"
  _fail "bin/serve must start within 8s even when the port is busy" \
        "nothing matching http://localhost: appeared in $LOG"
fi

OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC=0
LAST_CMD="bin/serve --no-open $PORT (port blocked)"

# It must announce the port was busy.
assert_out "busy, scanning for an open port" \
  "serve reports the requested port was busy"

# It must NOT have landed on the blocked port.
case "$OUT" in
  *"http://localhost:$PORT"*)
    _fail "serve must land on a DIFFERENT port than the blocked one" \
          "it claimed http://localhost:$PORT which is held by the blocker" ;;
esac

# Extract the port it actually chose and verify it serves.
ACTUAL_PORT=$(printf '%s' "$OUT" | grep -o 'http://localhost:[0-9]*' | head -1 | sed 's|http://localhost:||')
[ -n "$ACTUAL_PORT" ] || _fail "could not extract the actual port from output" \
  "output was: $OUT"

run http_get "http://127.0.0.1:$ACTUAL_PORT/"
assert_rc 0 "GET / on the auto-selected port completes"
case "$OUT" in
  200*|404*) ;;
  *) _fail "GET / on the auto-selected port must return a valid HTTP status" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac

# Clean up server for next section.
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

# ---------------------------------------------------------------------------
# 2. Multiple consecutive blocked ports — serve skips past all of them
# ---------------------------------------------------------------------------
PORT2=$(free_port)
block_port "$PORT2"
NEXT1=$((PORT2 + 1))
block_port "$NEXT1"
NEXT2=$((NEXT1 + 1))
block_port "$NEXT2"
sleep 0.3

LOG2="$TEST_TMP/serve-multi.log"
( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT2" ) >"$LOG2" 2>&1 &
SERVER_PID=$!

if ! wait_for_line "$LOG2" "http://localhost:" 80; then
  OUT=$(cat "$LOG2" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve --no-open $PORT2 (3 consecutive ports blocked)"
  _fail "bin/serve must start within 8s with 3 consecutive ports blocked" \
        "nothing matching http://localhost: appeared in $LOG2"
fi

OUT=$(cat "$LOG2"); ERR=""; ALL="$OUT"; RC=0
LAST_CMD="bin/serve --no-open $PORT2 (3 consecutive ports blocked)"

assert_out "busy, scanning for an open port" \
  "serve reports the port was busy when multiple are blocked"

# It must not have landed on any of the three blocked ports.
for _blocked in "$PORT2" "$NEXT1" "$NEXT2"; do
  case "$OUT" in
    *"http://localhost:$_blocked"*)
      _fail "serve must not land on blocked port $_blocked" \
            "it claimed http://localhost:$_blocked" ;;
  esac
done

# Extract and verify.
ACTUAL_PORT2=$(printf '%s' "$OUT" | grep -o 'http://localhost:[0-9]*' | head -1 | sed 's|http://localhost:||')
[ -n "$ACTUAL_PORT2" ] || _fail "could not extract the actual port from output" \
  "output was: $OUT"

run http_get "http://127.0.0.1:$ACTUAL_PORT2/"
assert_rc 0 "GET / on the auto-selected port (after skipping 3) completes"

# Clean up.
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
