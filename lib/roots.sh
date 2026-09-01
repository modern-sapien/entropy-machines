# roots.sh — resolve the ONE root every entry point needs. SOURCE it, do not
# run it.
#
#   . "$(dirname "$0")/../lib/roots.sh"
#   ENTROPY_MACHINES_HOME=$(entropy_machines_home "$0")
#   entropy_machines_require_root <tool-name>          # sets+exports ENTROPY_MACHINES_ROOT,
#                                             # refusing a nested clone first
#
# THERE IS ONE ROOT: THE GIT REPOSITORY.
#
# The harness is VENDORED AS PLAIN TRACKED FILES inside the project it works
# on and committed alongside the project's code — exactly as a `scripts/`
# directory is. There is no nested `.git`, so `git` from anywhere inside the
# project always answers with the project. config.json, .entropy-machines/, the
# harness's own bin/ and lib/ are all inside one repository.
#
#   ENTROPY_MACHINES_ROOT   the repository's MAIN checkout. .entropy-machines/
#                  lives here. This is THE root.
#   ENTROPY_MACHINES_HOME   the directory the harness's own files sit in (bin/, lib/,
#                  hooks/, doctrine/, config.json). NOT a root and not a repo —
#                  just a path, derived from the calling script's own $0, so a
#                  script can find its sibling lib/ files whether the harness is
#                  vendored at the repo root or in a subdirectory. It is always
#                  inside ENTROPY_MACHINES_ROOT, or equal to it when the harness
#                  is its own project.
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
# THE NESTED CLONE IS REFUSED, NOT RESOLVED. Deleting the two-root machinery
# removed the harness's ability to COPE with a nested clone; it did not stop
# anyone creating one (`cd my-project && git clone <harness> tools/` is the
# instinct, and is what the README said to do until recently). A nested repo
# shadows its parent for every git query, so every command run from inside it
# resolves to the HARNESS as the project: the tracker writes .entropy-machines/ into
# the harness, dispatch and handoff operate on the wrong repo, and nothing
# says a word. Three agents in a sibling project were lost to exactly that on
# 2026-08-17. entropy_machines_refuse_nested_clone() says so and exits. It is a
# REFUSAL, not a resolution scheme — if it ever grows a way to keep working
# in that layout, the expensive mistake has been re-made.
#
# ENTROPY_MACHINES_ROOT USES --git-common-dir, NOT --show-toplevel. THIS IS
# LOAD-BEARING. From inside a LINKED WORKTREE --show-toplevel prints the
# WORKTREE's own path. Tracker state lives under .entropy-machines/, which is
# gitignored and therefore absent from every worktree — resolving it that way
# hands a dispatched worker an EMPTY tracker instead of the project's, which
# reads as "no issues" rather than as an error. --git-common-dir names the
# main checkout's .git from anywhere, including from inside a worktree, which
# is the question actually being asked. A previous bug here sent state to the
# wrong place; do not "simplify" this to --show-toplevel.

# entropy_machines_home <path-to-calling-script>   — echoes the harness directory.
entropy_machines_home() {
  CDPATH= cd -- "$(dirname -- "$1")/.." 2>/dev/null && pwd -P
}

# entropy_machines_git_root [dir]  — echoes the main checkout of the git repository
# containing <dir> (default: the current directory), or nothing (exit 1).
#
# GIT ONLY: no config.json walk-up. entropy_machines_root() adds that fallback; the
# nested-clone check must not have it, because it asks specifically "WHICH GIT
# REPOSITORY owns this directory" and a walk-up would answer a different
# question with a path that looks like an answer.
entropy_machines_git_root() {
  _egr_dir=${1:-}
  if [ -n "$_egr_dir" ]; then
    _egr_common=$(CDPATH= cd -- "$_egr_dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || _egr_common=""
  else
    # No argument: run git in the AMBIENT cwd rather than cd-ing to "$PWD",
    # so entropy_machines_root() below keeps the exact behaviour it had before this
    # helper was extracted out of it.
    _egr_dir=$PWD
    _egr_common=$(git rev-parse --git-common-dir 2>/dev/null) || _egr_common=""
  fi
  if [ -n "$_egr_common" ]; then
    # --git-common-dir may print a path relative to the directory git ran in.
    case "$_egr_common" in
      /*) ;;
      *) _egr_common="$_egr_dir/$_egr_common" ;;
    esac
    if _egr_top=$(CDPATH= cd -- "$_egr_common/.." 2>/dev/null && pwd -P); then
      printf '%s\n' "$_egr_top"
      unset _egr_dir _egr_common _egr_top
      return 0
    fi
  fi
  unset _egr_dir _egr_common
  return 1
}

# entropy_machines_root   — echoes the repository's main checkout, or nothing (exit 1).
#
# No environment override. Nothing in this harness needs one any more: every
# caller either runs with a cwd inside the project (git answers), or is a git
# hook (git guarantees the cwd) or a scheduled unit that cd's into the harness
# directory first — which is inside the project. The old ENTROPY_PROJECT
# override existed to paper over the nested clone, and papering is exactly
# what made the wrong answer survivable.
entropy_machines_root() {
  if _er_top=$(entropy_machines_git_root); then
    printf '%s\n' "$_er_top"
    unset _er_top
    return 0
  fi

  # No git. Walk up for config.json so the harness still works in a plain
  # directory — the config loader's own tests do exactly this.
  _er_d=$PWD
  while [ -n "$_er_d" ] && [ "$_er_d" != "/" ]; do
    if [ -f "$_er_d/config.json" ]; then
      printf '%s\n' "$_er_d"
      unset _er_d
      return 0
    fi
    _er_d=$(dirname -- "$_er_d")
  done

  unset _er_d
  return 1
}

# entropy_machines_refuse_nested_clone <tool-name>  — exits 2 if the harness is a
# NESTED GIT REPOSITORY inside the project. A REFUSAL, not a resolution: it
# never tries to make that layout work (see the header).
#
# The harness is vendored — plain files committed into the project — so
# $ENTROPY_MACHINES_HOME/.git normally does not exist at all and this returns
# immediately. When it DOES exist there is exactly one innocent explanation:
# the harness IS the project, either developed standalone or vendored at the
# repo root. That still holds from inside a linked worktree, where the .git
# is a FILE pointing at the main checkout.
#
# So: nested iff a DIFFERENT repository encloses the harness's parent
# directory than the one that owns the harness directory itself. Deliberately
# phrased without ENTROPY_MACHINES_ROOT, which is resolved from the CWD and is
# therefore the shadowed, wrong answer in the very case being detected.
entropy_machines_refuse_nested_clone() {
  _rnc_tool=${1:-entropy-machines}
  _rnc_home=${ENTROPY_MACHINES_HOME:-}
  if [ -z "$_rnc_home" ] || [ ! -e "$_rnc_home/.git" ]; then
    unset _rnc_tool _rnc_home
    return 0
  fi

  _rnc_owner=$(entropy_machines_git_root "$_rnc_home") || _rnc_owner=""
  _rnc_outer=$(entropy_machines_git_root "$_rnc_home/..") || _rnc_outer=""

  if [ -z "$_rnc_outer" ] || [ "$_rnc_outer" = "$_rnc_owner" ]; then
    unset _rnc_tool _rnc_home _rnc_owner _rnc_outer
    return 0
  fi

  echo "$_rnc_tool: REFUSED — the harness is a nested git repository." >&2
  echo "  $_rnc_home has its own .git, and it sits inside another" >&2
  echo "  repository ($_rnc_outer)." >&2
  echo "" >&2
  echo "  A nested repo shadows its parent for every git query, so every" >&2
  echo "  command run from inside it resolves to the HARNESS as the project:" >&2
  echo "  the tracker writes .entropy-machines/ into the harness, and dispatch and" >&2
  echo "  handoff operate on the wrong repository. Nothing has been written." >&2
  echo "" >&2
  echo "  This harness is VENDORED, not cloned — plain files committed into" >&2
  echo "  the project alongside its code, exactly as a scripts/ directory is." >&2
  echo "  Fix it either way:" >&2
  echo "    rm -rf $_rnc_home/.git" >&2
  echo "    git -C $_rnc_outer add $_rnc_home && git -C $_rnc_outer commit" >&2
  echo "  or re-vendor: delete $_rnc_home and copy the harness's files in" >&2
  echo "  (no .git), then commit them into $_rnc_outer." >&2
  unset _rnc_tool _rnc_home _rnc_owner _rnc_outer
  exit 2
}

# entropy_machines_require_root <tool-name>  — sets and exports ENTROPY_MACHINES_ROOT, or exits 2
# with a message that names the directory actually looked in.
#
# config.json is still the project's contract with the harness, and its
# absence is still a refusal: every other entry point would otherwise have to
# guess at paths, suite commands and protected paths it has not been told.
# bin/init is the one command that runs without it, because it is the thing
# that writes it.
entropy_machines_require_root() {
  _err_tool=${1:-entropy-machines}
  # Before anything is resolved: in a nested clone every answer below is the
  # harness's, not the project's, and they all look plausible.
  entropy_machines_refuse_nested_clone "$_err_tool"
  if ! ENTROPY_MACHINES_ROOT=$(entropy_machines_root); then
    echo "$_err_tool: REFUSED — not inside a git repository, and no config.json" >&2
    echo "  found by walking up from $PWD." >&2
    echo "  cd into the project you are running the factory on." >&2
    unset _err_tool
    exit 2
  fi
  if [ ! -f "${ENTROPY_MACHINES_HOME:-$ENTROPY_MACHINES_ROOT}/config.json" ]; then
    echo "$_err_tool: REFUSED — no config.json at ${ENTROPY_MACHINES_HOME:-$ENTROPY_MACHINES_ROOT}." >&2
    echo "  That is this project's contract with the harness: every path," >&2
    echo "  command and suite the harness would otherwise hardcode lives in" >&2
    echo "  it. See ${ENTROPY_MACHINES_HOME:-<harness>}/docs/CONFIG.md." >&2
    echo "  To create a starter one:  ${ENTROPY_MACHINES_HOME:-<harness>}/bin/init" >&2
    unset _err_tool
    exit 2
  fi
  export ENTROPY_MACHINES_ROOT
  unset _err_tool
}
