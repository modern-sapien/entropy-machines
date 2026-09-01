#!/bin/sh
# One unattended fire: take eligible work, verify it, report it, push it for
# review. Invoked by the scheduled job on the hour, or by `bin/drain now`, or
# by `bin/drain at HH:MM`.
#
# Also answers `bin/drain-run.sh --probe-quota` — see QUOTA PROBE below. That
# is not a separate script; it is the same function bin/drain's `status` calls
# out to, so there is exactly one implementation instead of two that drift.
#
# The design goal is NOT "get work done overnight". It is "produce a diff worth
# reviewing in the morning, or produce nothing". Every guard below exists to
# make the second outcome cheap and the first trustworthy.
#
# GUARDS, in the order they fire. Each maps to a failure this kind of unattended
# job can produce if left unchecked:
#   armed      the operator's switch (bin/drain on|off)
#   branch     never commit onto whatever branch another workstream left
#              checked out — the shared-checkout hazard (see doctrine/WORKFLOW.md,
#              "the clean tree is the truth")
#   clean      a fire killed mid-issue by a quota ceiling leaves a dirty tree;
#              the NEXT fire refuses to start rather than building on top of it
#   quota      skip if the quota probe recently saw a wall — see QUOTA PROBE
#   paths      diff the finished work against config.json's protected paths
#              before pushing; the tracker's own tags say what we should not
#              START, this says what we actually TOUCHED
#
# EXIT CODES are the observable contract (status reads last-run.json, but a
# human running `drain now` reads these):
#   0 work landed        3 not on the expected branch   6 nothing eligible
#   1 internal error     4 tree not clean                7 timed out (see blockedOn)
#   2 disarmed           5 quota wall                    8 touched a protected path
set -e

# ONE ROOT, TWO PATHS — see lib/roots.sh. ENTROPY_MACHINES_HOME is the harness
# DIRECTORY (this script's own bin/, and the lib/ beside it); $root is the
# repository this works on. They are the same tree — the harness is vendored
# inside the project — but not necessarily the same directory.
#
# THE cd COMES FIRST AND IS LOAD-BEARING. A launchd/systemd unit fires with cwd
# at `/`, so git has nothing to answer from. Stepping into the harness
# directory — which is inside the repo — gives it one. This is what replaced
# the old "an installed job only works when the harness sits at the project
# root" gap: nothing has to carry the root in.
. "$(dirname "$0")/../lib/roots.sh"
ENTROPY_MACHINES_HOME=$(entropy_machines_home "$0")
cd "$ENTROPY_MACHINES_HOME"
# The nested-clone refusal still applies and must be asked for explicitly,
# because this script deliberately skips entropy_machines_require_root (below).
entropy_machines_refuse_nested_clone drain-run

# entropy_machines_root, not entropy_machines_require_root: the "no config.json" refusal exits
# 2, and 2 is already this script's documented "disarmed" code (see EXIT CODES
# above). A misconfigured repo is an internal error (1), not a disarmed one,
# and cfg() below already defaults every key it reads.
if ! root=$(entropy_machines_root); then
  echo "drain-run: could not resolve the repository from $ENTROPY_MACHINES_HOME." >&2
  exit 1
fi

# ---- config -------------------------------------------------------------
# Same cfg() as bin/drain. Kept as a second copy rather than a shared sourced
# file: these are the only two callers, both tiny, and a sourced helper would
# be a third file to keep in sync with the config.json shape for a five-line
# function. If a third caller shows up, that calculus changes.
cfg() {
  python3 - "$root/config.json" "$1" "$2" <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print(default); sys.exit(0)
cur = data
# TOLERATE A LEADING DOT. Every call site in this file and in bin/drain writes
# the key as '.unattended.x' (a jq habit), which split('.') turns into a first
# segment of '' that matches no dict key — so this helper silently returned its
# DEFAULT for every lookup, and no unattended setting in config.json had any
# effect. Fixed here rather than at a dozen call sites so both spellings work.
for part in key.lstrip('.').split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default); sys.exit(0)
print(default if cur is None else (cur if isinstance(cur, str) else json.dumps(cur)))
PY
}

# ---- QUOTA PROBE ----------------------------------------------------------
# Whether the configured coding-agent CLI recently hit a rate/quota wall, so a
# fire that would only hit the same wall again can be skipped cheaply instead
# of burning a session discovering it. This is OPTIONAL and OFF by default:
# there is no universal way to ask an arbitrary agent CLI "are you rate
# limited right now", so absent a configured probe this must not skip fires —
# skipping without evidence is a worse failure mode than occasionally hitting
# a wall the hard way.
#
# The one probe type implemented here, "log-glob", is a real but fragile
# technique: it globs a directory of the agent CLI's own session logs for a
# literal error-marker substring and reads a timestamp field off the JSON line
# that contains it. It ASSUMES:
#   - the CLI writes one JSON object per line (JSONL) to files under logGlob
#   - a rate-limit response is logged as a line containing errorMarker verbatim
#   - that line is valid JSON with a "timestamp" field in a sortable string form
#   - file mtimes are a reasonable proxy for "was this session active recently"
# Every one of those is an implementation detail of whatever agent CLI you
# point it at, not a stable interface, and can silently stop matching the
# moment that CLI changes its log format. Configure it under
# unattended.agent.quotaProbe in config.json:
#
#   "quotaProbe": {
#     "type": "log-glob",
#     "logGlob": "~/.claude/projects/**/*.jsonl",
#     "errorMarker": "\"error\":\"rate_limit\"",
#     "lookbackSeconds": 3600
#   }
#
# Leave quotaProbe unset (or type "none") to run with no quota awareness at
# all — every fire attempts the work and simply fails/times out if the agent
# CLI itself refuses.
probe_quota() {
  ptype=$(cfg '.unattended.agent.quotaProbe.type' 'none')
  case "$ptype" in
    none|"") return 0 ;;   # no probe configured — print nothing, never skip
  esac
  glob=$(cfg '.unattended.agent.quotaProbe.logGlob' '')
  marker=$(cfg '.unattended.agent.quotaProbe.errorMarker' '')
  lookback=$(cfg '.unattended.agent.quotaProbe.lookbackSeconds' '3600')
  if [ -z "$glob" ] || [ -z "$marker" ]; then
    return 0   # misconfigured probe — same as no probe, never skip
  fi
  python3 - "$glob" "$marker" "$lookback" <<'PY' 2>/dev/null || true
import glob as globmod, json, os, sys, time
pattern, marker, lookback = sys.argv[1], sys.argv[2], float(sys.argv[3])
cut = time.time() - lookback
newest = None
for f in globmod.glob(os.path.expanduser(pattern), recursive=True):
    try:
        if os.path.getmtime(f) < cut:
            continue
        for line in open(f, errors="ignore"):
            if marker in line:
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
}

if [ "$1" = "--probe-quota" ]; then
  probe_quota
  exit 0
fi

state_default=$(cfg '.unattended.stateHome' '~/.entropy-machines')
case "$state_default" in
  "~"*) state_default="$HOME${state_default#\~}" ;;
esac
state="${ENTROPY_DRAIN_HOME:-$state_default}"
flag="$state/armed"
runlog="$state/last-run.json"
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slug=$(date -u +%Y%m%d-%H%M%S)
out="$state/runs/$slug"
foreground=""
[ "$1" = "--foreground" ] && foreground=1

want_branch=$(cfg '.unattended.branch' 'main')
remote=$(cfg '.unattended.remote' 'origin')
branch_prefix=$(cfg '.unattended.branchPrefix' 'auto/')
forge_cli=$(cfg '.unattended.forgeCli' 'gh')
timeout_s=$(cfg '.unattended.sessionTimeoutSeconds' '5400')

mkdir -p "$state/runs"

# Single-flight. Two fires in one tree is the exact thing every guard below is
# protecting against, and the scheduler will happily start a second while the
# first is still going if a run outlives its hour.
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
if [ "$branch" != "$want_branch" ]; then
  finish "skipped" 3 "on branch '$branch', not '$want_branch'"
fi

# ---- guard: clean tree ----------------------------------------------------
if ! git diff --quiet || ! git diff --cached --quiet; then
  finish "skipped" 4 "working tree is dirty — triage the previous run first"
fi

# ---- guard: quota ---------------------------------------------------------
recent=$(probe_quota)
if [ -n "$recent" ] && [ -z "$foreground" ]; then
  finish "skipped" 5 "quota probe saw a wall at $recent — window has not turned over"
fi

# ---- pick the work --------------------------------------------------------
# The cost model and budget live in config.json (unattended.sizeCosts,
# unattended.budget) and are applied by bin/drain-pick.py, which has tests.
# THE rc IS CAPTURED, NOT SWALLOWED. Under `set -e` a bare
# `picked=$(...)` assignment kills this script the moment drain-pick exits
# non-zero -- so a picker that could not reach the tracker took the whole run
# down BEFORE the idle handler below, leaving no last-run.json, the real error
# buried in pick.err, and `bin/drain status` still reporting "last fire:
# never". Silent because the two outcomes look identical from outside: an
# empty $picked means "nothing eligible", which is a normal idle tick, while a
# non-zero rc means the picker itself failed and somebody has to be told.
pick_rc=0
picked=$(python3 "$ENTROPY_MACHINES_HOME/bin/drain-pick.py" "$root" 2>>"$state/pick.err") || pick_rc=$?
if [ "$pick_rc" -ne 0 ]; then
  finish "error" 7 "drain-pick failed (rc $pick_rc) — see $state/pick.err"
fi
if [ -z "$picked" ]; then
  finish "idle" 6 "nothing eligible for an unattended run"
fi
count=$(echo "$picked" | wc -w | tr -d ' ')
echo "drain: taking $count issue(s): $picked"

# ---- run ------------------------------------------------------------------
# NO permission flags. An unattended session gets exactly the same permissions
# an attended one would — an unrecognised command therefore prompts, and with
# nobody there to answer, the session stalls. That is why the timeout below is
# not optional: a stall costs one window and leaves a specific line in the log
# to widen the allowlist by, rather than hanging until the scheduler kills it.
prompt=$(sed "s|__ISSUES__|$picked|g; s|__BRANCH__|${branch_prefix}${slug}|g" "$ENTROPY_MACHINES_HOME/bin/drain-prompt.md")

# Agent invocation is pluggable: unattended.agent.cmd is the argv prefix
# (default ["claude", "-p"]) and the prompt is appended as the final argument.
# Building it as newline-separated tokens rather than a JSON array kept in one
# shell variable is deliberate — POSIX sh has no arrays, and this is the
# smallest portable way to rebuild an argv from a list of strings.
mkdir -p "$out"
set --
while IFS= read -r tok; do
  [ -n "$tok" ] && set -- "$@" "$tok"
done <<AGENTCMD
$(python3 - "$root/config.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    cmd = data.get("unattended", {}).get("agent", {}).get("cmd") or ["claude", "-p"]
except Exception:
    cmd = ["claude", "-p"]
for tok in cmd:
    print(tok)
PY
)
AGENTCMD
"$@" "$prompt" > "$out/session.json" 2> "$out/session.err" &
pid=$!
deadline=$(( $(date +%s) + timeout_s ))
while kill -0 "$pid" 2>/dev/null; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
    blocked=$(tail -c 2000 "$out/session.err" 2>/dev/null | tr '\n' ' ' | tr -d '"' | tail -c 300)
    finish "timeout" 7 "killed after $((timeout_s / 60))m — tail: ${blocked:-nothing on stderr}"
  fi
  sleep 20
done

# ---- guard: paths ---------------------------------------------------------
# The enforced half of the autonomy rule. The tracker's own tags say what an
# issue should not START on; this says what the session actually TOUCHED,
# which is the only one that survives an untagged issue turning out unsafe.
# protectedPaths is a plain list of path prefixes in config.json
# (project.protectedPaths) — not a project-specific Python module, so widening
# or narrowing the guarded set is a one-line config edit.
guarded=$(python3 - "$root" "$remote" "$want_branch" <<'PY'
import json, os, subprocess, sys
root, remote, branch = sys.argv[1], sys.argv[2], sys.argv[3]
protected = []
try:
    with open(os.path.join(root, "config.json")) as f:
        protected = json.load(f).get("project", {}).get("protectedPaths", []) or []
except Exception:
    protected = []
if not protected:
    print("")
    sys.exit(0)
changed = subprocess.run(
    ["git", "diff", "--name-only", f"{remote}/{branch}...HEAD"],
    cwd=root, capture_output=True, text=True).stdout.split()
hits = [f for f in changed if any(f.startswith(p) or f == p for p in protected)]
print(",".join(hits))
PY
)
if [ -n "$guarded" ]; then
  finish "quarantined" 8 "touched protected path(s): $guarded — left uncommitted for review"
fi

# ---- hand it over for review ----------------------------------------------
# Pushed, never merged. An unattended run earns no more trust than a human PR
# does — review happens on it like any other change.
branch_name="${branch_prefix}${slug}"
if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
  git push -q -u "$remote" "$branch_name" 2>>"$out/session.err" || \
    finish "landed-unpushed" 0 "commits made, push failed — see $out/session.err"
  if [ -n "$forge_cli" ] && command -v "$forge_cli" >/dev/null 2>&1; then
    "$forge_cli" pr create --draft --fill --base "$want_branch" --head "$branch_name" \
      >> "$out/session.err" 2>&1 || true
  fi
  finish "landed" 0 "$count issue(s) on $branch_name, pushed for review"
fi
finish "no-op" 0 "session ran but produced no branch — see $out/session.json"
