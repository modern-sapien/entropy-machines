# Themes — a second look for the viewable interfaces, chosen by config rather
# than by editing a template.
#
# THE RULE: one document structure, N skins. A theme is a :root token block in
# lib/themes/<name>.css; docs.theme names one; bin/serve INLINES it into every
# doc it serves. It is never <link>ed, because a doc here is a standalone local
# file the owner may open off disk or move — which is the same reason
# bin/doclint refuses any reference pointing off this machine.
#
# BOTH DIRECTIONS ARE ASSERTED, as in doclint-refuses-a-malformed-report.sh. A
# swap that applies nothing and a swap that applies everything look identical
# against one assertion, so every "daylight is here" is paired with "and the
# high-contrast value it replaced is NOT", and every refusal is paired with a
# configuration that must serve.
#
# WHY THE TOKEN NAME SETS ARE COMPARED. The classic bug in a theme file is a
# token that only exists under [data-theme=…]: the page renders unstyled in the
# default state, and it renders correctly the moment you press the toggle, so
# whoever wrote it saw it work. Comparing the two files' name sets, and
# insisting every name has a value in the BARE :root, is what catches it before
# a reader does.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

THEMES="$HARNESS/lib/themes"
TPL="$HARNESS/lib/REPORT-TEMPLATE.html"
DOCS="$REPO/entropy-machines-docs"
DOC="SPRINT-REPORT-THEMED.html"

# Janus — the default theme, violet-accented high contrast.
JN_BG="--bg:#0a0a0d;"
JN_BORDER="--border:#a78bfa;"
JN_STEP="--fs-base:14px;"
# High-contrast — the original house style.
HC_BG="--bg:#000;"
HC_BORDER="--border:#6FC3DF;"
HC_STEP="--fs-base:14px;"
# Daylight — a different aesthetic, not a recolour: warm paper, quiet rule,
# bigger type.
DL_BG="--bg:#FAF8F4;"
DL_BORDER="--border:#8E8A7E;"
DL_STEP="--fs-base:16px;"

# ---------------------------------------------------------------------------
# all themes ship
# ---------------------------------------------------------------------------
assert_file "$THEMES/janus.css" "the default theme ships as a file"
assert_file "$THEMES/high-contrast.css" "and so does the original"
assert_file "$THEMES/daylight.css" "and the light one"

# ---------------------------------------------------------------------------
# the token NAMES are the contract: identical sets, every one with a value in
# the bare :root of its own file.
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/tokens.py" <<'PY'
"""Compare the token name sets of two theme files, and insist every name has a
value in the bare :root. Exit 1 with the difference named; a missing token is
the failure mode this exists for."""
import re
import sys

REQUIRED = {
    "--bg", "--panel", "--fg", "--dim", "--border", "--focus", "--link",
    "--positive", "--caution", "--negative", "--accent",
    "--fs-sm", "--fs-base", "--fs-head", "--fs-title", "--mono",
    # secondary aliases some CSS may reference
    "--good", "--muted", "--warn-deep", "--code-bg",
}

BLOCK_RE = re.compile(r"(:root(?:\[[^\]]*\])?)\s*\{([^}]*)\}")
DECL_RE = re.compile(r"(--[A-Za-z0-9-]+)\s*:\s*([^;]+?)\s*(?:;|$)")


def blocks(path):
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"/\*[\s\S]*?\*/", "", text)  # comments hold no declarations
    out = []
    for sel, body in BLOCK_RE.findall(text):
        out.append((sel, {m.group(1): m.group(2) for m in DECL_RE.finditer(body)}))
    return out


bad = []
sets = {}
for path in sys.argv[1:]:
    bs = blocks(path)
    if not bs:
        bad.append("%s: no :root block at all" % path)
        continue
    base = None
    others = {}
    for sel, decls in bs:
        if sel == ":root":
            base = decls
        else:
            others.update(decls)
    if base is None:
        bad.append("%s: no BARE :root — every token would be unset by default" % path)
        continue
    names = set(base) | set(others)
    sets[path] = names

    missing = sorted(REQUIRED - names)
    if missing:
        bad.append("%s: missing required tokens: %s" % (path, " ".join(missing)))

    only_themed = sorted(n for n in others if n not in base)
    if only_themed:
        bad.append(
            "%s: %s defined only under a [data-theme] block — unstyled in the "
            "default state" % (path, " ".join(only_themed))
        )

    empty = sorted(n for n, v in base.items() if not v.strip())
    if empty:
        bad.append("%s: no value for %s in the bare :root" % (path, " ".join(empty)))

paths = list(sets)
if len(paths) >= 2:
    ref = paths[0]
    for other in paths[1:]:
        only_ref = sorted(sets[ref] - sets[other])
        only_other = sorted(sets[other] - sets[ref])
        if only_ref or only_other:
            bad.append("token name sets DIFFER: only in %s: %s | only in %s: %s"
                       % (ref, " ".join(only_ref) or "-", other, " ".join(only_other) or "-"))

if bad:
    for line in bad:
        print("THEME-TOKENS: %s" % line)
    sys.exit(1)

print("token name sets are identical: %d names, all with a value in the bare :root"
      % len(sets[paths[0]]))
PY

run python3 "$TEST_TMP/tokens.py" "$THEMES/janus.css" "$THEMES/high-contrast.css" "$THEMES/daylight.css"
assert_rc 0 "all themes define the same token names, every one valued in :root"
assert_out "token name sets are identical" "and the comparison says so"
assert_no_traceback

# The template carries the default theme inline so a file opened straight off
# disk still looks right. That inline copy is EXACTLY the theme file — if it
# drifts, an author reading the template is reading a palette nobody serves.
cat > "$TEST_TMP/inline.py" <<'PY'
import sys

BEGIN = "/* entropy-machines-theme:begin */\n"
END = "/* entropy-machines-theme:end */"
doc = open(sys.argv[1], encoding="utf-8").read()
theme = open(sys.argv[2], encoding="utf-8").read()
b = doc.find(BEGIN)
e = doc.find(END, b + len(BEGIN)) if b != -1 else -1
if b == -1 or e == -1:
    print("the template has no entropy-machines-theme markers — bin/serve cannot swap it")
    sys.exit(1)
span = doc[b + len(BEGIN):e]
if span != theme:
    print("the template's inlined block is NOT the default theme file")
    print("  inlined: %d chars, file: %d chars" % (len(span), len(theme)))
    sys.exit(1)
print("the template inlines the default theme file verbatim")
PY

run python3 "$TEST_TMP/inline.py" "$TPL" "$THEMES/janus.css"
assert_rc 0 "the template's own token block is the default theme file, byte for byte"
assert_out "verbatim" "and says so"

# ---------------------------------------------------------------------------
# helpers: point config.json at a theme, and drive a real server
# ---------------------------------------------------------------------------
set_theme() {
  ENTROPY_JSON="$REPO/config.json" NEW_THEME="$1" python3 -c '
import json, os
p = os.environ["ENTROPY_JSON"]
cfg = json.load(open(p, encoding="utf-8"))
docs = cfg.setdefault("docs", {})
name = os.environ["NEW_THEME"]
if name == "__unset__":
    docs.pop("theme", None)
else:
    docs["theme"] = name
json.dump(cfg, open(p, "w", encoding="utf-8"), indent=2)
'
}

cat > "$TEST_TMP/fetch.py" <<'PY'
import sys
import urllib.request

r = urllib.request.urlopen(sys.argv[1], timeout=5)
body = r.read().decode("utf-8")
open(sys.argv[2], "w", encoding="utf-8").write(body)
print(r.status)
PY

cat > "$TEST_TMP/probe.py" <<'PY'
"""Is anything listening? Prints LISTENING or CLOSED — never raises, so a case
can assert on the answer instead of on a traceback."""
import socket
import sys

s = socket.socket()
s.settimeout(2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    print("LISTENING")
except OSError:
    print("CLOSED")
finally:
    s.close()
PY

cat > "$TEST_TMP/runx.py" <<'RUNX'
"""Run a command with a deadline, print what it printed, exit with its code.

WHY A DEADLINE IS PART OF THE ASSERTION. Every refusal below is checked by
running bin/serve in the FOREGROUND and expecting it to exit. A bin/serve that
stopped refusing would not fail those assertions — it would serve, and block,
and hang the whole suite with no verdict at all. This turns that into a fast,
named failure: exit 124 and the word TIMEOUT, which no refusal assertion here
matches.
"""
import subprocess
import sys

deadline = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=deadline)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired as exc:
    sys.stdout.write(exc.stdout.decode() if exc.stdout else "")
    sys.stderr.write(exc.stderr.decode() if exc.stderr else "")
    print("TIMEOUT: %s did not exit within %ss — it did not refuse, it SERVED"
          % (" ".join(cmd), deadline))
    sys.exit(124)
RUNX

SERVED=0
stop_server() {
  if [ "$SERVED" -eq 1 ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVED=0
  fi
  return 0
}
trap 'stop_server' EXIT INT TERM

# start_server <port> <logfile> — fails the case if the URL never appears.
start_server() {
  ( cd "$REPO" && exec "$HARNESS/bin/serve" --no-open "$1" ) >"$2" 2>&1 &
  SERVER_PID=$!
  SERVED=1
  if ! wait_for_line "$2" "http://localhost:$1" 80; then
    OUT=$(cat "$2" 2>/dev/null); ERR=""; ALL="$OUT"; RC="(never printed a URL)"
    LAST_CMD="bin/serve $1"
    _fail "bin/serve must come up within 8s for this case to mean anything" \
          "nothing matching http://localhost:$1 appeared in $2"
  fi
  return 0
}

cp "$TPL" "$DOCS/$DOC"

# The dashboard redirects to the first PRD when the tracker is empty (first-
# contact redirect, bin/serve change 2026-09). This test needs the dashboard
# to render, so seed one issue to keep the dashboard path.
( cd "$REPO" && "$HARNESS/bin/tracker" set test-theme-issue status=notstarted title="Theming test fixture" ) >/dev/null 2>&1

# ---------------------------------------------------------------------------
# DEFAULT: no docs.theme at all — janus, the brand theme.
# ---------------------------------------------------------------------------
set_theme __unset__
PORT=$(free_port)
start_server "$PORT" "$TEST_TMP/serve-default.log"

OUT=$(cat "$TEST_TMP/serve-default.log"); ERR=""; ALL="$OUT"; RC=0
LAST_CMD="bin/serve $PORT (no docs.theme set)"
assert_out "theme: janus" "with no docs.theme it names the default it fell back to"

run python3 "$TEST_TMP/fetch.py" "http://127.0.0.1:$PORT/$DOC" "$TEST_TMP/default.html"
assert_rc 0 "the doc is served"
assert_out "200" "with a 200"

run grep -F -- "$JN_BG" "$TEST_TMP/default.html"
assert_rc 0 "the default serves the janus ground"
run grep -F -- "$JN_BORDER" "$TEST_TMP/default.html"
assert_rc 0 "and its violet border"
run grep -F -- "$JN_STEP" "$TEST_TMP/default.html"
assert_rc 0 "and its type scale"
# Daylight tokens may appear in the theme-options block (scoped under
# data-theme), but NOT in the server-inlined theme:begin/end span.
run sed -n '/entropy-machines-theme:begin/,/entropy-machines-theme:end/p' "$TEST_TMP/default.html"
assert_rc 0 "the theme span exists"
OUT=$(sed -n '/entropy-machines-theme:begin/,/entropy-machines-theme:end/p' "$TEST_TMP/default.html")
case "$OUT" in *"$DL_BG"*) RC=1 ;; *) RC=0 ;; esac
assert_rc 0 "and the inlined theme span has nothing of daylight's"

# The dashboard is a viewable interface too and wears the same theme.
run python3 "$TEST_TMP/fetch.py" "http://127.0.0.1:$PORT/" "$TEST_TMP/dash-default.html"
assert_rc 0 "the dashboard is served"
run grep -F -- "$JN_BG" "$TEST_TMP/dash-default.html"
assert_rc 0 "the dashboard is themed too, not left on a second private palette"

stop_server

# ---------------------------------------------------------------------------
# daylight: the SAME doc on disk, served with the other skin.
# ---------------------------------------------------------------------------
set_theme daylight
PORT=$(free_port)
start_server "$PORT" "$TEST_TMP/serve-daylight.log"

OUT=$(cat "$TEST_TMP/serve-daylight.log"); ERR=""; ALL="$OUT"; RC=0
LAST_CMD="bin/serve $PORT (docs.theme daylight)"
assert_out "theme: daylight" "the log names the theme it is applying"

run python3 "$TEST_TMP/fetch.py" "http://127.0.0.1:$PORT/$DOC" "$TEST_TMP/daylight.html"
assert_rc 0 "the same doc is served under daylight"

run grep -F -- "$DL_BG" "$TEST_TMP/daylight.html"
assert_rc 0 "daylight's ground is in the served page"
run grep -F -- "$DL_BORDER" "$TEST_TMP/daylight.html"
assert_rc 0 "and its rule colour"
run grep -F -- "$DL_STEP" "$TEST_TMP/daylight.html"
assert_rc 0 "and its type scale"
run grep -F -- "[data-theme=dark]" "$TEST_TMP/daylight.html"
assert_rc 0 "including the dark state, so the toggle still works both ways"

# The inlined theme span should have daylight, not janus.
# Janus tokens may appear in the theme-options block (scoped), but NOT in the
# server-inlined theme:begin/end span.
DL_THEME_SPAN=$(sed -n '/entropy-machines-theme:begin/,/entropy-machines-theme:end/p' "$TEST_TMP/daylight.html")
case "$DL_THEME_SPAN" in *"$JN_BG"*) RC=1 ;; *) RC=0 ;; esac
assert_rc 0 "the janus ground is not in daylight's inlined theme span"
case "$DL_THEME_SPAN" in *"$JN_BORDER"*) RC=1 ;; *) RC=0 ;; esac
assert_rc 0 "nor its violet border"

# The file on disk is untouched — the theme is applied in flight, so the doc
# stays the author's and switching themes rewrites nothing.
run grep -F -- "$JN_BG" "$DOCS/$DOC"
assert_rc 0 "the doc ON DISK still carries its own tokens; serving rewrote nothing"

# Structure is shared, not duplicated: the parts a theme does not own survive.
run grep -F -- "data-resp" "$TEST_TMP/daylight.html"
assert_rc 0 "the themed doc still carries its answer boxes"
run grep -F -- "max-width:860px" "$TEST_TMP/daylight.html"
assert_rc 0 "and its layout, which no theme file defines"

# ---------------------------------------------------------------------------
# A themed doc is still a doc: local-only and answerable, under either skin.
# ---------------------------------------------------------------------------
cp "$TEST_TMP/daylight.html" "$DOCS/SERVED-DAYLIGHT.html"
run "$HARNESS/bin/doclint" "$DOCS/SERVED-DAYLIGHT.html"
assert_rc 0 "doclint passes a doc as served under daylight"
assert_out "all local and answerable" "with no external reference introduced"

cp "$TEST_TMP/default.html" "$DOCS/SERVED-JN.html"
run "$HARNESS/bin/doclint" "$DOCS/SERVED-JN.html"
assert_rc 0 "and one as served under janus"
assert_no_traceback

run "$HARNESS/bin/doclint" "$THEMES/daylight.css"
assert_rc_nonzero "a theme file is not a doc — doclint has no business passing one"

stop_server
rm -f "$DOCS/SERVED-DAYLIGHT.html" "$DOCS/SERVED-JN.html"

# ---------------------------------------------------------------------------
# REFUSED: a theme that does not exist. Named, with the real options listed,
# and nothing served — a server that quietly fell back to the default would be
# indistinguishable, in the browser, from a theme that does not work.
# ---------------------------------------------------------------------------
set_theme midnight
PORT=$(free_port)
run_in "$REPO" python3 "$TEST_TMP/runx.py" 20 "$HARNESS/bin/serve" "$PORT"
assert_rc_nonzero "an unknown docs.theme is refused"
assert_out "REFUSED" "loudly"
assert_out "midnight" "naming the theme that does not exist"
assert_out "daylight" "and listing the ones that do"
assert_out "high-contrast" "all of them"
assert_out "janus" "including the new default"
assert_out_words "Nothing was served" "saying explicitly that it did not serve anyway"
assert_no_traceback

run python3 "$TEST_TMP/probe.py" "$PORT"
assert_rc 0 "the probe answers"
assert_out "CLOSED" "the refusal bound no port — there is no broken page to open"
assert_not_out "TIMEOUT" "and it exited on its own rather than being cut off mid-serve"

# ---------------------------------------------------------------------------
# REFUSED: a name that is a path. docs.theme is a NAME; resolving "../../x"
# against lib/themes/ would read a file the config never named.
# ---------------------------------------------------------------------------
set_theme "../../etc/passwd"
run_in "$REPO" python3 "$TEST_TMP/runx.py" 20 "$HARNESS/bin/serve" "$(free_port)"
assert_rc_nonzero "a docs.theme with a path separator is refused"
assert_out "path separator" "naming what is wrong with it"
assert_out "is a NAME" "and what a theme actually is"

# ---------------------------------------------------------------------------
# REFUSED: a theme file that exists but says nothing. It passes the shell-side
# readability check, so this is the python half's own guard: a transform whose
# input is unusable must refuse, never pass the document through unchanged.
# ---------------------------------------------------------------------------
: > "$THEMES/blank.css"
set_theme blank
run_in "$REPO" python3 "$TEST_TMP/runx.py" 20 "$HARNESS/bin/serve" "$(free_port)"
assert_rc_nonzero "an empty theme file is refused"
assert_out "REFUSED" "loudly"
assert_out "is empty" "naming the problem"
assert_no_traceback
rm -f "$THEMES/blank.css"

# ---------------------------------------------------------------------------
# And it still serves afterwards: every refusal above is paired with the
# configuration that must work, so a lint that refuses everything cannot pass
# this case.
# ---------------------------------------------------------------------------
set_theme daylight
PORT=$(free_port)
start_server "$PORT" "$TEST_TMP/serve-again.log"
run python3 "$TEST_TMP/fetch.py" "http://127.0.0.1:$PORT/$DOC" "$TEST_TMP/again.html"
assert_rc 0 "a valid theme serves after the refusals"
run grep -F -- "$DL_BG" "$TEST_TMP/again.html"
assert_rc 0 "still applying daylight"
stop_server

assert_no_traceback "no command in this case may exit via a Python traceback"
