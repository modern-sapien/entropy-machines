# bin/dispatch must preserve existing content in .dispatch-context/<id>.md.
#
# The orchestrator may write a spec into the context file before dispatching.
# That spec is the agent's primary input and must appear FIRST and intact.
# The generated dispatch sections go AFTER it, under a separator.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init
fixture_hooks

run "$HARNESS/bin/tracker" set i-spec title="issue with a pre-written spec" description="spec issue description"
assert_rc 0 "file the issue"

# --- pre-populate the context file with a spec ----------------------------
CTX="$REPO/.dispatch-context/i-spec.md"
mkdir -p "$REPO/.dispatch-context"
cat > "$CTX" <<'SPEC'
# Spec for i-spec

This is the orchestrator's spec for the agent.

## Requirements

1. Do the thing
2. Check the other thing
SPEC

# Capture the spec content for comparison
spec_before=$(cat "$CTX")

# --- dispatch over it — must NOT destroy the spec -------------------------
run "$HARNESS/bin/dispatch" i-spec --files "src/main.c" --brief "implement the spec" --force
assert_rc 0 "dispatch succeeds when the context file already exists"

# The spec must appear in the file, intact and BEFORE the dispatch boilerplate
run grep -qF "This is the orchestrator's spec for the agent." "$CTX"
assert_rc 0 "the pre-existing spec content is preserved"

run grep -qF "## Requirements" "$CTX"
assert_rc 0 "the spec's sections are preserved"

run grep -qF "Do the thing" "$CTX"
assert_rc 0 "the spec's details are preserved"

# The dispatch boilerplate must also be present
run grep -qF "implement the spec" "$CTX"
assert_rc 0 "the dispatch brief is written"

run grep -qF "Dispatch context" "$CTX"
assert_rc 0 "the dispatch header is written"

run grep -qF "src/main.c" "$CTX"
assert_rc 0 "the scope is written"

# The spec must appear BEFORE the dispatch metadata. Check that the spec's
# first line comes before the dispatch header.
spec_line=$(grep -n "orchestrator's spec" "$CTX" | head -1 | cut -d: -f1)
dispatch_line=$(grep -n "# Dispatch context" "$CTX" | head -1 | cut -d: -f1)
run python3 -c "
import sys
spec, dispatch = int(sys.argv[1]), int(sys.argv[2])
if spec >= dispatch:
    print(f'spec at line {spec}, dispatch at line {dispatch} — spec should come first')
    sys.exit(1)
print(f'spec at line {spec}, dispatch at line {dispatch} — order is correct')
" "$spec_line" "$dispatch_line"
assert_rc 0 "the spec appears before the dispatch boilerplate"

# There should be a separator between the spec and the dispatch sections
run grep -qF -- "---" "$CTX"
assert_rc 0 "a separator divides the spec from the dispatch metadata"

# --- a dispatch with NO pre-existing file works as before -----------------
run "$HARNESS/bin/tracker" set i-fresh title="fresh issue" description="fresh issue description"
assert_rc 0 "file a fresh issue"

CTX_FRESH="$REPO/.dispatch-context/i-fresh.md"
assert_no_file "$CTX_FRESH" "no pre-existing context file for the fresh issue"

run "$HARNESS/bin/dispatch" i-fresh --files "src/main.c" --brief "start from scratch" --force
assert_rc 0 "dispatch without a pre-existing file succeeds"
assert_file "$CTX_FRESH" "the context file is created"

# The fresh context file should start with the dispatch header, not a separator
first_nonblank=$(grep -m1 '.' "$CTX_FRESH")
case "$first_nonblank" in
  "# Dispatch context"*) ;;
  *) _fail "fresh context file should start with dispatch header" \
           "first non-blank line: $first_nonblank" ;;
esac
