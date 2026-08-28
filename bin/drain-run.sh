#!/bin/sh
# One unattended fire: take eligible work, verify it, report it, push it for
# review. Invoked by launchd on the hour, or by `scripts/drain now`.
#
# The design goal is NOT "get work done overnight". It is "produce a diff worth
# reviewing in the morning, or produce nothing". Every guard below exists to
# make the second outcome cheap and the first trustworthy.
#
# GUARDS, in the order they fire. Each maps to a failure this repo has lived:
#   armed      the owner's switch (scripts/drain on|off)
#   branch     never commit onto whatever branch another workstream left checked
#              out — the shared-checkout hazard in CLAUDE.md
#   clean      a fire killed mid-issue by a quota ceiling leaves a dirty tree;
#              the NEXT fire refuses to start rather than building on top of it
#   quota      skip if a 429 was logged recently — the wall is still there
#   paths      diff the finished work against AUTO_UNSAFE_PATHS before pushing;
#              the tag says what we should not START, this says what we did
#
# EXIT CODES are the observable contract (status reads last-run.json, but a
# human running `drain now` reads these):
#   0 work landed        3 not on main       6 nothing eligible
#   1 internal error     4 tree not clean    7 timed out (see blockedOn)
#   2 disarmed           5 quota wall        8 touched a guarded path
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
state="${JANUS_DRAIN_HOME:-$HOME/.janus-unattended}"
flag="$state/armed"
runlog="$state/last-run.json"
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slug=$(date -u +%Y%m%d-%H%M%S)
out="$state/runs/$slug"
foreground=""
[ "$1" = "--foreground" ] && foreground=1

mkdir -p "$state/runs"

# Single-flight. Two fires in one tree is the exact thing every guard below is
# protecting against, and launchd will happily start a second while the first
# is still going if a run outlives its hour.
lock="$state/lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "drain: another fire is in progress ($lock) — exiting"
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM

finish() {  # outcome, exit code, detail
  cat > "$runlog" <<JSON
{
  "startedAt": "$stamp",
  "finishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "outcome": "$1",
  "exit": $2,
  "detail": "$3",
  "log": "$out"
}
JSON
  echo "drain: $1 ($3)"
  exit "$2"
}

# ---- guard: armed ---------------------------------------------------------
if [ -z "$foreground" ] && [ ! -f "$flag" ]; then
  # Not an error and not worth a log entry — a disarmed job is meant to fire
  # and do nothing. Writing last-run.json here would bury the real last run.
  echo "drain: disarmed, nothing to do"
  exit 2
fi

cd "$root"

# ---- guard: branch --------------------------------------------------------
branch=$(git branch --show-current 2>/dev/null || echo "")
if [ "$branch" != "main" ]; then
  finish "skipped" 3 "on branch '$branch', not main"
fi

# ---- guard: clean tree ----------------------------------------------------
if ! git diff --quiet || ! git diff --cached --quiet; then
  finish "skipped" 4 "working tree is dirty — triage the previous run first"
fi

# ---- guard: quota ---------------------------------------------------------
# A 429 inside the last hour means the window has not turned over. Cheaper to
# skip and let the next hourly fire find out than to burn a session discovering
# the same wall. See scripts/drain (last_429) for why the session logs are the
# only available source.
recent=$(python3 - <<'PY'
import glob, json, os, time
cut = time.time() - 3600
newest = None
for f in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(f) < cut:
            continue
        for line in open(f, errors="ignore"):
            if '"error":"rate_limit"' in line:
                try:
                    ts = json.loads(line).get("timestamp")
                except Exception:
                    continue
                if ts and (newest is None or ts > newest):
                    newest = ts
    except OSError:
        continue
print(newest or "")
PY
)
if [ -n "$recent" ] && [ -z "$foreground" ]; then
  finish "skipped" 5 "429 at $recent — window has not turned over"
fi

# ---- pick the work --------------------------------------------------------
# One fire is 12 points: S=3, M=4, L=6 — chosen so 4S, 3M and 2L are all
# exactly one fire, which is the owner's original rule kept as the definition.
# Mixing falls out of the same number. JANUS_DRAIN_BUDGET resizes a night.
# The rule lives in scripts/drain-pick.py, which has tests.
picked=$(python3 "$root/scripts/drain-pick.py" "$root" 2>>"$state/pick.err")
if [ -z "$picked" ]; then
  finish "idle" 6 "nothing eligible for an unattended run"
fi
count=$(echo "$picked" | wc -w | tr -d ' ')
echo "drain: taking $count issue(s): $picked"

# ---- run ------------------------------------------------------------------
# NO permission flags. The owner's ruling on UNATTENDED-OPS: "these sessions
# should have the same permissions as attended sessions." An unrecognised
# command therefore prompts, and with nobody there the session stalls — which
# is why the timeout below is not optional. A stall costs one window and leaves
# a specific line in the log to widen the allowlist by.
prompt=$(sed "s|__ISSUES__|$picked|g; s|__BRANCH__|auto/$slug|g" "$root/scripts/drain-prompt.md")

mkdir -p "$out"
claude -p "$prompt" --output-format json > "$out/session.json" 2> "$out/session.err" &
pid=$!
deadline=$(( $(date +%s) + 5400 ))   # 90 min; a fire should never outlive its window
while kill -0 "$pid" 2>/dev/null; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
    blocked=$(tail -c 2000 "$out/session.err" 2>/dev/null | tr '\n' ' ' | tr -d '"' | tail -c 300)
    finish "timeout" 7 "killed after 90m — tail: ${blocked:-nothing on stderr}"
  fi
  sleep 20
done

# ---- guard: paths ---------------------------------------------------------
# The enforced half of the autonomy rule. The tag on an issue says what we
# should not START; this says what we actually TOUCHED, which is the only one
# that survives an untagged issue turning out to be unsafe.
guarded=$(python3 - "$root" <<'PY'
import importlib.util, os, subprocess, sys
# AUTO_UNSAFE_PATHS is imported from issues.py, never copied here — one
# definition, so widening the guarded set cannot leave this script behind.
spec = importlib.util.spec_from_file_location(
    "iss", os.path.join(sys.argv[1], "planning-docs/feature-guidance/production-plan/issues.py"))
iss = importlib.util.module_from_spec(spec); spec.loader.exec_module(iss)
changed = subprocess.run(["git", "diff", "--name-only", "origin/main...HEAD"],
                         cwd=sys.argv[1], capture_output=True, text=True).stdout.split()
hits = [f for f in changed if any(f.startswith(p) or f == p for p in iss.AUTO_UNSAFE_PATHS)]
print(",".join(hits))
PY
)
if [ -n "$guarded" ]; then
  finish "quarantined" 8 "touched guarded path(s): $guarded — left uncommitted for review"
fi

# ---- hand it over for review ----------------------------------------------
# Pushed, never merged. The owner's ruling: "we should have review in place for
# this work to trust merging."
if git rev-parse --verify "auto/$slug" >/dev/null 2>&1; then
  git push -q -u origin "auto/$slug" 2>>"$out/session.err" || \
    finish "landed-unpushed" 0 "commits made, push failed — see $out/session.err"
  gh pr create --draft --fill --base main --head "auto/$slug" \
    >> "$out/session.err" 2>&1 || true
  finish "landed" 0 "$count issue(s) on auto/$slug, draft PR opened"
fi
finish "no-op" 0 "session ran but produced no branch — see $out/session.json"
