#!/usr/bin/env python3
"""Choose the issues one unattended fire will take. Prints ids, space-separated.

    bin/drain-pick.py [<repo-root>]

Its own file rather than a heredoc inside drain-run.sh, for two reasons. A
heredoc piped from `tracker ready` would have the pipe and the heredoc both
claiming stdin, which is a real way to have python read the TRACKER OUTPUT as
its own source and die on a syntax error. And a selection rule with a cap in
it is worth testing directly, which a heredoc cannot be.

THE RULE. A cap phrased as separate small/medium/large limits ("N small, M
medium, P large only") does not compose — it has nothing to say about a fire
that wants two smalls and one medium. Recasting the caps as unit costs that
share one budget makes mixing fall out for free instead of needing a new rule
per combination.

Costs and the budget are project config (`unattended.sizeCosts`,
`unattended.budget` in entropy.json) with defaults chosen so a few small caps
land on the same number:

    S = 3    M = 4    L = 6    budget = 12

    4 x S = 12      3 x M = 12      2 x L = 12

Every pure-class fire is therefore identical to what flat per-size caps of
4/3/2 would allow, and mixing now falls out of the same number: L + M + S is
13, over budget, so it takes L + M; L + S + S is 12, so it takes all three.

Selection walks the ranked list — the order `bin/tracker ready` printed it
in — and takes anything that still fits, skipping what does not and
continuing. Skipping rather than stopping matters: one large issue at rank
three should not strand a fire with 6 unspent points when there are smaller
items below it. Rank is never reordered — a cheaper issue is only ever
reached after every dearer one above it was considered.

ENTROPY_DRAIN_BUDGET overrides the configured budget for a bigger or smaller
fire without touching the per-size costs.

Eligibility is exactly what `bin/tracker ready` prints (docs/TRACKER-ADAPTER.md)
and nothing else — so an issue cannot be picked while blocked, held, or gated
on an open decision. There is no separate "autonomous" flag in the adapter
contract: an issue a human decided an unattended run should not touch is
`held`, via `bin/tracker set <id> heldWhy=...` (see bin/drain-prompt.md), and
`ready` already excludes it.
"""
import json
import os
import subprocess
import sys

DEFAULT_COST = {"S": 3, "M": 4, "L": 6}
DEFAULT_BUDGET = 12


def load_cost_model(root):
    """(costs, budget) out of entropy.json's `unattended` block.

    Not read through lib/config.py — that loader does not define these two
    keys yet (see its DEFAULTS dict), and this script only needs two scalars,
    not the full merge/validate pipeline. A missing file, a missing key, or a
    malformed value all fall back to the defaults above rather than raising —
    same posture as bin/drain's and bin/drain-run.sh's own `cfg()` helper.
    """
    try:
        with open(os.path.join(root, "entropy.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = {}
    unattended = data.get("unattended") or {}
    costs = unattended.get("sizeCosts")
    if not isinstance(costs, dict) or not costs:
        costs = DEFAULT_COST
    budget = unattended.get("budget")
    if not isinstance(budget, (int, float)):
        budget = DEFAULT_BUDGET
    return costs, budget


def parse(text):
    """[(id, effort)] in listed order — `bin/tracker ready`'s JSONL, one
    issue record per line (docs/TRACKER-ADAPTER.md).

    A line that fails to parse, or parses but carries no "id", is skipped
    rather than aborting the whole pick — one malformed record from a
    `command` backend should not zero out an otherwise-eligible fire.
    `effort` is optional in the adapter contract; a record without one is
    handled by the caller's fail-closed default, same as an unrecognised
    value.
    """
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict):
            continue
        iid = rec.get("id")
        if not iid:
            continue
        out.append((iid, rec.get("effort")))
    return out


def pick(rows, costs, budget):
    """Walk the ranked list, take whatever still fits, return the ids.

    An unrecognised or missing effort costs the most a fire can hold.
    Fail-closed: a typo'd or newly-invented size (or an issue nobody sized at
    all) must not become the cheapest thing on the list and let an
    unattended run take an unbounded amount of it.
    """
    left = budget
    taken = []
    fallback = max(costs.values()) if costs else budget
    for iid, effort in rows:
        c = costs.get(effort, fallback)
        if c <= left:
            taken.append(iid)
            left -= c
    return taken


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    costs, budget = load_cost_model(root)
    override = os.environ.get("ENTROPY_DRAIN_BUDGET")
    if override:
        try:
            budget = float(override)
        except ValueError:
            print(f"drain-pick: ENTROPY_DRAIN_BUDGET={override!r} is not a "
                  f"number, ignoring", file=sys.stderr)
    try:
        r = subprocess.run(
            [os.path.join(root, "bin", "tracker"), "ready"],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"drain-pick: cannot reach the tracker: {exc}", file=sys.stderr)
        return 1
    if r.returncode != 0:
        print(f"drain-pick: tracker exited {r.returncode}: {r.stderr.strip()}",
              file=sys.stderr)
        return 1
    print(" ".join(pick(parse(r.stdout), costs, budget)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
