#!/usr/bin/env bash
# changelog-guard — a commit that touches a watched path must add a fragment
# under `changelog.fragmentDir`. What counts as "watched" is entropy.json's
# `changelog.watchedPathPatterns`; the default is `["**"]`, i.e. every path,
# until a project narrows it.
#
# One implementation, two callers, so the local hook and CI cannot drift:
#
#   lib/changelog-guard.sh --staged            # pre-commit: the index
#   lib/changelog-guard.sh --range A..B         # CI: every non-merge commit
#   lib/changelog-guard.sh --commit <sha>       # one commit
#
# A rule enforced only by a hook is enforced by nothing: hooks live in
# .git/ and are not version-controlled, so anyone who never runs the hook
# installer has no hook at all. That is the general shape of a setting that
# is silently ignored rather than refused — this repo's own hook installer
# (lib/install-hooks.sh) verifies its own install for exactly that reason.
# CI is the gate that actually lives in the repo; the hook is the fast local
# echo of it.
#
# Escape hatch, for a genuinely entry-free commit (a revert, a mechanical
# rename). It takes two forms because the two callers see different things:
# pre-commit has no commit message yet, and CI has nothing but the message.
#
#   SKIP_CHANGELOG=1 git commit -m "chore: rename only [skip changelog]"
#
# The env var satisfies the hook; the `[skip changelog]` marker is what
# survives into history and satisfies CI. Use both, or the commit passes
# locally and fails on push.
#
# `git commit --no-verify` is NOT an escape hatch. It skips the hook and
# leaves nothing behind, so CI fails and there is no record of the intent.
#
# The whole feature is optional: `changelog.enabled: false` in entropy.json
# turns this script into a no-op. A consuming project may not want a
# fragment-per-commit changelog at all.

set -euo pipefail

# TWO ROOTS. config.py ships with the HARNESS; entropy.json lives in the
# PROJECT. They are the same directory only when the harness is vendored at the
# project root, and this line used to assume that — in a drop-in install the
# hook fired and then died on a missing lib/config.py, which reads as a broken
# repo rather than a misinstalled harness. The shim installed by
# lib/install-hooks.sh exports both; the fallbacks are for direct invocation.
if [ -z "${ENTROPY_HOME:-}" ]; then
  ENTROPY_HOME="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
fi
ROOT="${ENTROPY_PROJECT:-$(git rev-parse --show-toplevel)}"
CONFIG_PY="$ENTROPY_HOME/lib/config.py"

ENABLED="$(python3 "$CONFIG_PY" get changelog.enabled)"
if [ "$ENABLED" != "true" ]; then
  echo "changelog-guard: changelog.enabled is false in entropy.json — skipped."
  exit 0
fi

FRAGMENT_DIR="$(python3 "$CONFIG_PY" get changelog.fragmentDir)"
NEW_FRAGMENT_CMD="$(python3 "$CONFIG_PY" get changelog.newFragmentCmd)"
WATCHED_RE="$(python3 "$CONFIG_PY" glob-re changelog.watchedPathPatterns)"
FRAGMENT_RE="$(python3 "$CONFIG_PY" changelog-fragment-re)"
SKIP_MARKER='[skip changelog]'

fail() {
  cat >&2 <<EOF
changelog-guard: $1 touches a watched path (entropy.json changelog.watchedPathPatterns) but adds no fragment under ${FRAGMENT_DIR}/.

  ${NEW_FRAGMENT_CMD} "type(scope): what changed" [issue-id]

then fill in the body and stage it. One fragment per commit — that is the
whole point: your fragment is a file nobody else writes, so it cannot
conflict with another agent's.

Genuinely no entry needed?
  SKIP_CHANGELOG=1 git commit -m "... ${SKIP_MARKER}"
Both parts matter: the env var clears the hook, the marker clears CI.
EOF
  exit 1
}

if [ "${SKIP_CHANGELOG:-}" = "1" ]; then
  echo "changelog-guard: SKIP_CHANGELOG=1 — skipped."
  echo "changelog-guard: put '${SKIP_MARKER}' in the commit message too, or CI will fail this commit."
  exit 0
fi

# A commit whose message carries the marker is exempt in CI, the same way the
# env var exempts it locally.
skipped_by_message() {
  git log -1 --format='%B' "$1" | grep -qF "$SKIP_MARKER"
}

check_lists() {
  # $1 = all changed paths, $2 = added paths
  local changed="$1" added="$2" label="$3"
  if ! printf '%s\n' "$changed" | grep -Eq "$WATCHED_RE"; then
    return 0
  fi
  if printf '%s\n' "$added" | grep -Eq "$FRAGMENT_RE"; then
    return 0
  fi
  fail "$label"
}

MODE="${1:---staged}"

case "$MODE" in
  --staged)
    changed=$(git diff --cached --name-only --diff-filter=ACMRD)
    added=$(git diff --cached --name-only --diff-filter=A)
    check_lists "$changed" "$added" "the staged change"
    echo "changelog-guard: staged change OK."
    ;;

  --commit)
    sha="${2:?--commit needs a sha}"
    if skipped_by_message "$sha"; then
      echo "changelog-guard: $(git log -1 --format='%h %s' "$sha") — ${SKIP_MARKER}, skipped."
      exit 0
    fi
    changed=$(git show --pretty=format: --name-only --diff-filter=ACMRD "$sha")
    added=$(git show --pretty=format: --name-only --diff-filter=A "$sha")
    check_lists "$changed" "$added" "commit $(git log -1 --format='%h %s' "$sha")"
    echo "changelog-guard: $(git log -1 --format='%h %s' "$sha") OK."
    ;;

  --range)
    range="${2:?--range needs A..B}"
    # Merge commits are skipped: their content already passed on the branch.
    commits=$(git rev-list --no-merges --reverse "$range")
    if [ -z "$commits" ]; then
      echo "changelog-guard: no non-merge commits in $range."
      exit 0
    fi
    n=0
    for sha in $commits; do
      if skipped_by_message "$sha"; then
        echo "changelog-guard: $(git log -1 --format='%h %s' "$sha") — ${SKIP_MARKER}, skipped."
        n=$((n + 1))
        continue
      fi
      changed=$(git show --pretty=format: --name-only --diff-filter=ACMRD "$sha")
      added=$(git show --pretty=format: --name-only --diff-filter=A "$sha")
      check_lists "$changed" "$added" "commit $(git log -1 --format='%h %s' "$sha")"
      n=$((n + 1))
    done
    echo "changelog-guard: $n commit(s) in $range OK."
    ;;

  *)
    echo "usage: changelog-guard.sh [--staged | --commit <sha> | --range A..B]" >&2
    exit 2
    ;;
esac
