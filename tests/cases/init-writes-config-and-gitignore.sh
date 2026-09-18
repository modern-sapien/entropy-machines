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
# It is seeded directly into SQLite — no HTML copy lands in the docs dir.
assert_file "$REPO/.entropy-machines/entropy-machines.db" "init seeds the PRD into SQLite"
run python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute("SELECT id,type,status FROM docs WHERE id=?",("PRD-001-orientation",)).fetchone(); print(r[0]); print(r[1]); print(r[2])' "$REPO/.entropy-machines/entropy-machines.db"
assert_rc 0 "the PRD is in the database"
assert_out "PRD-001-orientation" "doc id is PRD-001-orientation"
assert_out "prd" "doc type is prd"
assert_out "open" "doc status starts open"

# Pages and responses must be populated — an empty doc is useless.
run python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); p=c.execute("SELECT COUNT(*) FROM pages WHERE doc_id=?",("PRD-001-orientation",)).fetchone()[0]; r=c.execute("SELECT COUNT(*) FROM responses WHERE doc_id=?",("PRD-001-orientation",)).fetchone()[0]; print("pages=%d responses=%d"%(p,r))' "$REPO/.entropy-machines/entropy-machines.db"
assert_rc 0 "pages and responses query succeeds"
assert_not_out "pages=0" "the PRD has at least one page"
assert_not_out "responses=0" "the PRD has at least one response box"

# manifest.json is still written — it tracks doc status for docstate.py.
assert_file "$REPO/entropy-machines-docs/manifest.json" "init writes manifest.json"
run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["docs"]["PRD-001-orientation"]["file"]); print(d["docs"]["PRD-001-orientation"]["status"])' "$REPO/entropy-machines-docs/manifest.json"
assert_rc 0 "manifest.json parses as JSON and has a PRD-001-orientation entry"
assert_out "PRD-001-orientation.html" "PRD-001-orientation.file names the source HTML"
assert_out "open" "PRD-001-orientation.status starts open"

# .mcp.json must point mcp-serve at this project so MCP tools talk to the
# right database.
assert_file "$REPO/.mcp.json" "init writes .mcp.json"
run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["mcpServers"]["entropy-machines"]; print(s["cwd"])' "$REPO/.mcp.json"
assert_rc 0 ".mcp.json parses and has an entropy-machines server entry"
assert_out "$REPO" ".mcp.json cwd points at the project root"

# init's own last step claims the tracker is live. Check the claim rather than
# the sentence.
run "$HARNESS/bin/tracker" ready
assert_rc 0 "bin/tracker ready answers after init"
assert_same "" "$OUT" "a freshly initialised project has no ready issues"
