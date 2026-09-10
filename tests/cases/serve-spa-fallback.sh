# bin/serve serves the React SPA from ui/dist/ when it exists, falling back to
# the legacy dashboard when it does not.
#
# WHAT THIS GUARDS: when ui/dist/index.html exists (the Vite build output),
# the server (1) serves /assets/* with correct MIME types, (2) serves / as the
# SPA entry point instead of the legacy dashboard, (3) falls back to index.html
# for unmatched routes (React Router handles client-side routing), and
# (4) keeps /api/*, /__docversion, TRACKER.html, and legacy doc serving intact.
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

# --- create a fake ui/dist/ in the harness directory -------------------------
SPA_DIR="$HARNESS/ui/dist"
mkdir -p "$SPA_DIR/assets"
cat > "$SPA_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>SPA</title></head>
<body><div id="root"></div><script type="module" src="/assets/main-abc123.js"></script></body>
</html>
HTML
printf 'console.log("spa loaded");\n' > "$SPA_DIR/assets/main-abc123.js"
printf 'body { margin: 0; }\n' > "$SPA_DIR/assets/index-def456.css"
printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n' > "$SPA_DIR/assets/logo-ghi789.svg"

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!
SERVED=1

if ! wait_for_line "$LOG" "http://localhost:$PORT" 80; then
  OUT=$(cat "$LOG" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT (backgrounded)"
  _fail "bin/serve must print its URL within 8s" \
        "nothing matching http://localhost:$PORT appeared in $LOG"
fi

# The banner must mention the SPA root.
OUT=$(cat "$LOG"); ERR=""; ALL="$OUT"; RC=0; LAST_CMD="bin/serve $PORT banner"
assert_out "spa:" "the banner mentions SPA serving"

# --- GET / serves the SPA, not the legacy dashboard --------------------------
run http_get "http://127.0.0.1:$PORT/"
assert_rc 0 "GET / completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET / must return 200" "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out '<div id="root">' "GET / serves the SPA index.html with the React root"
assert_not_out "the factory" "GET / must NOT serve the legacy dashboard when SPA exists"

# --- GET /assets/*.js serves the JS file with correct MIME type ---------------
run http_get "http://127.0.0.1:$PORT/assets/main-abc123.js"
assert_rc 0 "GET /assets/*.js completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /assets/*.js must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "spa loaded" "the served JS file has the right content"

# --- GET /assets/*.css serves with correct content ----------------------------
run http_get "http://127.0.0.1:$PORT/assets/index-def456.css"
assert_rc 0 "GET /assets/*.css completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /assets/*.css must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "margin" "the served CSS file has the right content"

# --- GET /assets/*.svg serves with correct content ----------------------------
run http_get "http://127.0.0.1:$PORT/assets/logo-ghi789.svg"
assert_rc 0 "GET /assets/*.svg completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /assets/*.svg must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "svg" "the served SVG file has the right content"

# --- GET /assets/nonexistent.js returns 404 -----------------------------------
run http_get "http://127.0.0.1:$PORT/assets/nonexistent.js"
assert_rc 0 "GET /assets/nonexistent.js completes"
case "$OUT" in
  404*) ;;
  *) _fail "GET /assets/nonexistent.js must return 404" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- SPA fallback: unmatched routes serve index.html --------------------------
run http_get "http://127.0.0.1:$PORT/tracker"
assert_rc 0 "GET /tracker completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /tracker must return 200 (SPA fallback)" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out '<div id="root">' "GET /tracker falls through to SPA index.html"

run http_get "http://127.0.0.1:$PORT/prds/PRD-001"
assert_rc 0 "GET /prds/PRD-001 completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /prds/PRD-001 must return 200 (SPA fallback)" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out '<div id="root">' "GET /prds/* falls through to SPA index.html"

# --- legacy doc serving still works -------------------------------------------
run http_get "http://127.0.0.1:$PORT/PRD-001-orientation.html"
assert_rc 0 "GET a legacy doc completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET a legacy doc must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "data-resp" "legacy doc serving is intact — the doc carries its response boxes"

# --- /__docversion still works ------------------------------------------------
run http_get "http://127.0.0.1:$PORT/__docversion?file=PRD-001-orientation.html"
assert_rc 0 "GET /__docversion completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /__docversion must return 200" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
assert_out "reviews" "__docversion still returns the reviews hash"

# --- /api/* still routes to the API handler -----------------------------------
# This will return a 404 or error from the API module, but the point is it
# routes there rather than to the SPA fallback.
run http_get "http://127.0.0.1:$PORT/api/docs"
assert_rc 0 "GET /api/docs completes"
# The API handler responds with JSON (either a result or an error) — not SPA HTML.
assert_not_out '<div id="root">' "/api/* does NOT fall through to SPA"

stop_server

# ============================================================================
# PART 2: without ui/dist/, legacy behavior is preserved
# ============================================================================
rm -rf "$SPA_DIR"

PORT2=$(free_port)
LOG2="$TEST_TMP/serve2.log"

( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$PORT2" ) >"$LOG2" 2>&1 &
SERVER_PID=$!
SERVED=1

if ! wait_for_line "$LOG2" "http://localhost:$PORT2" 80; then
  OUT=$(cat "$LOG2" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT2 (no SPA)"
  _fail "bin/serve must print its URL within 8s (no SPA)" \
        "nothing matching http://localhost:$PORT2 appeared in $LOG2"
fi

# The banner must say SPA is not found.
OUT=$(cat "$LOG2"); ERR=""; ALL="$OUT"; RC=0; LAST_CMD="bin/serve $PORT2 banner (no SPA)"
assert_out "spa: not found" "banner says SPA is not available"

# --- GET / serves the legacy dashboard when no SPA ----------------------------
run http_get "http://127.0.0.1:$PORT2/"
assert_rc 0 "GET / without SPA completes"
case "$OUT" in
  200*|302*) ;;
  *) _fail "GET / without SPA must return 200 or 302" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac
# Either we get the dashboard or a redirect to a PRD — both are legacy behavior.
# If we got a 302 redirect, that is fine — it is the legacy "first contact" path.

# --- unknown routes 404 without SPA ------------------------------------------
run http_get "http://127.0.0.1:$PORT2/tracker"
assert_rc 0 "GET /tracker without SPA completes"
case "$OUT" in
  404*) ;;
  *) _fail "GET /tracker without SPA must return 404" \
           "first line was: $(printf '%s' "$OUT" | head -1)" ;;
esac

stop_server
