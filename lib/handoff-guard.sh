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

# Empty unless the project opts in — see the grandfathering note above.
CUTOFF="$(
  cd "$(git rev-parse --show-toplevel)" 2>/dev/null &&
  python3 "${ENTROPY_HOME:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}/lib/config.py" get guards.handoffCutoff 2>/dev/null | tr -d '"' || true
)"
# `if`, not `[ ... ] && ...` — under `set -e` a failing test as the last
# command of a compound exits the script, which would make this gate pass
# everything in silence. That is the exact failure this file exists to prevent.
if [ "$CUTOFF" = "null" ]; then CUTOFF=""; fi
SKIP_MARKER='[skip handoff]'

# See lib/changelog-guard.sh for why these are two separate roots. NOTE the
# cutoff block ABOVE runs before this assignment, so it derives ENTROPY_HOME
# itself rather than referencing $ROOT — referencing it there was an unbound
# variable under `set -u`, i.e. a crash in the gate rather than a refusal.
if [ -z "${ENTROPY_HOME:-}" ]; then
  ENTROPY_HOME="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
fi
ROOT="${ENTROPY_PROJECT:-$(git rev-parse --show-toplevel)}"
# HANDOFF_MEMORY is a TEST SEAM, not a bypass — tests/core/commit-gate-open-
# dispatch.test.ts points it at a fixture so it can exercise the refuse path
# without writing fake DISPATCH notes into the log two other sessions are
# reading. SKIP_HANDOFF is the supported escape hatch; do not set this one in
# CI. (Until 2026-08-27 this comment said "the self-test below", and there was
# no self-test below and never had been.)
# Where the note log lives is the tracker backend's business, so ask it rather
# than hardcoding a path. Falls back to the built-in backend's default.
MEMORY="${HANDOFF_MEMORY:-$ROOT/$(
  cd "$ROOT" 2>/dev/null &&
  python3 "$ENTROPY_HOME/lib/config.py" get tracker.file.path 2>/dev/null | tr -d '"' || true
)}"

# The tracker's store may be a NESTED REPO, absent from dispatched agents'
# worktrees. No memory file means no way to know what was dispatched, so the
# guard has nothing to say — it must pass rather than block a commit it cannot
# reason about.
[ -f "$MEMORY" ] || exit 0

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
    elif [ -f "$ROOT/$f" ]; then
      body=$(cat "$ROOT/$f")
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

dispatched = handed = None
with open(mem, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        text, ts = e.get("text", ""), e.get("ts", "")
        # Match on the note body, not the issue key: --issue is optional on
        # `remember`, and a note filed without it still records the dispatch.
        if text.startswith(f"DISPATCH {iid} "):
            dispatched = ts
        elif text.startswith(f"HANDOFF {iid} "):
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
label = os.environ["LABEL"]
try:
    hours = float(os.environ.get("CLAIM_HOURS") or 24)
except ValueError:
    hours = 24.0
try:
    now = datetime.datetime.strptime(os.environ["WHEN"], "%Y-%m-%dT%H:%M:%S")
except ValueError:
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

events = []
with open(os.environ["MEMORY"], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        m = VERB.match(e.get("text", ""))
        if not m:
            continue
        try:
            ts = datetime.datetime.strptime(e.get("ts", ""), "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            continue
        if ts > now:
            continue        # not yet true when this commit was made
        events.append((ts, m, e["text"]))
events.sort(key=lambda r: r[0])

live = {}
for ts, m, text in events:
    iid = m.group(2)
    if m.group(1) == "HANDOFF":
        live.pop(iid, None)
        continue
    # Searched from the END OF THE ID GROUP: VERB already consumed the first em
    # dash. Bounded by `— brief:` so the denylist field, which is also a path
    # list and sits after the brief, can never be read as scope.
    scope = re.search(r"—\s+scope:\s*(.*?)\s+—\s+brief:", text[m.end(2):])
    if not scope:
        continue
    live[iid] = (ts, scope.group(1).strip())

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
    check_scope "$msg" "this commit" "$touched" "$(date '+%Y-%m-%dT%H:%M:%S')" "$frags"
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
    # format-LOCAL, and the difference is not cosmetic. `%cd --date=format:`
    # renders in the timezone RECORDED IN THE COMMIT, which for a commit made
    # elsewhere (or with GIT_COMMITTER_DATE given as ...Z) is not this machine's.
    # Note-log timestamps are local and naive — `date '+%Y-%m-%dT%H:%M:%S'`
    # via bin/tracker — so comparing the two demands both be local. Caught by
    # the backdated-commit test, which was three hours in the FUTURE.
    check_scope "$msg" "$label" "$touched" \
      "$(git log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%S' "$arg")" "$frags"
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
        "$(git log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%S' "$sha")" "$frags" || rc=1
    done
    exit $rc
    ;;
esac
