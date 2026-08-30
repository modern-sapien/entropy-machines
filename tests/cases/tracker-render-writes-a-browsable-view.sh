# `bin/tracker render` writes TRACKER.html into the docs directory: a read-only
# browsable view of the issue store.
#
# WHAT THIS CASE IS REALLY GUARDING, in the order it matters:
#
#   1. THE PAGE MUST SAY WHY SOMETHING IS NOT CLAIMABLE. held, gated and
#      blocked are FIELD PRESENCE in this tracker, not status values, and an
#      issue can carry more than one at once. A view that flattens them into a
#      single "status" column loses the only thing a reader is there for. So
#      the assertions below are per-condition and per-reason, not "the id
#      appears somewhere".
#   2. IT MUST NOT INVENT A QUESTION. bin/serve and bin/status both scan the
#      docs directory for answer-box keys; a generated page carrying one would
#      be a question nobody can answer, and "fully answered" would become
#      unreachable. That has bitten this project twice. The case counts
#      unanswered questions before and after rendering and requires the same
#      number.
#   3. IT MUST NOT PHONE OUT. Every byte the page needs is in the file.
#   4. THE READY SET MUST BE THE TRACKER'S. lib/tracker-view.py re-states the
#      readiness rule (notstarted, not held, not gated, no open blocker) to
#      read the store in one atomic pass instead of three shell-outs. This
#      case compares the ids it marks ready against `bin/tracker ready` itself,
#      so the two definitions cannot drift apart unnoticed.
#
# The page is inspected through the JSON payload it inlines, not by looking for
# rendered text: the rows are built in the browser from that payload, so the
# payload is where the generator's answers actually are.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

DOCS="$REPO/entropy-docs"
PAGE="$DOCS/TRACKER.html"

# A reader over the inlined payload. Prints one line per query so a case can
# assert on it with assert_out.
read_page() {
  python3 - "$PAGE" "$@" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<script id="tracker-data" type="application/json">(.*?)</script>',
              text, re.S)
if not m:
    print("PAYLOAD-MISSING")
    raise SystemExit(0)
data = json.loads(m.group(1).replace("<\\/", "</"))
issues = data["issues"]
for query in sys.argv[2:]:
    kind, _, arg = query.partition(":")
    if kind == "ids":
        print("ids= " + " ".join(sorted(issues)))
    elif kind == "ready":
        print("ready= " + " ".join(sorted(i for i, v in issues.items()
                                          if "ready" in v["flags"])))
    elif kind == "flags":
        print("flags[%s]= %s" % (arg, " ".join(issues[arg]["flags"])))
    elif kind == "bucket":
        print("bucket[%s]= %s" % (arg, issues[arg]["bucket"]))
    elif kind == "held":
        print("held[%s]= %s" % (arg, issues[arg]["heldWhy"]))
    elif kind == "gate":
        print("gate[%s]= %s" % (arg, issues[arg]["gate"]))
    elif kind == "blockers":
        print("blockers[%s]= %s" % (arg, " ".join(issues[arg]["openBlockers"])))
    elif kind == "title":
        print("title[%s]= %s" % (arg, issues[arg]["title"]))
    elif kind == "notes":
        print("notes[%s]= %s" % (arg, json.dumps(issues[arg]["notes"], sort_keys=True)))
PY
}

# --- nothing filed yet ------------------------------------------------------
# An empty store still renders: a factory with no issues is a real state, and a
# page that refuses to exist until someone files something is a worse first
# impression than an empty one.
run "$HARNESS/bin/tracker" render
assert_rc 0 "render an empty tracker"
assert_file "$PAGE" "render writes TRACKER.html into the docs directory"
assert_out "TRACKER.html" "and says where it wrote it"

# --- one issue in every state ----------------------------------------------
run "$HARNESS/bin/tracker" set i-ready title="Claimable right now" effort=S
assert_rc 0 "file a ready issue"
run "$HARNESS/bin/tracker" set i-live title="Being worked" effort=M status=progress
assert_rc 0 "file an in-progress issue"
run "$HARNESS/bin/tracker" set i-done title="Finished" effort=S status=done
assert_rc 0 "file a done issue"
run "$HARNESS/bin/tracker" set i-held title="Not now" effort=L \
    heldWhy="owner wants the CLI shipped first"
assert_rc 0 "file a held issue"
run "$HARNESS/bin/tracker" set i-gated title="Waiting on a ruling" \
    gate="prd-001-q3-tracker-backend"
assert_rc 0 "file a gated issue"
run "$HARNESS/bin/tracker" set i-blocked title="Waits on i-ready" blockedBy="i-ready"
assert_rc 0 "file a blocked issue"
run "$HARNESS/bin/tracker" set i-both title="Half done, then held" status=progress \
    heldWhy="paused after the API changed"
assert_rc 0 "file an issue that is in progress AND held"

run "$HARNESS/bin/tracker" render
assert_rc 0 "render with every state present"
assert_out "7 issue(s)" "the summary counts every issue"

# --- every issue is on the page --------------------------------------------
run read_page ids:
assert_rc 0 "the page carries a readable payload"
assert_not_out "PAYLOAD-MISSING" "the payload block is the shape the reader expects"
for id in i-ready i-live i-done i-held i-gated i-blocked i-both; do
  assert_out "$id" "$id must appear on the page"
done

# --- WHY it is not claimable, one condition at a time -----------------------
# Each of the three must be distinguishable from the other two: a different
# field, carrying a different reason, in a different bucket.
run read_page held:i-held bucket:i-held flags:i-held
assert_out "held[i-held]= owner wants the CLI shipped first" \
  "a held issue carries its REASON, not just the fact of the hold"
assert_out "bucket[i-held]= held" "and is grouped as held"

run read_page gate:i-gated bucket:i-gated flags:i-gated
assert_out "gate[i-gated]= prd-001-q3-tracker-backend" \
  "a gated issue names the open question it is waiting on"
assert_out "bucket[i-gated]= gated" "and is grouped as gated, not as held"
assert_out "flags[i-gated]= gated" "gated is its own flag"

run read_page blockers:i-blocked bucket:i-blocked
assert_out "blockers[i-blocked]= i-ready" \
  "a blocked issue names the OPEN issue blocking it"
assert_out "bucket[i-blocked]= blocked" "and is grouped as blocked, not held or gated"

# The three conditions must not be one column. An issue that is both in
# progress and held keeps both.
run read_page flags:i-both held:i-both
assert_out "flags[i-both]= inflight held" \
  "an issue that is in flight AND held keeps both — the view never flattens them"
assert_out "held[i-both]= paused after the API changed" "with the hold's reason intact"

run read_page flags:i-ready flags:i-live flags:i-done
assert_out "flags[i-ready]= ready" "a claimable issue is flagged ready"
assert_out "flags[i-live]= inflight" "an in-progress issue is flagged in flight"
assert_out "flags[i-done]= done" "a finished issue is flagged done"

# --- the ready set is the tracker's, not a second opinion -------------------
run "$HARNESS/bin/tracker" ready
assert_rc 0 "bin/tracker ready"
CLI_READY=$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
print(" ".join(sorted(json.loads(l)["id"] for l in sys.stdin if l.strip())))')
run read_page ready:
assert_out "ready= $CLI_READY" \
  "the ids the page calls ready must be exactly the ids bin/tracker ready returns"

# --- the notes are on the page, DISPATCH and HANDOFF included ---------------
# This is the audit trail of who was given what; a tracker view without it
# cannot answer "who has this and what were they told".
fixture_hooks
run env ENTROPY_ACTOR=orchestrator "$HARNESS/bin/dispatch" i-ready \
    --files "src/main.c" --brief "wire the picker to the engine"
assert_rc 0 "dispatch an issue so there is a DISPATCH note"

run "$HARNESS/bin/tracker" render
assert_rc 0 "re-render after the dispatch"
run read_page notes:i-ready
assert_out '"verb": "DISPATCH"' "the DISPATCH note is on the page"
assert_out "wire the picker to the engine" "with the brief the agent was given"
assert_out "src/main.c" "and the file scope it was handed"

# A HANDOFF note is written by bin/handoff out of a real worktree; the note
# itself is what this page renders, so the case writes one through the same
# remember-payload convention bin/handoff uses (lib/notes.py).
PAYLOAD=$(python3 "$HARNESS/lib/notes.py" encode --verb HANDOFF --actor orchestrator \
  --field changed="rewrote the entry point" --field verified="I re-ran the suite myself")
run "$HARNESS/bin/tracker" remember --issue i-ready "$PAYLOAD"
assert_rc 0 "record a HANDOFF note"
run "$HARNESS/bin/tracker" render
assert_rc 0 "re-render after the handoff note"
run read_page notes:i-ready
assert_out '"verb": "HANDOFF"' "the HANDOFF note is on the page too"
assert_out "rewrote the entry point" "with what the worker said it changed"

# --- NO PHANTOM QUESTIONS ---------------------------------------------------
# bin/status counts answer-box keys across the docs directory. Rendering into
# that directory must not change the count. It also must not carry the save
# wiring: this page is generated, so there is nothing to save back.
run "$HARNESS/bin/status"
assert_rc 0 "bin/status after rendering"
assert_out "5 unanswered question(s) across 1 doc(s)" \
  "TRACKER.html adds no question of its own — the count is the PRD's alone"

if grep -q "data-resp" "$PAGE"; then
  OUT=$(grep -n "data-resp" "$PAGE"); ERR=""; ALL="$OUT"; RC=0
  LAST_CMD="grep data-resp $PAGE"
  _fail "the generated view must contain NO answer-box key" \
        "one there is a question nobody can answer, and bin/status can never go green"
fi
if grep -qE 'id="(saveBtn|responses-data)"' "$PAGE"; then
  OUT=$(grep -nE 'id="(saveBtn|responses-data)"' "$PAGE"); ERR=""; ALL="$OUT"; RC=0
  LAST_CMD="grep for save wiring in $PAGE"
  _fail "the generated view must not carry save wiring" \
        "it is regenerated, not answered — a save button on it would lie"
fi

# --- NO EXTERNAL REFERENCES -------------------------------------------------
if grep -qE 'https?://|(href|src)=\"//' "$PAGE"; then
  OUT=$(grep -nE 'https?://|(href|src)=\"//' "$PAGE"); ERR=""; ALL="$OUT"; RC=0
  LAST_CMD="grep for remote references in $PAGE"
  _fail "the generated view must fetch nothing from off this machine" \
        "no CDN, no webfont, no remote anything"
fi

# --- it says it is generated ------------------------------------------------
run grep -c "GENERATED FILE" "$PAGE"
assert_rc 0 "the page declares itself generated, so nobody hand-edits it"
# …and says it again where a tool can see it. bin/doclint masks HTML comments
# before it reads anything, so the sentence above is invisible to it; this
# attribute is the hook a check needs to tell a generated read-only view (which
# legitimately has no answer box) from a doc that forgot one.
run grep -c 'data-generated="bin/tracker render"' "$PAGE"
assert_rc 0 "and declares it in markup, outside a comment"

# --- re-rendering picks up a change ----------------------------------------
run "$HARNESS/bin/tracker" set i-held heldWhy=
assert_rc 0 "release the hold"
run read_page bucket:i-held
assert_out "bucket[i-held]= held" \
  "before re-rendering, the page still shows the OLD state — it is a snapshot"
run "$HARNESS/bin/tracker" render
assert_rc 0 "re-render"
run read_page bucket:i-held flags:i-held held:i-held
assert_out "bucket[i-held]= ready" "re-rendering picks up the released hold"
assert_out "held[i-held]= " "and the reason is gone with it"

# --- a `command` backend is refused, not half-rendered ----------------------
# The six-operation adapter contract cannot enumerate issues, so a page built
# from it would silently omit every held, gated, blocked and done issue and
# still look complete.
python3 - "$REPO/entropy.json" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path, encoding="utf-8"))
cfg["tracker"] = {"backend": "command", "command": {"bin": "./nope", "args": []}}
json.dump(cfg, open(path, "w", encoding="utf-8"), indent=2)
PY
run "$HARNESS/bin/tracker" render
assert_rc_nonzero "render must refuse a backend it cannot enumerate"
assert_out "REFUSED" "the refusal says so"
assert_out_words "has no operation that lists issues" "and names why it cannot be done"
