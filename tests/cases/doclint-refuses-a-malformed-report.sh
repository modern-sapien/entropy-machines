# bin/doclint — the mechanism behind the documentation rule.
#
# THE RULE: a report, plan or PRD in this factory is a LOCAL file. It is never
# published to an external site and never depends on one, and it has somewhere
# to answer in every section it asks about. bin/doclint is what enforces it;
# without this case the rule is a note, and a note is not a mechanism.
#
# BOTH DIRECTIONS ARE ASSERTED. A lint that refuses everything and a lint that
# passes everything look identical against one assertion, and this project has
# already shipped three gates that silently passed everything — one of them
# created by the fix for a crash. So every refusal here is paired with a
# document that must PASS: the shipped template, a restyled doc, and a doc
# using data:/relative/#anchor URIs.
#
# STYLE IS NOT POLICY. The palette, fonts and type scale in
# lib/REPORT-TEMPLATE.html are this project's default, not a conformance
# target — somebody vendoring this harness may want a report that looks
# nothing like ours. The `restyled` case below pins that: a serif font, a
# cream background and a 10px step must PASS.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

DOCS="$REPO/entropy-docs"
LINT="$HARNESS/bin/doclint"
TPL="$HARNESS/lib/REPORT-TEMPLATE.html"

assert_file "$TPL" "the harness ships a report template to copy"

# make_doc <name> <sed-ish python> — a doc derived from the template.
# Python, not sed: the edits below span lines and sed's in-place flag differs
# between GNU and BSD, which is exactly the portability trap this suite avoids.
make_doc() {
  _name="$1"; shift
  DOC_SRC="$TPL" DOC_OUT="$DOCS/$_name" python3 -c "$*"
}

# ---------------------------------------------------------------------------
# PASS: a doc built from the shipped template
# ---------------------------------------------------------------------------
cp "$TPL" "$DOCS/BUILD-REPORT-FROM-TEMPLATE.html"

run "$LINT" "$DOCS/BUILD-REPORT-FROM-TEMPLATE.html"
assert_rc 0 "a doc built from lib/REPORT-TEMPLATE.html passes"
assert_out "all local and answerable" "and says so"
assert_no_traceback

# ---------------------------------------------------------------------------
# REFUSE: no answer boxes — a broadcast, not a doc anyone can respond to
# ---------------------------------------------------------------------------
make_doc broadcast.html '
import os, re
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = re.sub(r"<div class=\"response\"[\s\S]*?</textarea>\s*</div>\n", "", s)
assert "data-resp=\"s-landed\"" not in s
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/broadcast.html"
assert_rc 1 "a doc with no answer boxes is refused"
assert_out "no-answer-boxes" "naming the problem by code"
assert_out "broadcast" "and in words"
assert_out "Landed" "and it names the sections that lost their box"
assert_out "Still open" "every one of them, not just the first"
assert_no_traceback

# ---------------------------------------------------------------------------
# REFUSE: an external stylesheet — THE rule. A doc that phones out is not a
# local doc: it stops working off this machine and it tells someone else's
# server that it was opened.
# ---------------------------------------------------------------------------
make_doc phones-home.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("<title>",
  "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Inter\">\n<title>", 1)
s = s.replace("<h1>", "<img src=\"//cdn.example.com/logo.png\" alt=\"\"><h1>", 1)
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/phones-home.html"
assert_rc 1 "a doc loading an external stylesheet is refused"
assert_out "external-reference" "naming the problem by code"
assert_out "https://fonts.googleapis.com/css2?family=Inter" "quoting the URL itself"
assert_out "//cdn.example.com/logo.png" "including a protocol-relative one"
assert_out "points off this machine" "and saying why that is the problem"
assert_no_traceback

# A remote font is refused because it is REMOTE, not because it is a font.
# Pin that: the same file, styled with a webfont declared inline against a
# local file, is fine.
make_doc local-font.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("<style>",
  "<style>@font-face{font-family:Mine;src:url(\"./mine.woff2\") format(\"woff2\")}", 1)
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/local-font.html"
assert_rc 0 "a webfont loaded from a file beside the doc is not the rule being enforced"

# ---------------------------------------------------------------------------
# PASS: data: URIs, relative paths and same-document anchors
#
# This assertion exists so nobody ever "fixes" the rule above by banning URIs
# in general. Embedding an image as a data: URI is the RECOMMENDED way to put
# a picture in a local doc; refusing it would push authors straight back to a
# remote <img src>.
# ---------------------------------------------------------------------------
make_doc local-uris.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("<h1>",
  "<img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\" alt=\"\">"
  "<a href=\"./PRD-001-orientation.html\">the PRD</a>"
  "<a href=\"#landed\">jump</a><h1>", 1)
s = s.replace("<p class=\"sub\">",
  "<p>Background reading lives at https://example.com/spec — text, not a fetch.</p>"
  "<p class=\"sub\">", 1)
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/local-uris.html"
assert_rc 0 "data: URIs, relative paths and #anchors pass"
assert_not_out "external-reference" "and prose that merely mentions a URL fetches nothing"

# ---------------------------------------------------------------------------
# PASS: a completely different look. Style is the author's; only local-only
# and answerable are enforced.
# ---------------------------------------------------------------------------
make_doc restyled.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("--fs-sm:12px;", "--fs-sm:10px;")
s = s.replace("--bg:#000;", "--bg:#f6f1e7;").replace("--ink:#fff;", "--ink:#3b2f2f;")
s = s.replace("ui-sans-serif,-apple-system,\"Segoe UI\",Roboto,sans-serif",
              "Georgia,\"Times New Roman\",serif")
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/restyled.html"
assert_rc 0 "a serif, cream, 10px doc passes — the aesthetic is a default, not a gate"

# ---------------------------------------------------------------------------
# REFUSE: the answers cannot reach disk
# ---------------------------------------------------------------------------
make_doc unsaveable.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("<button id=\"saveBtn\">", "<button>")
s = s.replace("<script type=\"application/json\" id=\"responses-data\">{}</script>", "")
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/unsaveable.html"
assert_rc 1 "a doc whose answers cannot reach disk is refused"
assert_out "no-save-button" "naming the missing save button"
assert_out "no-responses-data" "and the missing answer mirror"
assert_out "die in the browser" "and what that costs the reader"

# ---------------------------------------------------------------------------
# REFUSE: two boxes sharing one key. The second overwrites the first on save,
# silently — the reader answers twice and one answer is gone.
# ---------------------------------------------------------------------------
make_doc collide.html '
import os
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = s.replace("data-resp=\"s-verified\"", "data-resp=\"s-landed\"")
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/collide.html"
assert_rc 1 "two answer boxes sharing a key is refused"
assert_out "duplicate-key" "naming the problem"
assert_out "overwrites the first" "and the consequence"

# ---------------------------------------------------------------------------
# The declared opt-out: a section nobody is meant to answer says so in the
# markup. It is per-section and visible in the file — there is no flag and no
# whole-file exemption, because the failure being caught is a doc that LOOKS
# answerable and is not.
# ---------------------------------------------------------------------------
make_doc informational.html '
import os, re
s = open(os.environ["DOC_SRC"], encoding="utf-8").read()
s = re.sub(r"<div class=\"response\"[\s\S]*?</textarea>\s*</div>\n", "", s, count=1)
s = s.replace("<h2 id=\"landed\">", "<h2 id=\"landed\" data-informational>", 1)
open(os.environ["DOC_OUT"], "w", encoding="utf-8").write(s)
'

run "$LINT" "$DOCS/informational.html"
assert_rc 0 "an h2 marked data-informational needs no answer box"

# ---------------------------------------------------------------------------
# With no arguments it checks the configured docs directory, resolved the same
# way every other entry point resolves it — so it works from a subdirectory of
# the project too.
# ---------------------------------------------------------------------------
run_in "$REPO/src" "$LINT"
assert_rc 1 "with no arguments it finds the docs directory from a subdirectory"
assert_out "broadcast.html" "and reports the bad doc sitting in it"

rm -f "$DOCS"/*.html
cp "$TPL" "$DOCS/BUILD-REPORT-FROM-TEMPLATE.html"
run_in "$REPO/src" "$LINT"
assert_rc 0 "a docs directory holding only conforming docs passes"
assert_out "1 doc(s) checked" "counting what it actually read"

# ---------------------------------------------------------------------------
# A gate that cannot read its input REFUSES. It never reports success on
# nothing: three gates in this project were found passing everything, and the
# tell each time was a check that had no input and said nothing about it.
# ---------------------------------------------------------------------------
run "$LINT" "$DOCS/no-such-doc.html"
assert_rc 2 "a missing file is refused, not passed"
assert_out "REFUSED" "loudly"
assert_out "not a pass" "saying explicitly that nothing was checked"

rm -f "$DOCS"/*.html
run "$LINT"
assert_rc 2 "an empty docs directory is declined, not reported as clean"
assert_out "nothing was checked" "saying so"
assert_not_out "all local and answerable" "and never claiming a pass"

assert_no_traceback "no doclint invocation in this case may die on a traceback"
