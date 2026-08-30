# lib/install-hooks.sh installs shims AND verifies its own install.
#
# "A setting that is quietly ignored is a failure this project has already paid
# for once. An installer that prints 'installed' without checking is the same
# bug in a different costume." So the assertions are: the shims exist and are
# executable, the baked-in path is absolute and resolves, the installer exits
# non-zero when it does not — and bin/dispatch refuses to brief anybody from a
# checkout with no gate installed.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# --- dispatch refuses BEFORE the hooks are installed -----------------------
# An uninstalled hook is a total, silent loss of the gate in a checkout that
# looks identical to one that has it. This check sits immediately before the
# only activity the gate protects.
run "$HARNESS/bin/dispatch" i-early --files "src/main.c" --brief "b"
assert_rc_nonzero "dispatch must refuse with no commit-msg hook installed"
assert_out "REFUSED" "the refusal says so"
assert_out "commit-msg" "and names the missing hook"
assert_out "install-hooks.sh" "and the command that installs it"

# --- install ---------------------------------------------------------------
run "$HARNESS/lib/install-hooks.sh"
assert_rc 0 "install-hooks succeeds"
assert_out "verified" "and says it verified its own install"

for h in commit-msg pre-commit post-checkout; do
  [ -f "$HARNESS/hooks/$h" ] || continue
  assert_file "$REPO/.git/hooks/$h" "the $h shim is installed"
  [ -x "$REPO/.git/hooks/$h" ] || _fail "the $h shim must be executable" "not executable: $REPO/.git/hooks/$h"
done

# The shim lives in .git/hooks and cannot find lib/ relatively, so the harness
# path is baked in. It must be ABSOLUTE — a relative one resolves against
# whatever cwd git happens to give the hook.
baked=$(sed -n 's/^export ENTROPY_HOME="\(.*\)"$/\1/p' "$REPO/.git/hooks/commit-msg" | head -1)
assert_same "$HARNESS" "$baked" "the shim bakes in the harness directory, absolute"

# --- dispatch is satisfied now ---------------------------------------------
run "$HARNESS/bin/dispatch" i-early --files "src/main.c" --brief "b"
assert_rc 0 "with the hooks installed, dispatch proceeds"

# --- the installer catches a dead install ----------------------------------
# A shim that installs cleanly and points at a harness directory that is not
# there is "installed, verified, dead". The installer reads its own written
# file back off disk to catch exactly that, so breaking the target must make
# it exit non-zero rather than print success.
chmod -x "$HARNESS/hooks/commit-msg"
run "$HARNESS/lib/install-hooks.sh"
assert_rc_nonzero "install-hooks must FAIL when the hook it points at is not executable"
assert_out "FAIL" "and say which check failed"
chmod +x "$HARNESS/hooks/commit-msg"
