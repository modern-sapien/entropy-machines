# bin/init on a fresh project writes the four things it promises, and nothing
# it does not: config.json, a .gitignore entry for .entropy-machines/, the orientation
# PRD in the docs directory, and a tracker that actually answers afterwards.
. "$TEST_LIB/harness.sh"

fixture_new

# The fixture deliberately has no .gitignore, so init has to create one.
assert_no_file "$REPO/.gitignore" "precondition: the fixture ships no .gitignore"

run "$HARNESS/bin/init"
assert_rc 0 "bin/init on a fresh project"
assert_out "wrote $REPO/config.json" "init names the file it wrote"

assert_file "$REPO/config.json" "init writes config.json at the REPO root"

# Parsed, not grepped: a file that is not JSON would satisfy a grep and break
# every command that reads it.
run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["project"]["name"]); print(d["tracker"]["backend"])' "$REPO/config.json"
assert_rc 0 "config.json parses as JSON and has project.name + tracker.backend"
assert_out "$(basename "$REPO")" "project.name is the project directory's own name"
assert_out "file" "tracker.backend defaults to the built-in file backend"

# .entropy-machines/ is per-checkout state. Committing it is the mistake this line
# prevents, and a missing .gitignore is how it happens.
assert_file "$REPO/.gitignore" "init creates .gitignore when the project has none"
run sh -c "grep -qxF '.entropy-machines/' '$REPO/.gitignore'"
assert_rc 0 ".gitignore carries an exact '.entropy-machines/' line"

# docs.dir TOO. The docs a project answers are its own work and are rewritten
# on every serve; tracking them once put an owner's answered PRD into a public
# repository. init ignores the configured docs.dir, not a hardcoded name.
run sh -c "grep -qxF 'entropy-machines-docs/' '$REPO/.gitignore'"
assert_rc 0 ".gitignore carries an exact 'entropy-machines-docs/' line for docs.dir"

# The PRD is the point of init: it is what gives the owner something to answer.
assert_file "$REPO/entropy-machines-docs/PRD-001-orientation.html" "init installs the orientation PRD into docs.dir"

# A PRD written to disk but absent from manifest.json is invisible to anything
# that reads manifest.json for doc status (bin/tracker render, the API). init
# must register PRD-001, not just write an empty manifest.
assert_file "$REPO/entropy-machines-docs/manifest.json" "init writes manifest.json"
run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["docs"]["PRD-001-orientation"]["file"]); print(d["docs"]["PRD-001-orientation"]["status"])' "$REPO/entropy-machines-docs/manifest.json"
assert_rc 0 "manifest.json parses as JSON and has a PRD-001-orientation entry"
assert_out "PRD-001-orientation.html" "PRD-001-orientation.file points at the copied PRD"
assert_out "open" "PRD-001-orientation.status starts open"

# init's own last step claims the tracker is live. Check the claim rather than
# the sentence.
run "$HARNESS/bin/tracker" ready
assert_rc 0 "bin/tracker ready answers after init"
assert_same "" "$OUT" "a freshly initialised project has no ready issues"
