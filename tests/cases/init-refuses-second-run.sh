# A second bin/init refuses, names the file it will not overwrite, and leaves
# that file byte-for-byte alone.
#
# BOTH HALVES. The refusal on its own would be satisfied by a bin/init that
# refused unconditionally, so --force is asserted to still work — that is the
# control that says the gate is judging something.
. "$TEST_LIB/harness.sh"

fixture_new
fixture_init

# Someone has "tuned" the config. This is what must survive the second run.
python3 - "$REPO/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["suites"] = [{"name": "unit", "cmd": "true"}]
json.dump(d, open(p, "w"), indent=2)
PY
before=$(cksum < "$REPO/config.json")

run "$HARNESS/bin/init"
assert_rc_nonzero "a second bin/init must refuse"
assert_out "REFUSED" "the refusal says so"
assert_out "$REPO/config.json" "the refusal names the existing file by path"
assert_out "--force" "the refusal names the way out"

after=$(cksum < "$REPO/config.json")
assert_same "$before" "$after" "the refused run left the tuned config.json untouched"

# THE CONTROL. --force overwrites, so the refusal above is a judgement and not
# a blanket no.
run "$HARNESS/bin/init" --force
assert_rc 0 "bin/init --force overwrites an existing config"
forced=$(cksum < "$REPO/config.json")
[ "$forced" != "$before" ] || _fail "--force should have rewritten config.json" "checksum unchanged: $forced"

# And the .gitignore entry is added once, not once per run.
n=$(grep -cxF '.entropy-machines/' "$REPO/.gitignore")
assert_same "1" "$n" "re-running init does not duplicate the .entropy-machines/ ignore line"
