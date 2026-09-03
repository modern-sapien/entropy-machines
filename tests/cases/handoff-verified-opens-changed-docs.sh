# After bin/handoff --verified records successfully, changed docs in the docs
# directory are opened in the browser automatically -- but ONLY docs that
# appear in the changed-files list ($tmp/changes from the worktree scan).
#
# This verifies:
#   1. A doc file changed in a worktree is opened when --from is given.
#   2. Control: doc in dispatch scope but NOT changed -> nothing opened.
#   3. Control: handoff without --from -> nothing opened even if scope has docs.
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
# bin/init adds entropy-machines-docs/ to .gitignore, so the doc file must be
# force-added to get it into the history — otherwise git worktree add will not
# check it out and the worktree scan cannot find it.
git -C "$REPO" add -f "$docs_dir/PRD-001-test.html"
git -C "$REPO" commit -qm "add test doc"

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

# --- 1. doc changed in worktree + --from -> opened ---------------------------
# Create a worktree and modify the doc file in it.
wt="$TEST_TMP/wt-docopen"
git -C "$REPO" worktree add -q "$wt" HEAD

printf '<!doctype html><html><body>updated content</body></html>\n' \
  > "$wt/$docs_dir/PRD-001-test.html"

# The worktree needs a HANDOFF.md (--from without --lift requires it).
cat > "$wt/HANDOFF.md" <<'EOF'
changed: updated PRD-001-test.html
found: none
assumed: none
next: none
EOF

run "$HARNESS/bin/dispatch" i-docopen \
    --files "$docs_dir/PRD-001-test.html" --brief "update the orientation doc"
assert_rc 0 "dispatch records"

run "$HARNESS/bin/handoff" i-docopen --record-interrogation \
    --answer "did not run integration tests -- scope limited to doc detection" \
    --answer "the opened-output check -- removing the doc file would pass silently" \
    --answer "that bin/serve defaults to port 8787" \
    --answer "nothing skipped from the brief" \
    --answer "would verify the serve-startup path with no listener on 8787"
assert_rc 0 "interrogation recorded"

run "$HARNESS/bin/handoff" i-docopen \
    --from "$wt" \
    --changed "updated PRD-001-test.html" \
    --verified "I opened the doc in the browser and read the rendered output" \
    --clean
assert_rc 0 "handoff --from --verified records successfully"
assert_out "recorded on i-docopen" "the handoff note is written"
assert_out "opened http://localhost:8787/PRD-001-test.html" \
    "the changed doc is opened in the browser on the detected port"

# The mock 'open' actually received the call.
assert_file "$HOME/.open-calls" "the open command was invoked"

# --- 2. control: doc in scope but NOT changed -> nothing opened ---------------
# The worktree has only a code change, not a doc change, even though dispatch
# scope includes the doc directory.
wt2="$TEST_TMP/wt-nodoc"
git -C "$REPO" worktree add -q "$wt2" HEAD

printf 'int main(void) { return 1; }\n' > "$wt2/src/main.c"

cat > "$wt2/HANDOFF.md" <<'EOF'
changed: updated main.c
found: none
assumed: none
next: none
EOF

# Clear the open-calls log to isolate this test.
rm -f "$HOME/.open-calls"

run "$HARNESS/bin/dispatch" i-nodoc \
    --files "$docs_dir/PRD-001-test.html src/main.c" --brief "code change, doc in scope but unchanged"
assert_rc 0 "second dispatch records"

run "$HARNESS/bin/handoff" i-nodoc --record-interrogation \
    --answer "same suite, same reason" \
    --answer "no assertion written -- this is a negative control" \
    --answer "same assumptions as above" \
    --answer "nothing skipped" \
    --answer "would check the dispatch-context fallback path"
assert_rc 0 "second interrogation recorded"

run "$HARNESS/bin/handoff" i-nodoc \
    --from "$wt2" \
    --changed "updated main.c" \
    --verified "I compiled src/main.c in this checkout and it built cleanly" \
    --clean
assert_rc 0 "handoff without changed doc files succeeds"
assert_not_out "opened http://" "no doc is opened when no doc was changed"

# --- 3. control: no --from -> nothing opened even if scope has docs ----------
rm -f "$HOME/.open-calls"

run "$HARNESS/bin/dispatch" i-nofrom \
    --files "$docs_dir/PRD-001-test.html" --brief "direct handoff, no worktree"
assert_rc 0 "third dispatch records"

run "$HARNESS/bin/handoff" i-nofrom --record-interrogation \
    --answer "same suite, same reason" \
    --answer "no assertion written -- negative control" \
    --answer "same assumptions" \
    --answer "nothing skipped" \
    --answer "would check worktree path"
assert_rc 0 "third interrogation recorded"

run "$HARNESS/bin/handoff" i-nofrom \
    --changed "updated PRD-001-test.html" \
    --verified "I checked the doc manually" \
    --clean
assert_rc 0 "handoff without --from succeeds"
assert_not_out "opened http://" "no doc is opened without --from (no changes file)"
