# onboarding-smoke — what a real user experiences after `npm install
# entropy-machines`. No fixture_new, no vendor_harness, no fake ui/dist/: this
# case packs the actual tarball, installs it into a brand-new project the way
# a human would, and drives the real entry points from there. Every other
# serve case creates a fake ui/dist/index.html so the SPA path is active —
# useful for testing the server logic, but it means no case in this suite ever
# noticed that the npm delivery path (bin/entropy-machines-init's HARNESS_DIRS
# list) does not vendor ui/ at all, so a real install 404s on everything that
# isn't /api/*. THIS is the case that would have caught that.
. "$TEST_LIB/harness.sh"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "  SKIP: node/npm not available"
  exit 0
fi

# ---- pack the real package, exactly as it would be published ----
run_in "$ENTROPY_SRC" npm pack --pack-destination "$TEST_TMP"
assert_rc 0 "npm pack the real package"
TARBALL=$(ls "$TEST_TMP"/entropy-machines-*.tgz 2>/dev/null | head -1)
[ -n "$TARBALL" ] || _fail "tarball not found" "expected entropy-machines-*.tgz in $TEST_TMP"

# ---- a brand-new project, the way a real user starts one ----
PROJECT=$(mktemp -d "$TEST_TMP/project.XXXXXX")
PROJECT=$(CDPATH= cd -- "$PROJECT" && pwd -P)
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "tests@entropy.invalid"
git -C "$PROJECT" config user.name  "entropy tests"
git -C "$PROJECT" config commit.gpgsign false
REPO="$PROJECT"   # so the `run` helper (run_in "$REPO") works below

run_in "$PROJECT" npm init -y
assert_rc 0 "npm init -y"

run_in "$PROJECT" npm install --no-fund --no-audit "$TARBALL"
assert_rc 0 "npm install the packed tarball"

# ---- the real onboarding entry point ----
run_in "$PROJECT" "$PROJECT/node_modules/.bin/entropy-machines" init
assert_rc 0 "entropy-machines init, after a real npm install"

HARNESS="$PROJECT/entropy-machines"
assert_file "$HARNESS/config.json" "init wrote config.json"

# ---- bin/serve, exactly as a user runs it — no fake ui/dist anywhere ----
PORT=$(free_port)
LOG="$TEST_TMP/serve.log"
SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
trap 'stop_server' EXIT INT TERM

( cd "$PROJECT" && exec "$HARNESS/bin/serve" --no-open "$PORT" ) >"$LOG" 2>&1 &
SERVER_PID=$!

if ! wait_for_line "$LOG" "http://localhost:$PORT" 80; then
  OUT=$(cat "$LOG" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(still running)"
  LAST_CMD="bin/serve $PORT (real npm install)"
  _fail "bin/serve must start and print its URL after a real npm install" \
        "nothing matching http://localhost:$PORT appeared in $LOG"
fi

# --- GET / must not 404 — this is the first thing a browser requests --------
run http_get "http://127.0.0.1:$PORT/"
assert_rc 0 "GET / completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET / must return 200 after a real npm install, not 404" \
           "first line: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- the first doc a user sees must not 404 ----------------------------------
run http_get "http://127.0.0.1:$PORT/PRD-001-orientation.html"
assert_rc 0 "GET /PRD-001-orientation.html completes"
case "$OUT" in
  200*) ;;
  *) _fail "GET /PRD-001-orientation.html must return 200, not 404" \
           "first line: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- /api/docs must answer with parseable JSON, whatever the status --------
run http_get "http://127.0.0.1:$PORT/api/docs"
assert_rc 0 "GET /api/docs completes"
API_BODY=$(printf '%s' "$OUT" | tail -n +2)
if ! printf '%s' "$API_BODY" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  _fail "GET /api/docs must return valid JSON" "body: $API_BODY"
fi

stop_server

# ---- bin/migrate-db actually creates the database ---------------------------
run "$HARNESS/bin/migrate-db"
assert_rc 0 "bin/migrate-db succeeds after a real npm install"
assert_file "$PROJECT/.entropy-machines/entropy-machines.db" \
  "migrate-db creates .entropy-machines/entropy-machines.db"

# ---- bin/doclint passes on what init actually wrote --------------------------
run "$HARNESS/bin/doclint"
assert_rc 0 "bin/doclint passes on a freshly-initialised project"
assert_out "all local and answerable" "doclint reports a clean bill of health"
