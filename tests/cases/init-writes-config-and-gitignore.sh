# bin/init on a fresh project writes the four things it promises, and nothing
# it does not: entropy.json, a .gitignore entry for .entropy/, the orientation
# PRD in the docs directory, and a tracker that actually answers afterwards.
. "$TEST_LIB/harness.sh"

fixture_new

# The fixture deliberately has no .gitignore, so init has to create one.
assert_no_file "$REPO/.gitignore" "precondition: the fixture ships no .gitignore"

run "$HARNESS/bin/init"
assert_rc 0 "bin/init on a fresh project"
assert_out "wrote $REPO/entropy.json" "init names the file it wrote"

assert_file "$REPO/entropy.json" "init writes entropy.json at the REPO root"

# Parsed, not grepped: a file that is not JSON would satisfy a grep and break
# every command that reads it.
run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["project"]["name"]); print(d["tracker"]["backend"])' "$REPO/entropy.json"
assert_rc 0 "entropy.json parses as JSON and has project.name + tracker.backend"
assert_out "$(basename "$REPO")" "project.name is the project directory's own name"
assert_out "file" "tracker.backend defaults to the built-in file backend"

# .entropy/ is per-checkout state. Committing it is the mistake this line
# prevents, and a missing .gitignore is how it happens.
assert_file "$REPO/.gitignore" "init creates .gitignore when the project has none"
run sh -c "grep -qxF '.entropy/' '$REPO/.gitignore'"
assert_rc 0 ".gitignore carries an exact '.entropy/' line"

# The PRD is the point of init: it is what gives the owner something to answer.
assert_file "$REPO/entropy-docs/PRD-001-orientation.html" "init installs the orientation PRD into docs.dir"

# init's own last step claims the tracker is live. Check the claim rather than
# the sentence.
run "$HARNESS/bin/tracker" ready
assert_rc 0 "bin/tracker ready answers after init"
assert_same "" "$OUT" "a freshly initialised project has no ready issues"
