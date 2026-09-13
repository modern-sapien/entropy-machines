# Verify that the status/effort column comments in lib/schema.sql match the
# actual DEFAULT values the SQLite DDL sets. PRD-007 asked for "a test that
# enforces the comment matches the actual schema" so these never drift apart.
. "$TEST_LIB/harness.sh"

SCHEMA="$ENTROPY_SRC/lib/schema.sql"

# --- issues.status: comment must list the DEFAULT value and only valid tokens --
run python3 -c '
import re, sys

schema = open(sys.argv[1]).read()

# Extract the issues CREATE TABLE block
m = re.search(r"CREATE TABLE IF NOT EXISTS issues \((.*?)\);", schema, re.S)
if not m:
    print("FAIL: could not find CREATE TABLE issues in schema.sql")
    sys.exit(1)
body = m.group(1)

# --- issues.status ---
status_line = [l for l in body.splitlines() if l.strip().startswith("status")]
if not status_line:
    print("FAIL: no status column found in issues table")
    sys.exit(1)
status_line = status_line[0]

# Extract the DEFAULT value
dm = re.search(r"DEFAULT\s+'\''([^'\'']+)'\''", status_line)
if not dm:
    print("FAIL: no DEFAULT found on issues.status line")
    sys.exit(1)
default_val = dm.group(1)

# Extract the comment (after --)
cm = re.search(r"--\s*(.*)", status_line)
if not cm:
    print("FAIL: no comment found on issues.status line")
    sys.exit(1)
comment = cm.group(1).strip()

# The comment must list the default value
if default_val not in comment:
    print(f"FAIL: issues.status DEFAULT is '\''{default_val}'\'' but comment does not mention it: {comment}")
    sys.exit(1)

# --- issues.effort ---
effort_line = [l for l in body.splitlines() if l.strip().startswith("effort")]
if not effort_line:
    print("FAIL: no effort column found in issues table")
    sys.exit(1)
effort_line = effort_line[0]

dm = re.search(r"DEFAULT\s+'\''([^'\'']+)'\''", effort_line)
if not dm:
    print("FAIL: no DEFAULT found on issues.effort line")
    sys.exit(1)
effort_default = dm.group(1)

cm = re.search(r"--\s*(.*)", effort_line)
if not cm:
    print("FAIL: no comment found on issues.effort line")
    sys.exit(1)
effort_comment = cm.group(1).strip()

if effort_default not in effort_comment:
    print(f"FAIL: issues.effort DEFAULT is '\''{effort_default}'\'' but comment does not mention it: {effort_comment}")
    sys.exit(1)

print(f"issues.status DEFAULT='\''{default_val}'\'' matches comment: {comment}")
print(f"issues.effort DEFAULT='\''{effort_default}'\'' matches comment: {effort_comment}")
' "$SCHEMA"

assert_rc 0 "schema comment validation must pass"
assert_out "issues.status DEFAULT=" "status default was checked"
assert_out "issues.effort DEFAULT=" "effort default was checked"
