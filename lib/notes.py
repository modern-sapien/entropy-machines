#!/usr/bin/env python3
"""notes.py — the one place that understands a tracker note record.

A note record is one JSON object, one per line (JSONL), oldest first:

    {"ts":"2026-08-27T19:04:11Z","verb":"DISPATCH","issue":"i-foo",
     "actor":"orchestrator","fields":{"scope":["src/a.ts"],"brief":"..."}}

`verb` names the record type (DISPATCH, HANDOFF, INTERROGATION, or a
backend-defined string — consumers ignore verbs they do not know). `fields`
is free-form per verb; array-shaped fields (`scope`, `denylist`, `found`,
`assumed`) are always arrays here, never a delimited string, so nothing
downstream has to guess whether a scope line was comma- or space-joined.

WHY THIS FILE EXISTS. The tool this one replaced re-parsed a free-text,
em-dash-delimited note format — "DISPATCH <id> — scope: ... — brief: ..." —
independently in four separate places: a denylist scanner, a sed extraction,
an interrogation-state scanner, and a gate script that read the tracker's
raw storage file directly and re-implemented the same regex a fourth time.
Each copy anchored its verb-matching slightly differently, and the one time
they disagreed, a HANDOFF note that merely quoted the DISPATCH format in its
own free text was read BACK as a live dispatch — the log describing the
format got misread as an entry in it, and two files stayed walled off for
forty minutes after the agent holding them had already been handed off.
That failure class cannot happen from this file's shape: `verb` and `issue`
are structured fields, not text a regex has to find, so a record that merely
DISCUSSES a verb in its `fields` cannot be mistaken for a record that IS
that verb.

Every caller that used to re-implement note parsing — the dispatcher, the
handoff recorder, the commit gate — imports this module (or shells out to
its CLI below) instead. One format, one parser, one place a format change
has to land.

CLI, all subcommands read note records from stdin (see load_records for the
shapes accepted) unless noted otherwise; anything unparseable is skipped, not
fatal — an append-only log a human has hand-edited once should degrade, not
die:

  notes.py encode --verb V [--actor A] [--field k=v]...
      Print one line of JSON: the payload a caller passes as the <text>
      argument to a `remember` call. A field named twice accumulates into an
      array; scope/denylist accumulate into an array even given once, split
      on comma OR whitespace, because the format this replaced parsed that
      inconsistently across its four call sites and every caller quietly
      assumed its own convention was the only one in use.

  notes.py claims [--self ID] [--hours N] [--now ISO] [--exclude PATH]...
      Live file-scope claims: for every issue whose most recent DISPATCH has
      not been released by a later HANDOFF and has not aged out past --hours
      (default 24 — a claim is a round's worth of time, not a permanent
      wall), print:
          CLAIM\t<issue>\t<space-joined paths>
      one line per claiming issue, then always:
          PATHS\t<space-joined unique paths>
      --self excludes an issue reclaiming its own files. --exclude removes
      paths that can never be contended (a directory every writer gets its
      own file inside, for instance).

  notes.py hits --hours N [--now ISO] [--exclude PATH]... -- PATH...
      Given paths a commit or a worker actually touched, which of them
      collide with a LIVE claim (see `claims`) held by someone else. Prints:
          HIT\t<path>\t<issue>\t<ts>
      one line per collision.

  notes.py record --issue ID --verb V [--verb V]... [--last]
      Print the matching record(s) for one issue, restricted to the given
      verb(s), as JSON — one per line, oldest first. --last prints only the
      final match (a plain 404-by-absence: nothing is printed, exit 0, if
      there is no match at all).

  notes.py interrogation-state --issue ID
      One of: no-dispatch | not-required | recorded | missing. See the
      docstring on interrogation_state() below for what each means.

  notes.py dispatch-fields --issue ID
      The fields of the LAST DISPATCH record for one issue, one per line,
      for a shell caller that must not hand-roll note parsing (bin/handoff):
          DISPATCH\t1|0            was a DISPATCH record found at all
          SCOPE\t<space-joined>    the declared --files scope
          DENYLIST\t<space-joined>|(none)|(unavailable)
          INTERROGATION\t<value-or-empty>
      The three denylist states are NOT interchangeable and are preserved
      exactly: a real list is enforced, `(none)` means the claim log was read
      and nobody held anything, `(unavailable)` means it could not be read and
      the caller must fall back to enforcing the scope as an allowlist.
      Exit 0 always when the stream could be read; a caller that gets a
      non-zero exit has an unreadable store and must refuse, not proceed.

  notes.py dispatch-handoff-ts --issue ID
      Print the timestamp of the last DISPATCH and last HANDOFF record for
      one issue (each on its own line, empty if none):
          DISPATCHED\t<ts-or-empty>
          HANDED\t<ts-or-empty>
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timedelta, timezone

ARRAY_FIELDS = {"scope", "denylist", "found", "assumed"}

# Of the array-shaped fields, only these two are built by a SHELL caller as one
# delimited path list, so only these two are split on receipt. `found` and
# `assumed` are prose an agent wrote; splitting those on whitespace turned one
# sentence into a list of words, which is why the encode CLI now wraps them
# instead. Both still land as arrays — the on-disk shape in ARRAY_FIELDS is
# unchanged, only the way a single --field value is coerced into one.
SPLIT_FIELDS = {"scope", "denylist"}


# --------------------------------------------------------------------------
# timestamps
# --------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(value):
    """Parse a note's `ts`. Returns an aware UTC datetime, or None if the
    value is empty or does not match either accepted shape. A record with an
    unparseable timestamp is never dropped by a caller on that basis alone —
    every caller here that uses ts for expiry treats "unknown" as "still
    live", because failing safe costs a false wall and failing open costs a
    clobber, and a clobber is the more expensive mistake."""
    if not value:
        return None
    v = str(value).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(v, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


# --------------------------------------------------------------------------
# scope / path helpers
# --------------------------------------------------------------------------

def normalize_scope(value) -> list[str]:
    """Coerce a scope-shaped value to a list of non-empty strings. Accepts a
    real list (the on-disk shape) or a bare string, comma- or
    whitespace-delimited (the shape a shell caller builds most naturally,
    and the one place the two delimiters used to disagree)."""
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [p for p in re.split(r"[\s,]+", str(value).strip()) if p]


def strip_annotation(path: str) -> str:
    """A scope entry can carry a trailing annotation: "path/(own)" (this
    agent's own claim, exempted at the call site that cares), "dir/*.md" (a
    glob within a directory), or a bare "dir/". Strip all three down to the
    bare path a prefix match can use."""
    path = re.sub(r"\(own\)$", "", path)
    path = re.sub(r"/\*.*$", "", path)
    return path.rstrip("/")


def path_under(path: str, claimed: list[str]) -> bool:
    """True if `path` is one of `claimed`, or nested under one of them."""
    for p in claimed:
        p = strip_annotation(p)
        if not p:
            continue
        if path == p or path.startswith(p + "/"):
            return True
    return False


def paths_overlap(a: str, b: str) -> bool:
    """True if `a` and `b` name the same path or one nests inside the
    other, in either direction — used for an early warning where the
    direction of containment is not yet known (an advisory --files entry
    against a live claim, say)."""
    a, b = strip_annotation(a), strip_annotation(b)
    if not a or not b:
        return False
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


# --------------------------------------------------------------------------
# record parsing
# --------------------------------------------------------------------------

def parse_line(line: str):
    line = line.strip()
    if not line:
        return None
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(rec, dict):
        return None
    return rec


def parse_stream(text: str) -> list[dict]:
    out = []
    for line in text.splitlines():
        rec = parse_line(line)
        if rec is not None:
            out.append(rec)
    return out


def load_records(text: str) -> list[dict]:
    """Every note in `text`, whatever shape it arrives in.

    THREE SHAPES, because a reader that knows only one of them does not fail
    loudly — it fails as a gate that passes everything.

      - ONE PRETTY-PRINTED JSON DOCUMENT, `{"issues": {...}, "notes": [...]}`.
        This is what lib/tracker-file writes to disk. Read a line at a time it
        mostly raises JSONDecodeError and is skipped, until a line that is a
        bare JSON string on its own (`          "src/main.c"`, one element of a
        pretty-printed scope array) parses CLEANLY to a str and the next
        `.get()` is an AttributeError. lib/handoff-guard.sh died exactly that
        way, and the "fix" that only stopped the crash turned a gate that
        exploded into one that silently allowed everything.
      - A BARE JSON ARRAY of records.
      - JSONL, one record per line — what `bin/tracker notes` prints, and the
        shape older logs were stored in.

    Anything unparseable yields nothing rather than raising. A caller that
    cannot read its own state must decline or refuse; it must never mistake
    "I read nothing" for "there is nothing".
    """
    raw = text or ""
    try:
        doc = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("notes"), list):
        return [r for r in doc["notes"] if isinstance(r, dict)]
    if isinstance(doc, list):
        return [r for r in doc if isinstance(r, dict)]
    return parse_stream(raw)


# ANCHORED TO THE START OF THE NOTE BODY, NOT SEARCHED FOR IN IT — a HANDOFF
# note that quotes this very format was read back as a live DISPATCH once and
# left two issues holding their files after they had been handed off.
LEGACY_VERB = re.compile(r"^(DISPATCH|HANDOFF|INTERROGATION)\s+(\S+)\s+—")


def record_text(record: dict) -> str:
    """The free-text body of a note, wherever it lives: at the top level in the
    old flat log, under `fields` once a structured record wrapped it (which is
    what lib/tracker-file's decode_payload does with any note that is not this
    module's own JSON payload)."""
    text = record.get("text")
    if not isinstance(text, str):
        fields = record.get("fields")
        text = fields.get("text") if isinstance(fields, dict) else None
    return text if isinstance(text, str) else ""


def legacy_fields(text: str) -> dict:
    """The three fields a rendered em-dash DISPATCH line carried, parsed the
    way its readers parsed it before this module existed. Deliberately three
    targeted patterns rather than a general `key: value` grammar: the brief is
    free text and can itself contain an em dash, so a general split would let a
    brief invent a scope. Scope is bounded by `— brief:` for the same reason —
    the denylist is also a path list and sits after the brief."""
    out: dict = {}
    m = re.search(r"—\s+scope:\s*(.*?)\s+—\s+brief:", text)
    if m:
        out["scope"] = normalize_scope(m.group(1))
    m = re.search(r"—\s+denylist:\s*(.*)$", text)
    if m:
        raw = m.group(1).strip()
        # `(none)` and `(unavailable)` are STATES, not paths — see
        # dispatch_fields for why the difference is load-bearing.
        out["denylist"] = raw if raw in ("(none)", "(unavailable)") else normalize_scope(raw)
    if " — interrogation: required" in text:
        out["interrogation"] = "required"
    return out


def read_record(record):
    """(verb, issue, fields) for one note — or None if it is neither shape.

    STRUCTURED FIRST, RENDERED TEXT AS THE FALLBACK, so a store holding both
    still works. A record whose verb is structurally present wins outright; one
    carrying the old `DISPATCH <id> — scope: … — brief: …` string is parsed out
    of its text. Nothing here raises: a record it cannot read is not a record.
    """
    if not isinstance(record, dict):
        return None
    verb, issue = record.get("verb"), record.get("issue")
    fields = record.get("fields")
    if not isinstance(fields, dict):
        fields = {}
    if isinstance(verb, str) and verb and verb != "NOTE" and isinstance(issue, str) and issue:
        return verb, issue, fields
    m = LEGACY_VERB.match(record_text(record).strip())
    if not m:
        return None
    return m.group(1), m.group(2), legacy_fields(record_text(record))


def dispatch_fields(records: list[dict], issue: str):
    """The fields of the LAST DISPATCH record for `issue`, or None if there is
    no DISPATCH for it at all. The two are not the same answer and the caller
    must not collapse them: no dispatch is hand-done work and fails open; a
    dispatch whose fields cannot be read is a broken gate and must not."""
    found = None
    for record in records:
        parsed = read_record(record)
        if parsed is None:
            continue
        verb, iid, fields = parsed
        if verb == "DISPATCH" and iid == issue:
            found = fields
    return found


def format_record(record: dict) -> str:
    return json.dumps(record, separators=(",", ":"), sort_keys=True)


def build_record(*, ts: str, verb: str, issue: str, fields: dict, actor=None) -> dict:
    return {"ts": ts, "verb": verb, "issue": issue, "actor": actor or "unknown", "fields": fields}


# --------------------------------------------------------------------------
# the remember-payload convention
# --------------------------------------------------------------------------
# The adapter contract (docs/TRACKER-ADAPTER.md) keeps `remember` to exactly
# `remember --issue <id> <text>` so ANY backend — including a real external
# tracker that only understands a free-text insight — can implement it. A
# structured caller (this harness's own dispatcher and handoff recorder)
# still wants a verb and typed fields, so it encodes them as one line of JSON
# and passes THAT as <text>. A backend that understands the convention
# (lib/tracker-file does) decodes it back into a structured record; a
# backend that does not just stores the JSON as an opaque message, which is
# still a valid, readable note — degraded, not broken.

def encode_payload(verb: str, fields: dict, actor=None) -> str:
    payload = {"verb": verb, "fields": fields}
    if actor:
        payload["actor"] = actor
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)


def decode_payload(text: str) -> dict:
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        obj = None
    if isinstance(obj, dict) and "verb" in obj and isinstance(obj.get("fields"), dict):
        return {"verb": str(obj["verb"]), "actor": obj.get("actor"), "fields": obj["fields"]}
    # Not our convention — an external tracker's own note, or a caller that
    # just wants to log a sentence. Wrap it rather than reject it.
    return {"verb": "NOTE", "actor": None, "fields": {"text": text}}


# --------------------------------------------------------------------------
# live claims (the file-scope denylist)
# --------------------------------------------------------------------------

def live_claims(records: list[dict], *, exclude_issue=None, never_claimed=(),
                 hours: float = 24.0, now=None) -> "dict[str, list[str]]":
    """Every issue currently holding a live file-scope claim, in the order
    its DISPATCH first appeared, most recent state per issue.

    THREE THINGS MAKE THIS "LIVE", not "was ever dispatched":
      - a later HANDOFF for the same issue releases it (verb-anchored on
        the `issue` field — no possibility of a note that merely mentions
        an id being mistaken for one that closes it, unlike the format this
        replaced);
      - a claim older than `hours` has expired. The log is append-only with
        no delete, so a DISPATCH that was never handed off would otherwise
        hold its files forever, and the end state of an ever-growing
        denylist is the allowlist it was built to avoid, with worse
        ergonomics;
      - a path in `never_claimed` is never a wall, because some directories
        are structurally uncontended (every writer gets its own file in
        them) and denying one anyway reproduces the exact failure this
        mechanism exists to prevent, through the other door.
    """
    if now is None:
        now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=hours)

    live: dict[str, tuple] = {}
    order: list[str] = []
    for rec in records:
        # read_record, not rec.get("verb"): a store still holding rendered
        # em-dash notes must claim and release from those too, or the two
        # readers of this log (here and lib/handoff-guard.sh, which already
        # falls back) disagree about who is holding what.
        parsed = read_record(rec)
        if parsed is None:
            continue
        verb, issue, rec_fields = parsed
        if not issue or verb not in ("DISPATCH", "HANDOFF"):
            continue
        if verb == "HANDOFF":
            live.pop(issue, None)
            continue
        ts = parse_ts(rec.get("ts"))
        if ts is not None and ts < cutoff:
            live.pop(issue, None)
            continue
        scope = normalize_scope(rec_fields.get("scope"))
        live[issue] = (ts, scope)
        if issue not in order:
            order.append(issue)

    result: dict[str, list[str]] = {}
    for issue in order:
        if issue not in live or issue == exclude_issue:
            continue
        _, paths = live[issue]
        kept = [p for p in paths if strip_annotation(p) not in never_claimed]
        if kept:
            result[issue] = kept
    return result


# --------------------------------------------------------------------------
# verb-anchored record lookup
# --------------------------------------------------------------------------

def last_record(records: list[dict], issue: str, verbs=None):
    """The last record for `issue`, oldest-first input assumed, optionally
    restricted to a set of verbs. None if there is no match."""
    match = None
    for rec in records:
        if rec.get("issue") != issue:
            continue
        if verbs and rec.get("verb") not in verbs:
            continue
        match = rec
    return match


def interrogation_state(records: list[dict], issue: str) -> str:
    """
      no-dispatch   — no DISPATCH record for this issue at all (hand-done
                       work, or an unreadable tracker — both fail open here;
                       there was never an agent to question).
      not-required  — the DISPATCH record predates the interrogation
                       contract (its fields carry no `interrogation:
                       required` marker), so the agent was never told it
                       would be questioned.
      recorded      — an INTERROGATION record follows the LAST DISPATCH.
                       Ordering matters: a re-dispatch reopens the question.
      missing       — the agent was told, and nobody has asked yet.
    """
    last_dispatch_i = last_interrogation_i = None
    required = False
    for i, rec in enumerate(records):
        parsed = read_record(rec)
        if parsed is None:
            continue
        verb, iid, fields = parsed
        if iid != issue:
            continue
        if verb == "DISPATCH":
            last_dispatch_i = i
            required = fields.get("interrogation") == "required"
        elif verb == "INTERROGATION":
            last_interrogation_i = i
    if last_dispatch_i is None:
        return "no-dispatch"
    if not required:
        return "not-required"
    if last_interrogation_i is not None and last_interrogation_i > last_dispatch_i:
        return "recorded"
    return "missing"


def dispatch_handoff_ts(records: list[dict], issue: str):
    """(dispatched_ts, handed_ts) — the timestamp of the last DISPATCH and
    last HANDOFF record for `issue`, or None for either that never occurred."""
    dispatched = handed = None
    for rec in records:
        if rec.get("issue") != issue:
            continue
        if rec.get("verb") == "DISPATCH":
            dispatched = rec.get("ts")
        elif rec.get("verb") == "HANDOFF":
            handed = rec.get("ts")
    return dispatched, handed


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _usage():
    print(__doc__, file=sys.stderr)
    sys.exit(2)


def _read_stdin_records() -> list[dict]:
    return load_records(sys.stdin.read())


def _take(args, flag, multi=False):
    """Pull every occurrence of `--flag value` out of args, in place.
    Returns a list if multi else the last value (or None)."""
    out = []
    i = 0
    while i < len(args):
        if args[i] == flag and i + 1 < len(args):
            out.append(args[i + 1])
            del args[i:i + 2]
        else:
            i += 1
    if multi:
        return out
    return out[-1] if out else None


def _cli_encode(args):
    verb = _take(args, "--verb")
    actor = _take(args, "--actor")
    raw_fields = _take(args, "--field", multi=True)
    if not verb:
        _usage()
    fields: dict = {}
    for kv in raw_fields:
        if "=" not in kv:
            _usage()
        k, v = kv.split("=", 1)
        if k in fields:
            existing = fields[k]
            fields[k] = (existing if isinstance(existing, list) else [existing]) + [v]
        elif k in SPLIT_FIELDS:
            fields[k] = normalize_scope(v)
        elif k in ARRAY_FIELDS:
            fields[k] = [v] if v.strip() else []
        else:
            fields[k] = v
    print(encode_payload(verb, fields, actor=actor))


def _cli_claims(args):
    self_id = _take(args, "--self")
    hours = _take(args, "--hours")
    now_s = _take(args, "--now")
    exclude = _take(args, "--exclude", multi=True)
    now = parse_ts(now_s) if now_s else None
    records = _read_stdin_records()
    claims = live_claims(
        records, exclude_issue=self_id or None,
        never_claimed=set(strip_annotation(p) for p in exclude),
        hours=float(hours) if hours else 24.0, now=now,
    )
    paths: list[str] = []
    for issue, held in claims.items():
        print(f"CLAIM\t{issue}\t{' '.join(held)}")
        for p in held:
            if p not in paths:
                paths.append(p)
    print(f"PATHS\t{' '.join(paths)}")


def _cli_hits(args):
    hours = _take(args, "--hours")
    now_s = _take(args, "--now")
    exclude = _take(args, "--exclude", multi=True)
    if "--" in args:
        args = args[args.index("--") + 1:]
    now = parse_ts(now_s) if now_s else None
    records = _read_stdin_records()
    claims = live_claims(
        records, never_claimed=set(strip_annotation(p) for p in exclude),
        hours=float(hours) if hours else 24.0, now=now,
    )
    # Rebuild per-issue timestamps for the report line.
    ts_by_issue = {}
    for rec in records:
        if rec.get("verb") == "DISPATCH" and rec.get("issue") in claims:
            ts_by_issue[rec["issue"]] = rec.get("ts", "")
    for path in args:
        for issue, held in claims.items():
            if path_under(path, held):
                print(f"HIT\t{path}\t{issue}\t{ts_by_issue.get(issue, '')}")
                break


def _cli_record(args):
    issue = _take(args, "--issue")
    verbs = _take(args, "--verb", multi=True)
    last = "--last" in args
    if last:
        args.remove("--last")
    if not issue:
        _usage()
    records = _read_stdin_records()
    matches = [r for r in records if r.get("issue") == issue and (not verbs or r.get("verb") in verbs)]
    if last:
        matches = matches[-1:]
    for rec in matches:
        print(format_record(rec))


def _cli_dispatch_fields(args):
    issue = _take(args, "--issue")
    if not issue:
        _usage()
    fields = dispatch_fields(_read_stdin_records(), issue)
    if fields is None:
        print("DISPATCH\t0")
        print("SCOPE\t")
        print("DENYLIST\t")
        print("INTERROGATION\t")
        return
    print("DISPATCH\t1")
    print("SCOPE\t" + " ".join(normalize_scope(fields.get("scope"))))
    # THREE STATES AND THEY ARE NOT INTERCHANGEABLE. A real list is enforced at
    # lift. `(none)` means the claim log was read and nobody held anything, so
    # every file is this agent's. ABSENT means it could not be read at all, and
    # the caller has to fall back to enforcing the advisory scope as an
    # allowlist. Collapsing the last two turns an unknown claim set into an
    # empty one, which is the silent-allow this whole reader exists to prevent.
    deny = fields.get("denylist")
    if deny is None:
        print("DENYLIST\t(unavailable)")
    elif isinstance(deny, str):
        print("DENYLIST\t" + deny.strip())
    else:
        paths = normalize_scope(deny)
        print("DENYLIST\t" + (" ".join(paths) if paths else "(none)"))
    interrogation = fields.get("interrogation")
    print("INTERROGATION\t" + (str(interrogation) if isinstance(interrogation, str) else ""))


def _cli_interrogation_state(args):
    issue = _take(args, "--issue")
    if not issue:
        _usage()
    print(interrogation_state(_read_stdin_records(), issue))


def _cli_dispatch_handoff_ts(args):
    issue = _take(args, "--issue")
    if not issue:
        _usage()
    dispatched, handed = dispatch_handoff_ts(_read_stdin_records(), issue)
    print(f"DISPATCHED\t{dispatched or ''}")
    print(f"HANDED\t{handed or ''}")


_CLI = {
    "encode": _cli_encode,
    "claims": _cli_claims,
    "hits": _cli_hits,
    "record": _cli_record,
    "dispatch-fields": _cli_dispatch_fields,
    "interrogation-state": _cli_interrogation_state,
    "dispatch-handoff-ts": _cli_dispatch_handoff_ts,
}


def main(argv):
    if not argv or argv[0] not in _CLI:
        _usage()
    _CLI[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    main(sys.argv[1:])
