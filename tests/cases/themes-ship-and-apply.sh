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
# THEMES object is embedded in every template
# ---------------------------------------------------------------------------
for tpl in "$HARNESS/lib/doc-template.html" \
           "$HARNESS/lib/sprint-report-template.html" \
           "$HARNESS/lib/REPORT-TEMPLATE.html"; do
  base=$(basename "$tpl")
  run grep -c 'janus-light' "$tpl"
  assert_rc 0 "$base contains janus-light theme"
  run grep -c 'janus-dark' "$tpl"
  assert_rc 0 "$base contains janus-dark theme"
  run grep -c 'hc-dark' "$tpl"
  assert_rc 0 "$base contains hc-dark theme"
  run grep -c 'daylight' "$tpl"
  assert_rc 0 "$base contains daylight theme"
  run grep -c 'daylight-dark' "$tpl"
  assert_rc 0 "$base contains daylight-dark theme"
done

# ---------------------------------------------------------------------------
# only 5 color CSS vars used — no old tokens like --panel, --ink, --line, etc.
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/check_vars.py" <<'PY'
import re
import sys

ALLOWED_COLOR = {"--bg", "--fg", "--accent", "--positive", "--negative"}
ALLOWED_NONCOLOR = {"--fs-sm", "--fs-base", "--fs-head", "--fs-title", "--mono",
                    "--font", "--measure"}
ALLOWED = ALLOWED_COLOR | ALLOWED_NONCOLOR

OLD_VARS = {"--panel", "--ink", "--dim", "--line", "--focus", "--border",
            "--link", "--you", "--me", "--done", "--held", "--warn", "--ready",
            "--prog", "--blocked", "--gated", "--caution", "--muted",
            "--warn-deep", "--code-bg", "--good"}

bad = []
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    # Find all var(--name) usages (but skip inside THEMES JSON objects)
    for m in re.finditer(r'var\((--[a-z_-]+)', text):
        name = m.group(1)
        if name in OLD_VARS:
            line = text[:m.start()].count("\n") + 1
            bad.append("%s:%d uses old var %s" % (path, line, name))
    # Check for var() fallbacks: var(--name, something)
    for m in re.finditer(r'var\(--[a-z_-]+\s*,\s*[^)]+\)', text):
        line = text[:m.start()].count("\n") + 1
        bad.append("%s:%d has a var() fallback: %s" % (path, line, m.group()))

if bad:
    for b in bad:
        print("BAD: " + b)
    sys.exit(1)
print("all templates use only the 5 color vars, no fallbacks")
PY

run python3 "$TEST_TMP/check_vars.py" \
    "$HARNESS/lib/doc-template.html" \
    "$HARNESS/lib/sprint-report-template.html" \
    "$HARNESS/lib/REPORT-TEMPLATE.html"
assert_rc 0 "HTML templates use only the 5 color vars"
assert_no_traceback

# ---------------------------------------------------------------------------
# theme selector exists, old toggle button is gone
# ---------------------------------------------------------------------------
for tpl in "$HARNESS/lib/doc-template.html" \
           "$HARNESS/lib/sprint-report-template.html" \
           "$HARNESS/lib/REPORT-TEMPLATE.html"; do
  base=$(basename "$tpl")
  run grep -c 'theme-sel' "$tpl"
  assert_rc 0 "$base has a theme selector dropdown"
done

# The old system/light/dark toggle cycling button must not appear in templates
run grep -c '__theme-toggle-patch.*data-theme.*light.*dark' \
    "$HARNESS/lib/doc-template.html" \
    "$HARNESS/lib/sprint-report-template.html" \
    "$HARNESS/lib/REPORT-TEMPLATE.html"
assert_rc_nonzero "old light/dark toggle is gone from templates"

# ---------------------------------------------------------------------------
# applyTheme uses setProperty, not data-theme attribute
# ---------------------------------------------------------------------------
for tpl in "$HARNESS/lib/doc-template.html" \
           "$HARNESS/lib/sprint-report-template.html" \
           "$HARNESS/lib/REPORT-TEMPLATE.html"; do
  base=$(basename "$tpl")
  run grep -c "setProperty" "$tpl"
  assert_rc 0 "$base uses setProperty for theme application"
done

# ---------------------------------------------------------------------------
# doctracker.py and tracker-view.py templates also use only 5 color vars
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
    "$HARNESS/lib/tracker-view.py" \
    "$HARNESS/lib/enhance.py"
assert_rc 0 "Python templates use only the 5 color vars"
assert_no_traceback

assert_no_traceback "no command in this case may exit via a Python traceback"
