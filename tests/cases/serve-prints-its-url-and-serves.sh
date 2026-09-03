# bin/serve, backgrounded with its output going to a FILE rather than a tty —
# which is exactly how a bootstrapping agent starts it and then reads the URL
# back out to hand to a human.
#
# THE URL IS THE ONE THING THIS COMMAND EXISTS TO PRODUCE, and until 2026-08-29
# it produced nothing: Python block-buffers stdout when it is not a tty, the
# very next statement blocks in serve_forever() forever, so the buffer was
# never filled and never drained. The log stayed 0 bytes while the server ran
# and 0 bytes after it was killed. That is why this case redirects to a file
# instead of using a pty — a pty would line-buffer and pass a broken build.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

PORT=$(free_port)
LOG="$TEST_TMP/serve.log"
SERVED=0

SERVER2_PID=""
stop_server() {
  if [ -n "$SERVER2_PID" ]; then
    kill "$SERVER2_PID" 2>/dev/null; wait "$SERVER2_PID" 2>/dev/null
    SERVER2_PID=""
  fi
  [ "$SERVED" -eq 0 ] && return 0
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVED=0
  return 0
}
# Kill both servers however this case ends, including an assertion failure.
trap 'stop_server' EXIT INT TERM

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
SERVED=1

if ! wait_for_line "$LOG" "http://localhost:$PORT" 80; then
  OUT=$(cat "$LOG" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT (backgrounded, stdout to a file)"
  _fail "bin/serve must PRINT ITS URL when backgrounded, within 8s" \
        "nothing matching http://localhost:$PORT appeared in $LOG"
fi

OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC=0; LAST_CMD="bin/serve $PORT"
assert_out "serving $REPO" "the URL line names the project it is serving"
assert_out "docs: $REPO/entropy-machines-docs" "and the docs directory it will serve from"

# --- GET / ------------------------------------------------------------------
run http_get "http://127.0.0.1:$PORT/"
assert_rc 0 "GET / completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET / must return 200" "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "<!doctype html>" "the dashboard is an HTML page"
assert_out "the factory" "titled as the factory dashboard"

# --- GET a doc --------------------------------------------------------------
run http_get "http://127.0.0.1:$PORT/PRD-001-orientation.html"
assert_rc 0 "GET a doc completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET a real doc must return 200" "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "data-resp" "the served doc still carries its response boxes"

# --- an unknown path is a 404, not a 200 of something else ------------------
run http_get "http://127.0.0.1:$PORT/no-such-doc.html"
assert_rc 0 "GET an unknown doc completes"
case "$OUT" in
  404*) ;;
  *) _fail "an unknown doc must 404" "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- a second serve on the same port falls back to a different port ---------
LOG2="$TEST_TMP/serve2.log"
( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG2" 2>&1 &
SERVER2_PID=$!

if ! wait_for_line "$LOG2" "http://localhost:" 80; then
  OUT=$(cat "$LOG2" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT (second instance, backgrounded)"
  _fail "second bin/serve must start and print its URL within 8s" \
        "nothing matching http://localhost: appeared in $LOG2"
fi

OUT=$(cat "$LOG2"); ERR=""; ALL="$OUT"; RC=0; LAST_CMD="bin/serve $PORT (second instance)"

# It must NOT have landed on the original port.
case "$OUT" in
  *"http://localhost:$PORT"*)
    _fail "second server must land on a DIFFERENT port" \
          "it claimed http://localhost:$PORT which is already held" ;;
esac

# It must have printed the busy notice (to stderr, captured in the same log).
assert_out "busy, scanning for an open port" \
  "second server reports the requested port was busy"

# Clean up both servers.
kill "$SERVER2_PID" 2>/dev/null; wait "$SERVER2_PID" 2>/dev/null; SERVER2_PID=""
stop_server

# --- a non-numeric port is refused before anything binds --------------------
run_in "$REPO" "$HARNESS/bin/serve" not-a-port
assert_rc_nonzero "a non-numeric port is refused"
assert_out "must be a number" "naming what was wrong with it"
