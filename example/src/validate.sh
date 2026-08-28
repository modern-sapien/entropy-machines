#!/bin/sh
# Validate a username. Two INDEPENDENT rules, deliberately.
#
# The independence is the point: this example exists so you can watch the
# mutation proof work. Blind one rule and exactly the tests that rule owns go
# red, while the others stay green. Two disjoint mutations producing two
# disjoint failure sets is the strongest cheap signal that your tests are
# pinned to behaviour rather than passing by accident.
#
# Usage: validate.sh <name>   -> exit 0 valid, 1 invalid (reason on stdout)

name="$1"

# RULE A — length. Between 3 and 16 characters.
rule_length() {
  n=${#1}
  [ "$n" -ge 3 ] || { echo "too short"; return 1; }
  [ "$n" -le 16 ] || { echo "too long"; return 1; }
  return 0
}

# RULE B — charset. Lowercase letters, digits and underscore only.
rule_charset() {
  case "$1" in
    *[!a-z0-9_]*) echo "illegal character"; return 1 ;;
    *) return 0 ;;
  esac
}

rule_length "$name" || exit 1
rule_charset "$name" || exit 1
echo "ok"
