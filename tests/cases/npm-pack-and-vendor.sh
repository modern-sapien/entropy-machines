# npm pack produces a tarball that installs correctly and vendors a working
# harness via both the default layout and --dir . — the end-to-end path an
# npm user hits, from pack through install through init.
#
# This is the case the previous handoff asked for: the --dir . bug was
# shippable because no test exercised the npm wrapper at all.
. "$TEST_LIB/harness.sh"

# node and npm are hard requirements for this case.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "  SKIP: node/npm not available"
  exit 0
fi

# ---- Pack the harness from ENTROPY_SRC ----

run_in "$ENTROPY_SRC" npm pack --pack-destination "$TEST_TMP"
assert_rc 0 "npm pack the harness"

TARBALL=$(ls "$TEST_TMP"/entropy-machines-*.tgz 2>/dev/null | head -1)
[ -n "$TARBALL" ] || _fail "tarball not found" "expected entropy-machines-*.tgz in $TEST_TMP"

# ---- Sanity-check the tarball contents ----

# The tarball must include the six harness directories plus the always-included
# files (LICENSE, README.md, package.json). It must NOT include tests/,
# planning/, example/, .entropy/, config.json (the project's own config), or
# CONTRIBUTING.md — those are source-only.
TAR_LIST=$(tar tzf "$TARBALL")

for d in bin/ lib/ docs/ doctrine/ hooks/ agents/; do
  echo "$TAR_LIST" | grep -q "^package/$d" \
    || _fail "tarball contents" "expected $d in the tarball"
done

for bad in tests/ planning/ example/ .entropy/ CONTRIBUTING.md __pycache__; do
  echo "$TAR_LIST" | grep -q "^package/$bad" \
    && _fail "tarball contents" "$bad should NOT be in the tarball"
done

# ---- Test 1: default layout (entropy-machines/ subdirectory) ----

DEFAULT_REPO=$(mktemp -d "$TEST_TMP/repo-default.XXXXXX")
DEFAULT_REPO=$(CDPATH= cd -- "$DEFAULT_REPO" && pwd -P)
git -C "$DEFAULT_REPO" init -q
git -C "$DEFAULT_REPO" config user.email "tests@entropy.invalid"
git -C "$DEFAULT_REPO" config user.name  "entropy tests"
git -C "$DEFAULT_REPO" config commit.gpgsign false
git -C "$DEFAULT_REPO" commit --allow-empty -qm "initial"
printf '{"name":"test-default","version":"1.0.0","private":true}\n' \
  > "$DEFAULT_REPO/package.json"
git -C "$DEFAULT_REPO" add package.json
git -C "$DEFAULT_REPO" commit -qm "add package.json"

run_in "$DEFAULT_REPO" npm install --no-fund --no-audit "$TARBALL"
assert_rc 0 "npm install tarball (default layout)"

# The bin link must exist.
assert_file "$DEFAULT_REPO/node_modules/.bin/entropy-machines" \
  "npm creates the entropy-machines bin link"

# Run init via the installed bin, not npx (avoids network probes in CI).
run_in "$DEFAULT_REPO" "$DEFAULT_REPO/node_modules/.bin/entropy-machines" init
assert_rc 0 "entropy-machines init (default layout)"

# The six harness directories must be vendored.
for d in bin lib docs doctrine hooks agents; do
  assert_dir "$DEFAULT_REPO/entropy-machines/$d" \
    "default layout: $d/ vendored"
done

# config.json must exist (written by bin/init, not by the npm wrapper).
assert_file "$DEFAULT_REPO/entropy-machines/config.json" \
  "default layout: config.json written"

# .version stamp for auto-update detection.
assert_file "$DEFAULT_REPO/entropy-machines/.version" \
  "default layout: .version stamp written"

# LICENSE must travel with the vendored code (Elastic 2.0 notice requirement).
assert_file "$DEFAULT_REPO/entropy-machines/LICENSE" \
  "default layout: LICENSE copied"

# The npm wrapper itself must NOT be vendored — it is the delivery mechanism,
# not part of the harness.
assert_no_file "$DEFAULT_REPO/entropy-machines/bin/entropy-machines-init" \
  "npm wrapper excluded from vendoring"

# No nested .git anywhere in the vendored tree. A nested .git shadows the
# parent repo for every git query and is the exact failure vendoring exists
# to prevent.
_nested=$(find "$DEFAULT_REPO/entropy-machines" -name ".git" -type d 2>/dev/null || true)
[ -z "$_nested" ] \
  || _fail "no nested .git" "found: $_nested"

# Key files must be executable after going through pack -> install -> copy.
for f in bin/init bin/serve bin/tracker bin/dispatch bin/handoff \
         lib/install-hooks.sh hooks/commit-msg hooks/pre-commit; do
  [ -x "$DEFAULT_REPO/entropy-machines/$f" ] \
    || _fail "exec bit preserved" "$f should be executable"
done

# ---- Test 2: --dir . layout ----

DOTDIR_REPO=$(mktemp -d "$TEST_TMP/repo-dotdir.XXXXXX")
DOTDIR_REPO=$(CDPATH= cd -- "$DOTDIR_REPO" && pwd -P)
git -C "$DOTDIR_REPO" init -q
git -C "$DOTDIR_REPO" config user.email "tests@entropy.invalid"
git -C "$DOTDIR_REPO" config user.name  "entropy tests"
git -C "$DOTDIR_REPO" config commit.gpgsign false
git -C "$DOTDIR_REPO" commit --allow-empty -qm "initial"
printf '{"name":"test-dotdir","version":"1.0.0","private":true}\n' \
  > "$DOTDIR_REPO/package.json"
git -C "$DOTDIR_REPO" add package.json
git -C "$DOTDIR_REPO" commit -qm "add package.json"

run_in "$DOTDIR_REPO" npm install --no-fund --no-audit "$TARBALL"
assert_rc 0 "npm install tarball (--dir . layout)"

run_in "$DOTDIR_REPO" "$DOTDIR_REPO/node_modules/.bin/entropy-machines" init --dir .
assert_rc 0 "entropy-machines init --dir ."

# The six directories must be at the repo root.
for d in bin lib docs doctrine hooks agents; do
  assert_dir "$DOTDIR_REPO/$d" \
    "--dir . layout: $d/ vendored at root"
done

# config.json at root.
assert_file "$DOTDIR_REPO/config.json" \
  "--dir . layout: config.json at root"

# The commit hint for --dir . must name the individual directories, not
# "git add ." — the repo now contains node_modules/ and a package-lock.json
# that the harness's .gitignore does not cover.
assert_out_words "git add bin lib docs doctrine hooks agents LICENSE" \
  "--dir . layout: commit hint names dirs, not 'git add .'"
assert_not_out "git add ." \
  "--dir . layout: commit hint must not say 'git add .'"

# No nested .git in the --dir . tree either (check vendored dirs only,
# skip the real .git and node_modules).
for d in bin lib docs doctrine hooks agents; do
  _nested2=$(find "$DOTDIR_REPO/$d" -name ".git" -type d 2>/dev/null || true)
  [ -z "$_nested2" ] \
    || _fail "no nested .git in $d" "found: $_nested2"
done

# Key files must still be executable.
for f in bin/init bin/serve bin/tracker lib/install-hooks.sh hooks/commit-msg; do
  [ -x "$DOTDIR_REPO/$f" ] \
    || _fail "exec bit preserved (--dir .)" "$f should be executable"
done
