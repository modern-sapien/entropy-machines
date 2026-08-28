# roots.sh — resolve the two roots every entry point needs. SOURCE it, do not run it.
#
#   . "$(dirname "$0")/../lib/roots.sh"
#
# Sets and exports ENTROPY_HOME and ENTROPY_PROJECT.
#
# THERE ARE TWO ROOTS AND THEY ARE NOT THE SAME.
#
#   ENTROPY_HOME     where bin/, lib/, hooks/ and doctrine/ live — the harness
#                    itself. Resolved from the calling script's own path, so it
#                    is correct no matter where the harness is installed.
#   ENTROPY_PROJECT  the MAIN checkout of the repo being worked on — where
#                    entropy.json and .entropy/ live.
#
# They are equal only when the harness is vendored at the project root, which
# is the layout it was extracted from and the reason every entry point used to
# use one `dirname $0/..` for both. In any other layout — a sibling clone, a
# vendored subdirectory — that single value is right for lib/ and wrong for
# entropy.json, and the failure is silent: `bin/tracker` reads and writes issue
# state inside the HARNESS directory, so a project gets a permanently empty
# tracker and a harness checkout slowly fills up with someone else's issues.
#
# ENTROPY_PROJECT USES --git-common-dir, NOT --show-toplevel. From inside a
# linked worktree --show-toplevel prints the WORKTREE's own path. Tracker state
# lives under .entropy/, which is gitignored and therefore absent from every
# worktree — resolving it that way would hand a dispatched agent an empty
# tracker instead of the project's, which reads as "no issues" rather than as
# an error. --git-common-dir names the main checkout's .git from anywhere,
# including from inside a worktree, which is the question actually being asked.

# entropy_home <path-to-calling-script>   — echoes the harness root.
entropy_home() {
  CDPATH= cd -- "$(dirname -- "$1")/.." 2>/dev/null && pwd -P
}

# entropy_project   — echoes the project's main checkout root, or nothing.
#
# ENTROPY_PROJECT in the environment wins, so a caller that already knows (a
# hook, a test, a drain unit with no cwd to speak of) is never second-guessed.
entropy_project() {
  if [ -n "${ENTROPY_PROJECT:-}" ]; then
    printf '%s\n' "$ENTROPY_PROJECT"
    return 0
  fi

  _ep_common=$(git rev-parse --git-common-dir 2>/dev/null) || _ep_common=""
  if [ -n "$_ep_common" ]; then
    # --git-common-dir may print a path relative to the current directory.
    case "$_ep_common" in
      /*) ;;
      *) _ep_common="$PWD/$_ep_common" ;;
    esac
    if _ep_root=$(CDPATH= cd -- "$_ep_common/.." 2>/dev/null && pwd -P); then
      printf '%s\n' "$_ep_root"
      unset _ep_common _ep_root
      return 0
    fi
  fi

  # No git. Walk up for entropy.json so the harness still works in a plain
  # directory — the tests for the config loader do exactly this.
  _ep_d=$PWD
  while [ -n "$_ep_d" ] && [ "$_ep_d" != "/" ]; do
    if [ -f "$_ep_d/entropy.json" ]; then
      printf '%s\n' "$_ep_d"
      unset _ep_common _ep_d
      return 0
    fi
    _ep_d=$(dirname -- "$_ep_d")
  done

  unset _ep_common _ep_d
  return 1
}

# entropy_require_project <tool-name>  — sets ENTROPY_PROJECT or exits 2 with a
# message that names the directory actually looked in. The old refusal named
# the HARNESS directory, which sent anyone who hit it to create entropy.json in
# entirely the wrong repo.
entropy_require_project() {
  _erp_tool=${1:-entropy}
  if ! ENTROPY_PROJECT=$(entropy_project); then
    echo "$_erp_tool: REFUSED — not inside a git repository, and no entropy.json" >&2
    echo "  found by walking up from $PWD." >&2
    echo "  cd into the project you are running the factory on, or set" >&2
    echo "  ENTROPY_PROJECT to its root." >&2
    unset _erp_tool
    exit 2
  fi
  if [ ! -f "$ENTROPY_PROJECT/entropy.json" ]; then
    echo "$_erp_tool: REFUSED — no entropy.json at $ENTROPY_PROJECT." >&2
    echo "  That is this project's contract with the harness: every path," >&2
    echo "  command and suite the harness would otherwise hardcode lives in" >&2
    echo "  it. See $ENTROPY_HOME/docs/CONFIG.md." >&2
    echo "  To create a starter one:  $ENTROPY_HOME/bin/init" >&2
    unset _erp_tool
    exit 2
  fi
  export ENTROPY_PROJECT
  unset _erp_tool
}
