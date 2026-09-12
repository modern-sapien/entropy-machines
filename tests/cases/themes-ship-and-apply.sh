# Themes — config-driven, not CSS files.
#
# THE RULE: themes are 5-color config objects (bg, fg, accent, positive,
# negative) embedded directly in every template as a THEMES JS object.
# No theme CSS files, no data-theme attribute, no var() fallbacks.
# Theme application uses style.setProperty on :root for the 5 vars.
# Selection persists via localStorage key 'entropy-machines-theme'.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# ---------------------------------------------------------------------------
# no theme CSS files exist — themes are config, not files
# ---------------------------------------------------------------------------
run test -d "$HARNESS/lib/themes"
assert_rc_nonzero "lib/themes/ directory must not exist — themes are config objects"

# ---------------------------------------------------------------------------
# the old HTML templates are gone (React replacements have landed)
# ---------------------------------------------------------------------------
run test -f "$HARNESS/lib/doc-template.html"
assert_rc_nonzero "doc-template.html must not exist — replaced by React"
run test -f "$HARNESS/lib/sprint-report-template.html"
assert_rc_nonzero "sprint-report-template.html must not exist — replaced by React"
run test -f "$HARNESS/lib/REPORT-TEMPLATE.html"
assert_rc_nonzero "REPORT-TEMPLATE.html must not exist — replaced by React"
run test -f "$HARNESS/lib/enhance.py"
assert_rc_nonzero "enhance.py must not exist — replaced by React"

# ---------------------------------------------------------------------------
# doctracker.py and tracker-view.py templates use only 5 color vars
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/check_py_templates.py" <<'PY'
import re
import sys

OLD_VARS = {"--panel", "--ink", "--dim", "--line", "--focus", "--border",
            "--link", "--you", "--me", "--done", "--held", "--warn", "--ready",
            "--prog", "--blocked", "--gated", "--caution", "--muted",
            "--warn-deep", "--code-bg", "--good"}

bad = []
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r'var\((--[a-z_-]+)', text):
        name = m.group(1)
        if name in OLD_VARS:
            line = text[:m.start()].count("\n") + 1
            bad.append("%s:%d uses old var %s" % (path, line, name))
    for m in re.finditer(r'var\(--[a-z_-]+\s*,\s*[^)]+\)', text):
        line = text[:m.start()].count("\n") + 1
        bad.append("%s:%d has a var() fallback: %s" % (path, line, m.group()))

if bad:
    for b in bad:
        print("BAD: " + b)
    sys.exit(1)
print("Python templates clean")
PY

run python3 "$TEST_TMP/check_py_templates.py" \
    "$HARNESS/lib/doctracker.py" \
    "$HARNESS/lib/tracker-view.py"
assert_rc 0 "Python templates use only the 5 color vars"
assert_no_traceback

assert_no_traceback "no command in this case may exit via a Python traceback"
