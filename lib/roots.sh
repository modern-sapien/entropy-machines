# roots.sh — resolve the ONE root every entry point needs. SOURCE it, do not
# run it.
#
#   . "$(dirname "$0")/../lib/roots.sh"
#   ENTROPY_HOME=$(entropy_home "$0")
#   entropy_require_root <tool-name>          # sets+exports ENTROPY_ROOT
#
# THERE IS ONE ROOT: THE GIT REPOSITORY.
#
# The harness is VENDORED AS PLAIN TRACKED FILES inside the project it works
# on and committed alongside the project's code — exactly as a `scripts/`
# directory is. There is no nested `.git`, so `git` from anywhere inside the
# project always answers with the project. entropy.json, .entropy/, the
# harness's own bin/ and lib/ are all inside one repository.
#
#   ENTROPY_ROOT   the repository's MAIN checkout. entropy.json and .entropy/
#                  live here. This is THE root.
#   ENTROPY_HOME   the directory the harness's own files sit in (bin/, lib/,
#                  hooks/, doctrine/). NOT a root and not a repo — just a path,
#                  derived from the calling script's own $0, so a script can
#                  find its sibling lib/ files whether the harness is vendored
#                  at the repo root or in a subdirectory. It is always inside
#                  ENTROPY_ROOT, or equal to it when the harness is its own
#                  project.
#
# WHAT USED TO BE HERE AND WHY IT IS GONE. This file used to resolve TWO
# roots, because the install layout was a NESTED GIT CLONE (`cd my-project &&
# git clone <harness> entropy-machines`). A nested repo shadows its parent for
# every git query, so "which repo am I in" had two answers depending on cwd.
# That one fact produced all of: a second root, drift detection
# (`entropy_harness_drift`), drift refusals in bin/init, gitignoring the
# harness directory, and a worktree-resolution stanza to tell the two apart.
# The vendored layout deletes the premise, so all of it is deleted. If you
# find yourself re-adding a "which repo is this really" check, the layout has
# regressed, not the code.
#
# ENTROPY_ROOT USES --git-common-dir, NOT --show-toplevel. THIS IS
# LOAD-BEARING. From inside a LINKED WORKTREE --show-toplevel prints the
# WORKTREE's own path. Tracker state lives under .entropy/, which is
# gitignored and therefore absent from every worktree — resolving it that way
# hands a dispatched worker an EMPTY tracker instead of the project's, which
# reads as "no issues" rather than as an error. --git-common-dir names the
# main checkout's .git from anywhere, including from inside a worktree, which
# is the question actually being asked. A previous bug here sent state to the
# wrong place; do not "simplify" this to --show-toplevel.

# entropy_home <path-to-calling-script>   — echoes the harness directory.
entropy_home() {
  CDPATH= cd -- "$(dirname -- "$1")/.." 2>/dev/null && pwd -P
}

# entropy_root   — echoes the repository's main checkout, or nothing (exit 1).
#
# No environment override. Nothing in this harness needs one any more: every
# caller either runs with a cwd inside the project (git answers), or is a git
# hook (git guarantees the cwd) or a scheduled unit that cd's into the harness
# directory first — which is inside the project. The old ENTROPY_PROJECT
# override existed to paper over the nested clone, and papering is exactly
# what made the wrong answer survivable.
entropy_root() {
  _er_common=$(git rev-parse --git-common-dir 2>/dev/null) || _er_common=""
  if [ -n "$_er_common" ]; then
    # --git-common-dir may print a path relative to the current directory.
    case "$_er_common" in
      /*) ;;
      *) _er_common="$PWD/$_er_common" ;;
    esac
    if _er_top=$(CDPATH= cd -- "$_er_common/.." 2>/dev/null && pwd -P); then
      printf '%s\n' "$_er_top"
      unset _er_common _er_top
      return 0
    fi
  fi

  # No git. Walk up for entropy.json so the harness still works in a plain
  # directory — the config loader's own tests do exactly this.
  _er_d=$PWD
  while [ -n "$_er_d" ] && [ "$_er_d" != "/" ]; do
    if [ -f "$_er_d/entropy.json" ]; then
      printf '%s\n' "$_er_d"
      unset _er_common _er_d
      return 0
    fi
    _er_d=$(dirname -- "$_er_d")
  done

  unset _er_common _er_d
  return 1
}

# entropy_require_root <tool-name>  — sets and exports ENTROPY_ROOT, or exits 2
# with a message that names the directory actually looked in.
#
# entropy.json is still the project's contract with the harness, and its
# absence is still a refusal: every other entry point would otherwise have to
# guess at paths, suite commands and protected paths it has not been told.
# bin/init is the one command that runs without it, because it is the thing
# that writes it.
entropy_require_root() {
  _err_tool=${1:-entropy}
  if ! ENTROPY_ROOT=$(entropy_root); then
    echo "$_err_tool: REFUSED — not inside a git repository, and no entropy.json" >&2
    echo "  found by walking up from $PWD." >&2
    echo "  cd into the project you are running the factory on." >&2
    unset _err_tool
    exit 2
  fi
  if [ ! -f "$ENTROPY_ROOT/entropy.json" ]; then
    echo "$_err_tool: REFUSED — no entropy.json at $ENTROPY_ROOT." >&2
    echo "  That is this project's contract with the harness: every path," >&2
    echo "  command and suite the harness would otherwise hardcode lives in" >&2
    echo "  it. See ${ENTROPY_HOME:-<harness>}/docs/CONFIG.md." >&2
    echo "  To create a starter one:  ${ENTROPY_HOME:-<harness>}/bin/init" >&2
    unset _err_tool
    exit 2
  fi
  export ENTROPY_ROOT
  unset _err_tool
}
