#!/bin/sh
# Zero-dependency test suite. Nothing here needs a package manager, which is
# the point: the harness does not care what your project is written in.
#
# Exit 0 all pass, 1 any fail. Prints "PASS n / FAIL n" as the last line.
V="$(dirname "$0")/../src/validate.sh"
pass=0; fail=0

check() { # check <label> <input> <expect-exit> <expect-substring>
  out=$("$V" "$2" 2>&1); rc=$?
  if [ "$rc" = "$3" ] && printf '%s' "$out" | grep -q "$4"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: $1 (rc=$rc out='$out')"
  fi
}

# --- Rule A: length ---------------------------------------------------
check "length/too-short"  "ab"                 1 "too short"
check "length/minimum"    "abc"                0 "ok"
check "length/too-long"   "abcdefghijklmnopq"  1 "too long"

# --- Rule B: charset --------------------------------------------------
check "charset/uppercase" "Alice"              1 "illegal character"
check "charset/hyphen"    "a-b"                1 "illegal character"
check "charset/underscore" "a_b"               0 "ok"

echo "PASS $pass / FAIL $fail"
[ "$fail" = 0 ]
