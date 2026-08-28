#!/usr/bin/env python3
"""Choose the issues one unattended fire will take. Prints ids, space-separated.

    scripts/drain-pick.py [<repo-root>]

Its own file rather than a heredoc inside drain-run.sh, for two reasons. The
heredoc version was broken on arrival — `tracker ready | python3 - <<'PY'` has
the pipe and the heredoc both claiming stdin, so python read the TRACKER OUTPUT
as its source and died on an IndentationError. And a selection rule with a cap
in it is worth testing directly (test_drain_pick.py), which a heredoc cannot be.

THE RULE. The owner's original framing was "4 small, 3 medium, 2 large only"
(UNATTENDED-OPS, 2026-08-09), then: "mixing is fine, but you need to create a
scoring system."

So the three caps become the DEFINITION of one fire's budget rather than three
separate rules. Costs are chosen so all three are exactly equal:

    S = 3    M = 4    L = 6    budget = 12

    4 × S = 12      3 × M = 12      2 × L = 12

Every pure-class fire is therefore identical to what the caps used to allow,
and mixing now falls out of the same number: L + M + S is 13, over budget, so
it takes L + M; L + S + S is 12, so it takes all three.

Selection walks the ranked list and takes anything that still fits, skipping
what does not and continuing. Skipping rather than stopping matters: one large
issue at rank three should not strand a fire with 6 unspent points when there
are smaller items below it. Rank is never reordered — a cheaper issue is only
ever reached after every dearer one above it was considered.

The count is bounded without a separate rule: the cheapest issue costs 3, so
no fire can take more than 4 items.

JANUS_DRAIN_BUDGET overrides the 12 for a bigger or smaller night without
touching the costs — set it to 6 to halve a fire, 24 to double it.

Eligibility is `tracker ready --autonomous` and nothing else — so an issue
cannot be picked while blocked, held, gated on an open decision, or tagged
hand-only.
"""
import os
import re
import subprocess
import sys

COST = {"S": 3, "M": 4, "L": 6}
BUDGET = int(os.environ.get("JANUS_DRAIN_BUDGET", "12"))

# The ready listing is columnar: two spaces, an optional priority band, an
# optional "unblocks N", then id, [workstream], effort.
#
# Every element before the id is enumerated rather than skipped with `.*?`.
# The permissive version matched the CONTINUATION lines too — priority notes
# and decision-doc flags are printed indented under their issue, so a note whose
# prose happened to mention an id parsed as a second work item. An unattended
# run would then take an issue nobody selected. Caught by test_drain_pick.
ROW = re.compile(
    r"^ {2}\s*(?:demo|broken|backlog)?\s*(?:unblocks \d+)?\s+"
    r"(i-[a-z0-9-]+)\s+\[(\w+)\s*\]\s+([SML])(?:\s|$)")


def parse(text):
    """[(id, effort)] in listed order — which is ranked order, not file order."""
    out = []
    for line in text.splitlines():
        m = ROW.match(line)
        if m:
            out.append((m.group(1), m.group(3)))
    return out


def pick(rows, budget=None):
    """Walk the ranked list, take whatever still fits, return the ids.

    An unknown effort letter costs the most a fire can hold. Fail-closed: a
    typo'd or newly-invented size must not become the cheapest thing on the
    list and let an unattended run take an unbounded amount of it.
    """
    left = BUDGET if budget is None else budget
    taken = []
    for iid, effort in rows:
        c = COST.get(effort, max(COST.values()))
        if c <= left:
            taken.append(iid)
            left -= c
    return taken


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        r = subprocess.run([os.path.join(root, "scripts", "tracker"),
                            "ready", "--autonomous"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"drain-pick: cannot reach the tracker: {exc}", file=sys.stderr)
        return 1
    if r.returncode != 0:
        print(f"drain-pick: tracker exited {r.returncode}: {r.stderr.strip()}",
              file=sys.stderr)
        return 1
    print(" ".join(pick(parse(r.stdout))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
