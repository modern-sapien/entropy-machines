# harness.sh — helpers every case file sources. POSIX sh; no framework.
#
#   . "$TEST_LIB/harness.sh"
#
# The runner (tests/run) exports what this needs:
#   ENTROPY_SRC   the harness checkout under test (tests/run's parent, or an
#                 override — that override is what lets you point the whole
#                 suite at a deliberately-broken COPY, see tests/README.md)
#   TEST_TMP      a scratch directory belonging to this case alone
#   TEST_NAME     the case's name, for messages
#
# WHAT A CASE LOOKS LIKE. Build a throwaway git repo with fixture_new, drive a
# real entry point with run/run_in, assert on RC / OUT / ERR / ALL. No case
# reads a harness internal, imports a python module, or shares state with
# another case — see tests/README.md for why.

# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------
# All of them print the whole captured output on failure and exit 1, which the
# runner reports as a failed case. There is no "soft" assertion: a case that
# has already gone wrong tells you more if it stops at the first surprise.

_fail() {
  echo "  ASSERTION FAILED: $1"
  shift
  for _line in "$@"; do echo "    $_line"; done
  echo "  --- last command: $LAST_CMD"
  echo "  --- exit code: $RC"
  echo "  --- stdout ---"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  echo "  --- stderr ---"
  printf '%s\n' "$ERR" | sed 's/^/    /'
  exit 1
}

# assert_rc <expected> <what was being tested>
#
# EXIT CODES ARE ASSERTED EXPLICITLY, ALWAYS. Several of this project's bugs
# hid behind a command that printed the right thing and exited non-zero, or
# crashed and exited zero. "It worked" is not an observation; the code is.
assert_rc() {
  [ "$RC" = "$1" ] || _fail "$2" "expected exit $1, got $RC"
}

assert_rc_nonzero() {
  [ "$RC" != "0" ] || _fail "$1" "expected a non-zero exit, got 0"
}

# assert_out <substring> <what was being tested>   — searches stdout+stderr
assert_out() {
  case "$ALL" in
    *"$1"*) ;;
    *) _fail "$2" "expected output to contain: $1" ;;
  esac
}

assert_not_out() {
  case "$ALL" in
    *"$1"*) _fail "$2" "expected output NOT to contain: $1" ;;
    *) ;;
  esac
}

# assert_out_words <phrase> <what was being tested>
#
# Same as assert_out, but every run of whitespace on both sides collapses to
# one space first. The refusals in this harness are hand-wrapped to fit a
# terminal, so a sentence worth asserting on is routinely split across two
# lines — matching the literal text would pin the line breaks, which are not
# the contract, and would break on any rewrap.
assert_out_words() {
  _hay=$(printf '%s' "$ALL" | tr '\n' ' ' | tr -s ' ')
  _needle=$(printf '%s' "$1" | tr '\n' ' ' | tr -s ' ')
  case "$_hay" in
    *"$_needle"*) ;;
    *) _fail "$2" "expected output to contain (ignoring line wrapping): $1" ;;
  esac
}

# A gate that dies is not a gate. lib/handoff-guard.sh was found exiting on a
# Python traceback instead of a verdict, which reads to a caller as a broken
# tool rather than a rule — and the fix for that crash then turned it into a
# gate that silently passed everything. run_in checks this after EVERY command
# so no case can forget; this named version exists so a case that cares can say
# so out loud.
assert_no_traceback() {
  assert_not_out "Traceback (most recent call last)" "${1:-no command may exit via a Python traceback}"
}

assert_file() {
  [ -f "$1" ] || _fail "${2:-file should exist}" "missing file: $1"
}

assert_no_file() {
  [ ! -e "$1" ] || _fail "${2:-file should NOT exist}" "unexpected file: $1"
}

assert_dir() {
  [ -d "$1" ] || _fail "${2:-directory should exist}" "missing directory: $1"
}

# assert_same <expected> <actual> <what>
assert_same() {
  [ "$1" = "$2" ] || _fail "$3" "expected: $1" "actual:   $2"
}

# ---------------------------------------------------------------------------
# running the thing under test
# ---------------------------------------------------------------------------
# run_in <dir> <cmd> [args...]   — sets RC, OUT, ERR, ALL, LAST_CMD.
# Never returns non-zero itself: a refusal is the thing being tested, so the
# case must stay alive to assert on it.
run_in() {
  _dir="$1"; shift
  LAST_CMD="(cd $_dir && $*)"
  ( cd "$_dir" 2>/dev/null || exit 127; "$@" ) >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  RC=$?
  OUT=$(cat "$TEST_TMP/.out")
  ERR=$(cat "$TEST_TMP/.err")
  ALL="$OUT
$ERR"
  case "$ALL" in
    *"Traceback (most recent call last)"*)
      _fail "a command exited via a Python traceback — a tool that dies is not a gate" \
            "command: $LAST_CMD" ;;
  esac
  return 0
}

# run <cmd> [args...] — run_in against $REPO, which is where nearly everything
# is meant to be run from.
run() { run_in "$REPO" "$@"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
# vendor_harness <destination>
#
# THE HARNESS IS VENDORED AS PLAIN TRACKED FILES, so that is exactly what the
# fixtures do: copy the directories in and commit them. No nested .git, no
# clone, no symlink — a symlinked bin/ would make $0-relative resolution
# (lib/roots.sh's entropy_home) answer a question the real layout never asks.
vendor_harness() {
  for _d in bin lib hooks doctrine agents docs; do
    [ -d "$ENTROPY_SRC/$_d" ] || continue
    cp -R "$ENTROPY_SRC/$_d" "$1/"
  done
  find "$1" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
  return 0
}

# fixture_new [harness-subdir]
#
# A brand-new git repository with the harness vendored into it and committed,
# plus one file of "project code" (src/main.c) for scope tests to fight over.
# With no argument the harness lands at the repo root; with one (e.g.
# "tools/entropy") it lands in a subdirectory — both are supported layouts and
# both are exercised.
#
# Sets:
#   REPO      the repository's main checkout, PHYSICAL path (pwd -P). Physical
#             matters: bin/dispatch compares `pwd -P` against the resolved
#             root, and on macOS $TMPDIR is behind a symlink, so a logical path
#             would fail that comparison for a reason that has nothing to do
#             with the code under test.
#   HARNESS   where bin/ and lib/ actually are (== REPO for the root layout).
fixture_new() {
  _sub="${1:-}"
  REPO=$(mktemp -d "$TEST_TMP/repo.XXXXXX")
  REPO=$(CDPATH= cd -- "$REPO" && pwd -P)

  git -C "$REPO" init -q
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  git -C "$REPO" config user.email "tests@entropy.invalid"
  git -C "$REPO" config user.name  "entropy tests"
  git -C "$REPO" config commit.gpgsign false
  # A core.hooksPath inherited from the developer's own global config would
  # send lib/install-hooks.sh's shims somewhere shared and real. Pin it local
  # and absolute (absolute because install-hooks warns, correctly, that a
  # relative one is resolved per-worktree and would never fire).
  if git -C "$REPO" config --get core.hooksPath >/dev/null 2>&1; then
    git -C "$REPO" config core.hooksPath "$REPO/.git/hooks"
  fi

  mkdir -p "$REPO/src"
  printf 'int main(void) { return 0; }\n' > "$REPO/src/main.c"

  if [ -n "$_sub" ]; then HARNESS="$REPO/$_sub"; else HARNESS="$REPO"; fi
  mkdir -p "$HARNESS"
  vendor_harness "$HARNESS"

  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "vendor the entropy-machines harness"
}

# fixture_init — run the real bin/init and fail the case if it refuses.
# For tests ABOUT init, drive bin/init yourself instead.
fixture_init() {
  run "$HARNESS/bin/init"
  assert_rc 0 "fixture setup: bin/init should succeed in a fresh repo"
}

# fixture_hooks — install the git hooks and fail the case if that refuses.
fixture_hooks() {
  run "$HARNESS/lib/install-hooks.sh"
  assert_rc 0 "fixture setup: lib/install-hooks.sh should succeed"
}

# commit_all <message> — stage everything and commit, returning the hook's
# verdict in RC. Deliberately goes through a real `git commit` so the installed
# commit-msg hook actually runs; nothing here calls the guard directly.
commit_all() {
  git -C "$REPO" add -A >/dev/null 2>&1
  run git -C "$REPO" commit -m "$1"
}

# commit_paths <message> <path>... — the same, but staging only the named
# paths. Scope tests need this: `git add -A` would also sweep in whatever
# bin/dispatch wrote (.dispatch-context/ is untracked and not ignored), and
# then the set of files the commit touches is no longer the set the case
# chose.
commit_paths() {
  _msg="$1"; shift
  git -C "$REPO" reset -q >/dev/null 2>&1
  git -C "$REPO" add -- "$@" >/dev/null 2>&1
  run git -C "$REPO" commit -m "$_msg"
}

commit_count() {
  git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# network-ish helpers, for bin/serve only
# ---------------------------------------------------------------------------
# A port the kernel just told us is free. There is a race between closing it
# and bin/serve binding it; the alternative is a hardcoded port, which is a
# guaranteed collision on a developer's machine instead of an unlikely one.
free_port() {
  python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# http_get <url> — prints the status code on the first line, then the body.
# urllib rather than curl: python3 is already a hard dependency of the harness,
# curl is not.
http_get() {
  python3 -c 'import sys, urllib.request, urllib.error
try:
    r = urllib.request.urlopen(sys.argv[1], timeout=5)
    print(r.status)
    sys.stdout.write(r.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    print(e.code)
    sys.stdout.write(e.read().decode("utf-8", "replace"))
' "$1"
}

# wait_for_line <file> <substring> [tries] — poll a log file. Returns 1 on
# timeout so the caller can assert on it rather than hanging the suite.
wait_for_line() {
  _f="$1"; _needle="$2"; _tries="${3:-60}"
  while [ "$_tries" -gt 0 ]; do
    if [ -f "$_f" ] && grep -qF "$_needle" "$_f" 2>/dev/null; then return 0; fi
    sleep 0.1
    _tries=$((_tries - 1))
  done
  return 1
}
