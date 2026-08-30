#!/usr/bin/env bash
# handoff-guard — a commit that lands a DISPATCHED issue must carry a handoff
# record for it.
#
#   lib/handoff-guard.sh --message .git/COMMIT_EDITMSG   # commit-msg hook
#   lib/handoff-guard.sh --commit <sha>                  # audit one commit
#   lib/handoff-guard.sh --range A..B                    # audit a range
#
# LOCAL-ONLY BY DESIGN, AND THAT IS NOT THE WEAK CASE HERE. changelog-guard.sh
# is mirrored by a CI job because the rule it enforces has to hold for anything
# that reaches the remote. This one does not: agents are dispatched, landed and
# verified locally by design, so the machine doing the landing is
# always the machine with the hook, and a handoff that never left a laptop has
# still done its whole job — the next session reads it out of the same log.
#
# A CI job would also be impossible if we wanted one. The record lives in the
# tracker's note log, which is commonly gitignored in its
# entirety (.gitignore:37), so a runner checks out a tree with no log, reads
# nothing, and passes everything. Do not "fix" that by moving the record
# somewhere tracked: the log is where agents and sessions already read, and
# splitting it to satisfy a check nobody runs would cost the thing that makes
# it useful.
#
# The real local failure mode is not CI's absence — it is a checkout that never
# ran `npm run hooks:install` and therefore has no gate while looking exactly
# like one that does. bin/dispatch refuses to brief an agent from such a
# checkout, which puts the check immediately before the only activity this gate
# protects. --range and --commit audit history by hand.
#
# WHY commit-msg AND NOT pre-commit. The gate keys on the issue id in the
# commit message, and pre-commit runs before a message exists. changelog-guard
# can live in pre-commit because it only reads the index; this cannot.
#
# WHAT IT GATES, AND WHAT IT DELIBERATELY DOES NOT. It fires only for an id
# that bin/dispatch actually recorded a DISPATCH note for. A commit naming
# an issue you did yourself, by hand, passes untouched — there was no agent, so
# there is nothing to salvage from a worktree. This keeps the gate off the
# large majority of commits and pointed at the one case that loses knowledge.
#
# GRANDFATHERING, WHICH IS OFF BY DEFAULT AND EXISTS FOR ADOPTERS. When this
# gate first landed in its home repo, several agents were already in flight,
# briefed under the old protocol and unable to know about the new one.
# Refusing their landings would have stranded other sessions' work for a rule
# written after they started.
#
# The fix generalises, so it is kept as an option rather than a baked-in date:
# set `guards.handoffCutoff` (an ISO-8601 timestamp) in entropy.json and a
# dispatch recorded BEFORE it warns and passes, while one recorded after
# refuses. The exemption then expires BY ITSELF as those dispatches land —
# there is no flag anyone must remember to flip, and no window in which the
# rule is off for new work. That self-expiry is the part worth copying.
#
# A FRESH INSTALL WANTS NO CUTOFF AT ALL, and that is the default: with the
# key absent every dispatch is judged by the rule. Only set it if you are
# turning this gate on in a repo that already has agents mid-flight.
#
# ESCAPE HATCH, in the two forms the callers need (commit-msg has the message
# but CI has only history):
#
#   SKIP_HANDOFF=1 git commit -m "fix(x): partial landing (i-foo) [skip handoff]"
#
# Use both or it passes locally and fails in CI. `--no-verify` is not a hatch:
# it skips the hook and leaves nothing behind.
#
# ===========================================================================
# THE SECOND CHECK — an ID-LESS COMMIT INTO AN OPEN DISPATCH'S SCOPE
#
# ===========================================================================
#
# THE HOLE. Everything above keys on an issue id, recovered from the message or
# from a changelog.d fragment's `issue:` line. changelog-guard.sh only requires
# a fragment for the project's own code paths. So a commit that touches only
# tooling and tests, names no id and adds no fragment has NO id to recover,
# and this guard has nothing to refuse — the whole protocol is off. Every
# commit in the 2026-08-26/27 harness sprint was that shape, which is where
# dispatch discipline matters most.
#
# THE RULE, AND WHY IT IS THIS NARROW. When a commit names NO id at all and
# touches a path that a dispatch is HOLDING at that moment (a DISPATCH note
# with no later HANDOFF, inside the same 24h claim window bin/dispatch
# uses), it is refused. Naming the id is enough to satisfy it — and that hands
# the commit to the id-keyed check above, which then wants the handoff record.
#
# WHY NOT THE OBVIOUS STRONGER RULE — "a commit touching an open scope must
# name THAT id". MEASURED, not argued, over the last 100 commits of this repo:
#
#     rule                                                    would refuse
#     must name the holding id, directory claims bind         19 / 100
#     must name the holding id, exact file claims only        10 / 100
#     id-less only, directory claims bind (SHIPPED)            1 / 100
#
# 20 of those 100 commits name no id at all, so the shipped rule is quiet on 19
# of the 20 it is even eligible to look at. The one it refuses is the target
# shape, not a false positive: its fragment's `issue:` line is EMPTY and it
# writes a file another dispatch was holding, undispatched-looking and
# unlanded. Reproduce the table over your own history with
# `lib/handoff-guard.sh --range HEAD~100..HEAD`.
#
# The stronger rule's refusals are not evasions. A scope line is a prediction
# (`--files` is advisory, per bin/dispatch), and it routinely lists hub or
# generated files — src/shared/types.ts, internal/controller/controller.mjs,
# the entry point and a generated controller — that every other landing
# also touches. Refusing 10-20% of ordinary landings is how a gate becomes
# noise: "a job that cries wolf gets ignored, which is worse than no job"
# (lib/fail-first.mjs). A commit that names an id is already inside the
# protocol and the check above engages on it; a commit that names none is the
# one case where nothing engages at all.
#
# THE RESIDUAL GAP, STATED RATHER THAN PAPERED OVER. A commit that names id A
# and quietly carries a file held by agent B still passes this check. It does
# not pass unexamined — A's own handoff record is demanded above — but B's work
# can ride along under A's id. Closing that is the 10/100 rule, and the
# measurement says the cost is not payable. `bin/handoff --lift` is the
# other end of that case: it refuses to lift a file outside the agent's scope.
#
# NEVER CLAIMABLE, mirroring bin/dispatch's NEVER_CLAIMED: changelog.d/,
# because every agent writes its own fragment there BY DESIGN, and
# docs/CHANGELOG.md, which is collated output no one hand-edits (CLAUDE.md) and
# which was the single false positive in the 100-commit measurement — a
# `docs/` scope claim walling off `npm run changelog:collate`.
#
# SAME ESCAPE HATCH, both halves: SKIP_HANDOFF=1 for the hook, `[skip handoff]`
# in the message for the audit modes. There is no CI mirror to satisfy here
# (the log is gitignored), but the marker is what makes `--range` quiet later.
#
# TIME IS READ FROM THE COMMIT, NOT FROM NOW, in the audit modes: the question
# is whether a dispatch was open AT THE MOMENT THE COMMIT WAS MADE. `--range`
# over history is therefore also the measurement instrument for the table
# above; re-run it before changing the rule.

set -euo pipefail

# ENTROPY_HOME is the harness DIRECTORY — where config.py sits — which may be
# the repo root or a subdirectory of it. It is not a root and not a separate
# repo (see lib/roots.sh). The shim installed by lib/install-hooks.sh exports
# it; the fallback is for direct invocation, by hand or from a test.
#
# RESOLVED FIRST, before anything references it. It used to be assigned BELOW
# the cutoff block, which then had to re-derive it inline — and a single
# reference to the not-yet-assigned variable was an unbound-variable crash
# under `set -u`, i.e. a gate that died instead of refusing.
if [ -z "${ENTROPY_HOME:-}" ]; then
  ENTROPY_HOME="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
fi

# TWO DIFFERENT TREES, one root. Both are computed here so the distinction is
# visible in one place:
#
#   TREE  the working tree this commit belongs to — `--show-toplevel`, i.e.
#         the LINKED WORKTREE when a worker is committing from one. The staged
#         changelog.d fragments being committed are on disk there and nowhere
#         else, so fragment reads must use this.
#   ROOT  the repository's MAIN checkout — `--git-common-dir` via
#         lib/roots.sh. The tracker's note log lives under .entropy/, which is
#         gitignored and therefore absent from every worktree, so the dispatch
#         memory must be read from here. Resolving it with --show-toplevel
#         found no memory file inside a worktree and the guard passed
#         everything in silence.
#
# `|| true` on both: a guard that cannot resolve its own inputs must decline
# to judge (below), not die. Dying inside a hook reads as a broken tool.
. "$(dirname -- "$0")/roots.sh"
TREE="$(git rev-parse --show-toplevel 2>/dev/null || true)"
ROOT="$(entropy_root 2>/dev/null || true)"

# Empty unless the project opts in — see the grandfathering note above.
CUTOFF="$(
  cd "${TREE:-$PWD}" 2>/dev/null &&
  python3 "$ENTROPY_HOME/lib/config.py" get guards.handoffCutoff 2>/dev/null | tr -d '"' || true
)"
# `if`, not `[ ... ] && ...` — under `set -e` a failing test as the last
# command of a compound exits the script, which would make this gate pass
# everything in silence. That is the exact failure this file exists to prevent.
if [ "$CUTOFF" = "null" ]; then CUTOFF=""; fi
SKIP_MARKER='[skip handoff]'

# HANDOFF_MEMORY is a TEST SEAM, not a bypass — tests/core/commit-gate-open-
# dispatch.test.ts points it at a fixture so it can exercise the refuse path
# without writing fake DISPATCH notes into the log two other sessions are
# reading. SKIP_HANDOFF is the supported escape hatch; do not set this one in
# CI. (Until 2026-08-27 this comment said "the self-test below", and there was
# no self-test below and never had been.)
# Where the note log lives is the tracker backend's business, so ask it rather
# than hardcoding a path. Falls back to the built-in backend's default.
if [ -n "${HANDOFF_MEMORY:-}" ]; then
  MEMORY="$HANDOFF_MEMORY"
elif [ -n "$ROOT" ]; then
  MEMORY="$ROOT/$(
    cd "$ROOT" 2>/dev/null &&
    python3 "$ENTROPY_HOME/lib/config.py" get tracker.file.path 2>/dev/null | tr -d '"' || true
  )"
else
  MEMORY=""
fi

# .entropy/ is gitignored per-checkout state. No memory file means no way to
# know what was dispatched, so the guard has nothing to say — it must pass
# rather than block a commit it cannot reason about. Same for an unresolvable
# root: decline to judge, do not die.
if [ -z "$MEMORY" ] || [ ! -f "$MEMORY" ]; then
  exit 0
fi

if [ "${SKIP_HANDOFF:-}" = "1" ]; then
  echo "handoff-guard: SKIP_HANDOFF=1 — skipped."
  exit 0
fi

mode=""; arg=""
case "${1:-}" in
  --message|--commit|--range) mode="$1"; arg="${2:-}" ;;
  *) echo "usage: handoff-guard.sh --message <file> | --commit <sha> | --range A..B" >&2; exit 2 ;;
esac
[ -n "$arg" ] || { echo "handoff-guard: $mode needs an argument" >&2; exit 2; }

# Issue ids named by the changelog.d fragments this commit adds.
#
# WHY THE MESSAGE IS NOT ENOUGH. The gate keyed only on ids in the commit
# message, so simply forgetting to write "(i-foo)" turned it off — silently,
# with no diagnostic, in the one place the whole protocol is mechanical. That is
# not a bypass anyone has to intend; it is a typo-grade omission, and a gate you
# disable by forgetting is a gate that protects only the people who did not need
# it. Every commit touching the project's code paths must already carry a fragment
# (changelog-guard.sh), and a fragment declares `issue:` — so the id is
# recoverable from the commit's own contents. Both sources are unioned.
# $2 is a rev to read the fragments FROM; empty means the working tree (the
# --message case, where the commit does not exist yet and the files are staged).
# The audit modes pass a sha, because a fragment can be collated away later and
# reading the worktree would then find nothing.
fragment_ids() {
  local files="$1" rev="${2:-}" f body ids=""
  for f in $files; do
    case "$f" in changelog.d/*.md) ;; *) continue ;; esac
    if [ -n "$rev" ]; then
      body=$(git show "$rev:$f" 2>/dev/null || true)
    elif [ -n "$TREE" ] && [ -f "$TREE/$f" ]; then
      # $TREE, not $ROOT: the fragment being committed is staged in THIS
      # working tree, which is a linked worktree when a worker is committing.
      body=$(cat "$TREE/$f")
    else
      continue
    fi
    ids="$ids $(printf '%s' "$body" | sed -n 's/^issue:[[:space:]]*//p' | head -1)"
  done
  printf '%s' "$ids"
}

# ONE definition of "which ids does this commit name", used by both checks.
# Duplicating the pattern would let the two disagree about what counts as
# naming an id, and the second check's whole rule is "names none of them".
ids_in() {
  printf '%s %s' "$1" "${2:-}" | grep -oE '\bi-[a-z0-9][a-z0-9-]{4,}' | sort -u || true
}

check_message() {
  local msg="$1" label="$2" extra="${3:-}"
  case "$msg" in *"$SKIP_MARKER"*) return 0 ;; esac

  local ids
  ids=$(ids_in "$msg" "$extra")
  [ -n "$ids" ] || return 0

  local rc=0
  for id in $ids; do
    MEMORY="$MEMORY" ID="$id" CUTOFF="$CUTOFF" LABEL="$label" python3 - <<'PY' || rc=1
import json, os, sys

mem, iid = os.environ["MEMORY"], os.environ["ID"]
cutoff, label = os.environ["CUTOFF"], os.environ["LABEL"]

def records(path):
    """Every note in the store, whatever shape the store is.

    TWO SHAPES, because this gate outlived one of them and DIED on the other.
    lib/tracker-file writes ONE JSON DOCUMENT -- {"issues": {...}, "notes":
    [...]} -- pretty-printed over many lines. The reader here used to iterate
    LINES and json.loads() each one, which is the shape of an older flat JSONL
    log. Against the current store that mostly raised JSONDecodeError and was
    skipped, until a line that happens to be a bare JSON string on its own
    (`          "src/main.c"`, one element of a pretty-printed scope array)
    parsed CLEANLY to a str, and `.get` on a str is an AttributeError. The gate
    then exited non-zero with a traceback: every commit naming any i- id was
    blocked by what read as a broken tool rather than a rule. Confirmed on the
    pristine file, so it predates the one-root collapse.

    Both shapes are read, and anything unparseable yields nothing rather than
    raising -- a guard that cannot read its own store must decline to judge.
    """
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return []
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("notes"), list):
        return [r for r in doc["notes"] if isinstance(r, dict)]
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


dispatched = handed = None
for e in records(mem):
    ts = e.get("ts") or ""
    # A record carries the verb structurally (tracker-file / lib/notes.py) or
    # inline at the head of a free-text note (the older flat log). Match on the
    # note BODY as well as the issue key: --issue is optional on `remember`,
    # and a note filed without it still records the dispatch.
    verb = e.get("verb") or ""
    issue = e.get("issue") or ""
    # The free text lives at the top level in the old flat log and under
    # "fields" in lib/notes.py's record. bin/handoff files its handoff as
    # verb NOTE with the verb word at the head of fields.text, so reading only
    # the top level saw the DISPATCH and never the HANDOFF -- the gate would
    # then refuse the same commit forever, after the handoff was recorded.
    text = e.get("text")
    if not isinstance(text, str):
        fields = e.get("fields")
        text = fields.get("text") if isinstance(fields, dict) else None
    if not isinstance(text, str):
        text = ""
    is_dispatch = (verb == "DISPATCH" and issue == iid) or text.startswith(f"DISPATCH {iid} ")
    is_handoff = (verb == "HANDOFF" and issue == iid) or text.startswith(f"HANDOFF {iid} ")
    if is_dispatch:
        dispatched = ts
    elif is_handoff:
        handed = ts

if dispatched is None:
    sys.exit(0)                      # nobody dispatched this — not agent work
if handed is not None and handed > dispatched:
    sys.exit(0)                      # handed off after the most recent dispatch

stale = handed is not None          # handed off, then re-dispatched
why = ("the handoff on record predates the latest dispatch"
       if stale else "no handoff was recorded")

if cutoff and dispatched < cutoff:
    print(f"handoff-guard: WARNING on {label} — {iid} was dispatched at "
          f"{dispatched} and {why}.")
    print(f"  Dispatched before this project's handoff cutoff ({cutoff}), so "
          f"not blocked. Record it anyway once the work is verified:")
    print(f'    bin/handoff {iid} --changed "..." --verified "..." '
          f'[--found "..."] [--next "..."] [--clean]')
    sys.exit(0)

print(f"handoff-guard: REFUSED on {label} — {iid} was dispatched at "
      f"{dispatched} and {why}.", file=sys.stderr)
print("  An agent's dead ends, out-of-scope findings and assumptions live only "
      "in a worktree that is about to be deleted.", file=sys.stderr)
print(f'    bin/handoff {iid} --changed "..." --verified "..." '
      f'[--found "..."] [--next "..."] [--clean]', file=sys.stderr)
print(f"  Genuinely nothing to hand off: pass --clean. Not agent work at all: "
      f"SKIP_HANDOFF=1 and '{'[skip handoff]'}' in the message.", file=sys.stderr)
sys.exit(1)
PY
  done
  return $rc
}

# An id-less commit into a scope some dispatch is holding right now. See the
# long block at the top of this file for the rule, the measurement behind it,
# and the residual gap it deliberately leaves open.
check_scope() {
  local msg="$1" label="$2" paths="$3" when="$4" extra="${5:-}"
  case "$msg" in *"$SKIP_MARKER"*) return 0 ;; esac
  # Named an id: the id-keyed check above owns this commit. Measured — see the
  # table in the header; demanding the SPECIFIC id here refuses 10-20% of
  # ordinary landings.
  [ -z "$(ids_in "$msg" "$extra")" ] || return 0
  [ -n "$paths" ] || return 0

  MEMORY="$MEMORY" LABEL="$label" PATHS="$paths" WHEN="$when" \
  CLAIM_HOURS="${DISPATCH_CLAIM_HOURS:-24}" python3 - <<'PY'
import datetime, json, os, re, sys

paths = os.environ["PATHS"].split()
def _ts(v):
    """Parse a note/commit timestamp, tolerating a trailing Z.

    tracker-file stamps notes UTC as `...:43Z`; this reader's format string had
    no %z and no Z, so EVERY note raised ValueError and was skipped. It was
    invisible because the JSONL crash above aborted the block before reaching
    here -- fixing that crash turned a gate that exploded into one that
    silently passed everything. Both halves are the same defect: a guard that
    cannot read its own store must refuse or decline, never quietly allow.
    """
    if not isinstance(v, str):
        return None
    v = v.strip()
    if v.endswith("Z"):
        v = v[:-1]
    try:
        return datetime.datetime.strptime(v, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


label = os.environ["LABEL"]
try:
    hours = float(os.environ.get("CLAIM_HOURS") or 24)
except ValueError:
    hours = 24.0
now = _ts(os.environ["WHEN"])
if now is None:
    sys.exit(0)          # cannot place the commit in time — say nothing

# NEVER CLAIMABLE. changelog.d/ is one file per entry BY DESIGN so two agents
# never contend; docs/CHANGELOG.md is collated output nobody hand-edits, and a
# `docs/` scope claim over it was a false positive in the 100-commit
# measurement.
#
# EXEMPTED ON BOTH SIDES, and only one of them is enough on its own. Dropping
# these from the CLAIM covers `scope: changelog.d/`; dropping them from the
# COMMIT'S PATHS covers the other direction, a `docs/` claim swallowing
# docs/CHANGELOG.md through the prefix match. The first version had only the
# claim-side filter and the audit refused the changelog collation commit.
NEVER_CLAIMED = ("changelog.d", "docs/CHANGELOG.md")

def exempt(p):
    return any(p == n or p.startswith(n + "/") for n in NEVER_CLAIMED)

paths = [p for p in paths if not exempt(p)]
if not paths:
    sys.exit(0)

# ANCHORED TO THE START OF THE NOTE BODY, NOT SEARCHED FOR IN IT. Of the 135
# notes in the live log whose text contains "DISPATCH" on 2026-08-27, only 106
# ARE one; the other 29 mention it inside a HANDOFF's free text. A handoff note
# that quoted this very format was read as a dispatch once and left two issues
# holding their files after they were handed off (see bin/dispatch). Here
# the subject is the JSON `text` field, so `^` is exact rather than a prefix
# guess, and both verbs come from ONE match so their order cannot matter.
VERB = re.compile(r"^(DISPATCH|HANDOFF)\s+(\S+)\s+—")

def strip(p):
    p = re.sub(r"\(own\)$", "", p)
    p = re.sub(r"/\*.*$", "", p)
    return p.rstrip("/")

# TWO STORE SHAPES, TWO RECORD SHAPES, AND THIS READER MUST SURVIVE BOTH.
#
# SHAPE OF THE FILE. tracker-file writes ONE pretty-printed JSON document;
# older stores were JSONL. Reading the pretty-printed form a line at a time
# makes `json.loads` succeed on a bare value line — `"src/main.c"` parses to a
# str — and the next `.get()` raised AttributeError. That crash is why this
# check was not gating: it exited on a traceback instead of a verdict, and a
# gate that cannot read its own store must DECLINE, never explode.
#
# SHAPE OF A RECORD. Notes now carry structured fields
# ({"verb": "DISPATCH", "issue": ..., "fields": {"scope": [...]}}); they used
# to carry one rendered em-dash-separated "text" string. Structured is read
# first and the regex is the fallback, so a store holding both still works.
def _load_notes(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return []
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("notes"), list):
        return [r for r in doc["notes"] if isinstance(r, dict)]
    if isinstance(doc, list):
        return [r for r in doc if isinstance(r, dict)]
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


def _read(e):
    """(verb, issue, scope-string) for one note, or None if it is not one."""
    verb = e.get("verb")
    issue = e.get("issue")
    if isinstance(verb, str) and isinstance(issue, str) and verb in ("DISPATCH", "HANDOFF"):
        fields = e.get("fields")
        scope = fields.get("scope") if isinstance(fields, dict) else None
        if isinstance(scope, list):
            scope = " ".join(str(x) for x in scope)
        return verb, issue, (scope if isinstance(scope, str) else "")
    text = e.get("text")
    if not isinstance(text, str):
        return None
    m = VERB.match(text)
    if not m:
        return None
    # Searched from the END OF THE ID GROUP: VERB already consumed the first em
    # dash. Bounded by `— brief:` so the denylist field, which is also a path
    # list and sits after the brief, can never be read as scope.
    hit = re.search(r"—\s+scope:\s*(.*?)\s+—\s+brief:", text[m.end(2):])
    return m.group(1), m.group(2), (hit.group(1).strip() if hit else "")


events = []
for e in _load_notes(os.environ["MEMORY"]):
    parsed = _read(e)
    if not parsed:
        continue
    ts = _ts(e.get("ts"))
    if ts is None:
        continue
    if ts > now:
        continue        # not yet true when this commit was made
    events.append((ts, parsed))
events.sort(key=lambda r: r[0])

live = {}
for ts, (verb, iid, scope) in events:
    if verb == "HANDOFF":
        live.pop(iid, None)
        continue
    if not scope:
        continue
    live[iid] = (ts, scope)

hits = []
for iid, (ts, scope) in live.items():
    if now - ts >= datetime.timedelta(hours=hours):
        continue            # the claim expired, same window bin/dispatch uses
    held = [strip(p) for p in re.split(r"[\s,]+", scope) if strip(p)]
    held = [p for p in held if not exempt(p) and p not in ("(none)", "(unavailable)")]
    for f in paths:
        if any(f == p or f.startswith(p + "/") for p in held):
            hits.append((iid, f, ts))
            break

if not hits:
    sys.exit(0)

print(f"handoff-guard: REFUSED on {label} — it names no issue id, and it "
      f"touches a file an open dispatch is holding:", file=sys.stderr)
for iid, f, ts in sorted(hits):
    print(f"    {f}  — held by {iid}, dispatched {ts.isoformat()}, not handed off",
          file=sys.stderr)
print("  Landing that agent's work: name the id in the message, then record "
      "the handoff:", file=sys.stderr)
print('    bin/handoff <id> --changed "..." --verified "..." '
      '[--found "..."] [--next "..."] [--clean]', file=sys.stderr)
print("  Unrelated work that happens to sit in an open scope: SKIP_HANDOFF=1 "
      "and '[skip handoff]' in the message.", file=sys.stderr)
sys.exit(1)
PY
}

# In --message mode the commit does not exist yet, so the fragments are whatever
# is STAGED. In the audit modes they are the files the commit itself added.
case "$mode" in
  --message)
    staged=$(git diff --cached --name-only --diff-filter=AM 2>/dev/null || true)
    # EVERY staged path, not just added/modified: a delete or a rename's old
    # name is exactly the clobber the scope check is looking for.
    touched=$(git diff --cached --name-only --no-renames 2>/dev/null || true)
    msg=$(cat "$arg")
    frags=$(fragment_ids "$staged")
    check_message "$msg" "this commit" "$frags"
    check_scope "$msg" "this commit" "$touched" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$frags"
    ;;
  --commit)
    added=$(git show --name-only --diff-filter=AM --format= "$arg" 2>/dev/null || true)
    touched=$(git show --name-only --no-renames --format= "$arg" 2>/dev/null || true)
    msg=$(git log -1 --format=%B "$arg")
    label=$(git log -1 --format='%h %s' "$arg")
    frags=$(fragment_ids "$added" "$arg")
    check_message "$msg" "$label" "$frags"
    # The COMMIT's own time, not now: the question is whether a dispatch was
    # open at the moment it was made.
    #
    # format-UTC, and the difference is not cosmetic. `%cd --date=format:`
    # renders in the timezone RECORDED IN THE COMMIT, which for a commit made
    # elsewhere is not this machine's. Note-log timestamps are UTC with a
    # trailing Z (lib/notes.py stamps `datetime.now(timezone.utc)`), so both
    # sides of the comparison must be UTC.
    #
    # THIS COMMENT USED TO SAY LOCAL, AND SO DID THE CODE. Against UTC notes
    # every dispatch looked like it was made in the FUTURE (`ts > now`), so the
    # scope check skipped every note and passed every commit. It went unseen
    # because a JSONL crash aborted the block before it could matter.
    check_scope "$msg" "$label" "$touched" \
      "$(git log -1 --format=%cd --date=format-utc:'%Y-%m-%dT%H:%M:%SZ' "$arg")" "$frags"
    ;;
  --range)
    rc=0
    for sha in $(git rev-list --no-merges "$arg"); do
      added=$(git show --name-only --diff-filter=AM --format= "$sha" 2>/dev/null || true)
      touched=$(git show --name-only --no-renames --format= "$sha" 2>/dev/null || true)
      msg=$(git log -1 --format=%B "$sha")
      label=$(git log -1 --format='%h %s' "$sha")
      frags=$(fragment_ids "$added" "$sha")
      check_message "$msg" "$label" "$frags" || rc=1
      check_scope "$msg" "$label" "$touched" \
        "$(git log -1 --format=%cd --date=format-utc:'%Y-%m-%dT%H:%M:%SZ' "$sha")" "$frags" || rc=1
    done
    exit $rc
    ;;
esac
