# After bin/handoff --verified records successfully, changed docs in the docs
# directory are opened in the browser automatically.
#
# This verifies:
#   1. Doc files are detected from the dispatch scope.
#   2. The URL is constructed and `open` is called.
#   3. Control: no doc files in scope -> nothing opened.
#
# bin/serve and `open` are mocked so no real server runs and no browser window
# opens. The test asserts only on the script's output and the mock's log.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

# --- setup: a doc in the configured docs directory ---------------------------
docs_dir="entropy-machines-docs"
mkdir -p "$REPO/$docs_dir"
printf '<!doctype html><html><body>test</body></html>\n' \
  > "$REPO/$docs_dir/PRD-001-test.html"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "add test doc"

# --- setup: mock lsof and open so no real server or browser is touched -------
#
# lsof pretends port 8787 has a listener, so the handoff function does not try
# to start bin/serve. open records its arguments instead of launching a browser.
mkdir -p "$TEST_TMP/mockbin"

cat > "$TEST_TMP/mockbin/lsof" <<'MOCK'
#!/bin/sh
case "$*" in *iTCP:8787*) echo "12345"; exit 0 ;; esac
exit 1
MOCK
chmod +x "$TEST_TMP/mockbin/lsof"

cat > "$TEST_TMP/mockbin/open" <<'MOCK'
#!/bin/sh
echo "$@" >> "$HOME/.open-calls"
MOCK
chmod +x "$TEST_TMP/mockbin/open"

export PATH="$TEST_TMP/mockbin:$PATH"

# --- 1. doc file in scope -> opened automatically ---------------------------
run "$HARNESS/bin/dispatch" i-docopen \
    --files "$docs_dir/PRD-001-test.html" --brief "update the orientation doc"
assert_rc 0 "dispatch records"

run "$HARNESS/bin/handoff" i-docopen --record-interrogation \
    --answer "did not run integration tests — scope limited to doc detection" \
    --answer "the opened-output check — removing the doc file would pass silently" \
    --answer "that bin/serve defaults to port 8787" \
    --answer "nothing skipped from the brief" \
    --answer "would verify the serve-startup path with no listener on 8787"
assert_rc 0 "interrogation recorded"

run "$HARNESS/bin/handoff" i-docopen \
    --changed "updated PRD-001-test.html" \
    --verified "I opened the doc in the browser and read the rendered output" \
    --clean
assert_rc 0 "handoff --verified records successfully"
assert_out "recorded on i-docopen" "the handoff note is written"
assert_out "opened http://localhost:8787/PRD-001-test.html" \
    "the changed doc is opened in the browser on the detected port"

# The mock 'open' actually received the call.
assert_file "$HOME/.open-calls" "the open command was invoked"

# --- 2. control: no doc in scope -> nothing opened ---------------------------
run "$HARNESS/bin/dispatch" i-nodoc --files "src/main.c" --brief "code-only change"
assert_rc 0 "second dispatch records"

run "$HARNESS/bin/handoff" i-nodoc --record-interrogation \
    --answer "same suite, same reason" \
    --answer "no assertion written — this is a negative control" \
    --answer "same assumptions as above" \
    --answer "nothing skipped" \
    --answer "would check the dispatch-context fallback path"
assert_rc 0 "second interrogation recorded"

run "$HARNESS/bin/handoff" i-nodoc \
    --changed "updated main.c" \
    --verified "I compiled src/main.c in this checkout and it built cleanly" \
    --clean
assert_rc 0 "handoff without doc files succeeds"
assert_not_out "opened http://" "no doc is opened when scope has no docs"
