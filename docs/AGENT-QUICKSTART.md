# Agent quickstart

Read this entire doc before bootstrapping or running the harness. These are
directives, not suggestions — follow every step.
If you are the project owner (a human), start at [../README.md](../README.md).

**MANDATED READING — you MUST read [../doctrine/](../doctrine/) before
proceeding.** It explains why the gates exist.

## Context

**entropy-machines** is a project harness that moves work through a fixed
cycle — dispatch, work, verify, fold — enforced by shell gates, not convention.
Four roles (owner, orchestrator, worker, verifier) collaborate through tracked
issues and served HTML docs with response boxes.

**The browser UI is a React SPA backed by SQLite.** `bin/serve` runs a local
web server that serves a single-page app. All content the browser displays —
docs, pages, responses, issues — is read from the SQLite database at
`.entropy-machines/entropy-machines.db`. The HTML files on disk in the docs
directory are source material consumed by `bin/migrate-db` to populate that
database; **editing an HTML file on disk does not change what the browser
shows**. The browser reads from the database via `/api/*` REST endpoints
(defined in `lib/api.py`), and agents write to the same database through MCP
tools or those endpoints.

The schema (`lib/schema.sql`): `docs` holds document metadata, `pages` holds
the HTML content per page, `responses` holds response boxes and their values,
`issues` and `issue_events` hold the tracker state. Everything the SPA renders
comes from these tables.

Plain tracked files, one git root. The harness is vendored as tracked files,
never a nested git repository; prefix commands with the harness path if it sits
in a subdirectory.

## Tools

### MCP tools (primary interface when connected)

When the MCP server is connected (`bin/mcp-serve` over stdio, configured in
`.mcp.json`), you MUST use these tools — do not shell out to `bin/*`. They call
the same handlers as the REST API — same validation, same database.

**Issue tracker:**

| Tool | What it does |
|---|---|
| `list_issues` | List all issues, optionally filtered by status. |
| `get_issue` | Get a single issue by id. |
| `create_issue` | Create a new issue (id, title, description required). |
| `update_issue` | Update fields on an existing issue. |
| `list_issue_events` | List all events (dispatch, handoff, comment) for an issue. |
| `add_issue_event` | Add an event to an issue. |
| `get_ready_issues` | Issues ready for dispatch: notstarted, not held, not blocked. |
| `get_active_claims` | Issues currently claimed by an agent. |

**Documents:**

| Tool | What it does |
|---|---|
| `list_docs` | List all documents with response counts. |
| `get_doc` | Get a document by id, including pages and responses. |
| `create_doc` | Create a new document with pages and response boxes. |
| `update_doc` | Write HTML content into a document's pages (data-informational sections). This is how agents fill in doc content. |
| `update_doc_status` | Update a document's status or metadata (title, short_name, foot). |
| `create_report` | Generate a sprint report or dialogue doc (HTML file + manifest + SQLite). |

**Pipeline:**

| Tool | What it does |
|---|---|
| `dispatch_issue` | Run the full dispatch pipeline (preflight, worktree, worker, verify). |
| `handoff_issue` | Record that work on an issue is complete. |

### Shell commands (pipeline operations)

These are the mechanical gates. Use them only when MCP is not connected or
for operations with no MCP equivalent.

```
bin/status                                        # read-only: ready, in flight, unanswered
bin/tracker show|notes|remember|claim|ready|set   # six tracker operations
bin/dispatch <id> --files "..." --brief "..."     # the gate before any writing agent
bin/handoff <id> --from <worktree> --verified "..." # the only way work lands
bin/serve [port]                                  # start the SPA server (default 8787)
bin/doclint [path...]                             # lint doc HTML
bin/init                                          # bootstrap — writes config.json
bin/migrate-db                                    # build/rebuild the SQLite database
bin/mcp-serve                                     # MCP server (stdio, launched by .mcp.json)
```

`tracker ready` is the state of the world, not a doc's account of it: it
excludes held (`heldWhy`) and gated (`gate`). `dispatch --files` is advisory;
what is enforced is the denylist of files other agents hold, pasted into your
brief. The tracker backend is adaptable — see
[TRACKER-ADAPTER.md](TRACKER-ADAPTER.md).

**MANDATED READING — you MUST read [CONFIG.md](CONFIG.md) and
[SERVE.md](SERVE.md) before proceeding.**

## The job

### Step 0 — bootstrap (no `config.json` yet)

This is your first job and the whole job. Do not stop for permission between
steps.

1. **Point `CLAUDE.md` and/or `AGENTS.md` at the harness** — both if both
   exist, rewriting nothing already there:

   ```markdown
   ## entropy-machines
   Vendored at `<path>`. **Owner** decides and ticks. **Worker** does one scoped
   issue in an isolated worktree and commits nothing. **Verifier** sweeps a sprint
   once, on a clean tree. **Orchestrator** dispatches, folds, lands — the only
   committer. Doctrine: `<path>/doctrine/`.
   ```

2. **Run `bin/init`.** It writes `config.json`, gitignores `.entropy-machines/`,
   copies the orientation PRD into `docs.dir`, and builds the SQLite database.
   **Then run `bin/init` again and confirm it exits 2.** That refusal proves
   the bootstrap landed. If it does not exit 2, stop and report the output.

3. **Baseline discovery — record only what you RAN.** `init` writes
   `suites: []` rather than guess. **Spawn an Explore subagent** to locate the
   project's test, typecheck, and build commands — do not guess commands
   yourself. Then **run** each candidate command the Explore subagent found
   and enter only those that passed into `config.json`; one that fails is a
   finding, not an entry.

4. **Fill the PRD's data-informational sections.** Use the `update_doc` MCP
   tool to write your findings into the database. The orientation PRD has pages
   you fill (what you found in the repo, what you could not verify) and pages
   only the owner answers (open questions, priorities). Fill yours, leave the
   owner's. **Do not edit the HTML file on disk** — the browser reads from
   SQLite, so edits to the file are invisible until the next `migrate-db` run,
   which would overwrite your database writes.

5. **Run `bin/doclint`** first. Then **run `bin/serve`** — start it
   backgrounded; it holds the terminal. It binds `127.0.0.1` and prints its
   URL.

Hand over that URL and **stop**. A PRD you answered yourself produces issues
nobody agreed to.

## Rules

### Never

- **Commit**, unless you are the orchestrator landing via `handoff`.
- **Edit HTML doc files on disk** expecting the browser to reflect it. The SPA
  reads from SQLite. Use `update_doc` (MCP) or the REST API to write content.
- **Edit the tracker directly.** File issues via MCP `create_issue` / `update_issue`
  or the REST API. Direct edits to `.entropy-machines/issues.json` are blocked by
  pre-commit hooks.
- **Claim a command you did not run.** Suites, typecheck, build — if you say it
  passed, you ran it.
- **Write a file another live dispatch holds.** Stop, ship nothing, name the
  file in `HANDOFF.md`'s `found:` line.
- **Touch another worktree**, or run the full build (it rewrites committed
  bookkeeping — use `suites`).
- **Relay another agent's verification.** You verify your own work.
- **Land held work.**
- **Answer the owner's response boxes.** Data-informational pages are yours;
  open questions, priorities, and decisions are the owner's.

### Limits

- **`--lift` exits 1 on `.scratch`** — delete that symlink from the worktree,
  rerun.
- **Claude-native in practice.** The gates are POSIX shell; automatic parallel
  workers in isolated worktrees is a Claude Code capability. Another runner gets
  the same gates one issue at a time, using `agents/isolated-worker.md` by hand.
- **Isolation can silently not happen.** `isolation: worktree` branches the repo
  the *calling session's cwd* is in, so driving one project from a shell in
  another hands every worker the wrong repo — or one shared checkout where
  agents see each other's edits. Workers check `git rev-parse --git-common-dir`
  (never `--show-toplevel`); orchestrators verify cwd, keep scopes disjoint and
  never `git add -A` while a lane is live. No gate covers it —
  [../doctrine/WORKFLOW.md](../doctrine/WORKFLOW.md).
