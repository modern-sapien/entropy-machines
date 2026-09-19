# entropy-machines

This repo **is** the harness. Vendored at repo root (no subdirectory prefix).
Docs dir: `entropy-machines-docs/`. Tracker: file-backed at `.entropy-machines/issues.json`.

**Read `docs/AGENT-QUICKSTART.md` and `doctrine/` before doing anything.**

## Roles

- **Owner** decides and ticks response boxes.
- **Orchestrator** dispatches, folds, lands — the only committer on `main`.
- **Worker** does one scoped issue in an isolated worktree and commits nothing.
- **Verifier** sweeps a sprint once, on a clean tree.

## Orchestrator rules

You are the orchestrator in this directory. Follow the cycle.

### Issue management — MCP only

- File issues via MCP `create_issue`. Never write `.entropy-machines/issues.json` directly — the pre-commit hook blocks it.
- Update issues via MCP `update_issue`.
- Check ready work with `get_ready_issues`.
- `planning/i-*.md` files without a matching tracker issue trigger a pre-commit warning.

### Dispatch — use the pipeline

- Dispatch implementation work via MCP `dispatch_issue`. It runs the full pipeline: preflight → worktree → worker → auto-verify → verifier.
- **Do not** use Claude Code's `Agent` tool to implement issue work. The dispatch pipeline enforces isolation, verification, and handoff gates that `Agent` bypasses.
- After `dispatch_issue` returns, fold the result with `handoff_issue`.

### What you do directly (no dispatch)

- Triage: reading code, filing issues, answering questions.
- Config changes: `config.json`, `CLAUDE.md`, `.mcp.json`.
- Version bumps, `npm pack`, QA testing.
- Doc content via MCP `update_doc` or `create_doc`.
- Small mechanical fixes where dispatch overhead exceeds the work (document why).

### Server

`bin/serve` should always be running. Start it if it isn't.

### Constraints

- 6 colors at 100% opacity: bg, fg, accent, positive, negative, notice.
- No `rgba()` for dim/muted text. Use `var(--fg)`.
- No CSS `var()` fallback values. Not `var(--accent, #7c3aed)`. Just `var(--accent)`.
- Never auto-open a browser. Use `--no-open` in tests and tooling.
