# The tracker adapter

The harness needs **six** operations from an issue tracker. That is the whole
dependency. Anything richer belongs to your tracker, not to us.

A backend is any executable that implements this CLI. `tracker.backend` in
`entropy.json` selects one.

| Command | Contract |
|---|---|
| `show <id>` | Print one issue as JSON on stdout. Exit 3 if no such issue. |
| `notes [--issue <id>]` | Print the note log as JSONL, one record per line, oldest first. With `--issue`, only that issue's records. |
| `remember --issue <id> <text>` | Append one note record. Must be atomic under concurrent writers. |
| `claim <id>` | Mark in-progress and record the claimant. Exit 4 if already claimed by someone else. |
| `ready` | Print claimable issues as JSONL — no open blockers, not held, not gated. |
| `set <id> <key>=<value>` | Set a field. Exit 2 on an unknown key. |

## The note record

The original harness wrote notes as free text with em-dash delimiters and
re-parsed that format in four independent places. Any format change needed
four synchronised edits, so the format could never change.

Notes are JSONL here. One record per line, one parser, `lib/notes`:

```json
{"ts":"2026-08-27T19:04:11Z","verb":"DISPATCH","issue":"i-foo","actor":"orchestrator",
 "fields":{"scope":["src/a.ts","tests/a.test.ts"],"brief":"one-line task"}}
```

- `verb` is the record type: `DISPATCH`, `HANDOFF`, `INTERROGATION`, or a
  backend-defined string. Consumers MUST ignore verbs they do not know.
- `fields` is free-form per verb. `scope` is an ARRAY — the original parsed
  comma-vs-space-delimited strings differently in different call sites.
- Records are append-only. Nothing rewrites or deletes one.

## What we deliberately do not require

Milestones, priorities, assignees, sprints, epics, time tracking. If your
tracker has them, good; the harness will not read them.

## Two states a general tracker usually lacks

A `command` backend that cannot express these will degrade: `ready` will
over-report, and the orchestrator has to catch it by eye.

- **held** — decided not to do now, WITH a reason. Distinct from closed: a
  held issue is a decision, not a completion, and `ready` must not return it.
- **gated** — blocked on an open question outside the issue graph (a design
  decision, an owner ruling). Distinct from blocked-by, which points at
  another issue. `ready` must not return a gated issue, and must fail closed
  when the gate handle is unknown.

**Neither is a `status` value.** `status` holds only `notstarted`, `progress`
or `done`. Held-ness is the presence of a `heldWhy` field; gated-ness is the
presence of a `gate` field. This is deliberate. Modelling them as statuses
makes the reason optional — a bare `status: held` is expressible, and a held
issue whose reason nobody recorded is indistinguishable from one somebody
forgot. Carrying the reason in the field that defines the state makes the
reasonless version unrepresentable.

It also keeps the two orthogonal to progress: an issue can be half-implemented
AND held, which a single status enum forces you to lose.

The built-in `file` backend enforces this — `set <id> status=held` is refused
with a message naming the right field.
