# config.json — the project contract

Everything the harness would otherwise hardcode about its host project, at the
repo root. Nothing in `bin/` or `lib/` may name a language, package manager or
directory not read from here. It is also the root marker.

`bin/init` writes the first one. It files **no issues** (a PRD is what creates
issues) and guesses at no command it hasn't run — a fabricated suite makes the
harness report a broken command as a broken project.

```json
{
  "project":    { "name": "my-project", "protectedPaths": [] },
  "tracker":    { "backend": "file", "file": { "path": ".entropy-machines/issues.json" } },
  "docs":       { "dir": "entropy-machines-docs", "theme": "janus" },
  "suites":     [ { "name": "unit", "cmd": ["npm", "test"] },
                  { "name": "e2e",  "cmd": ["npm", "run", "e2e"], "tag": "slow" } ],
  "generate":   { "cmd": ["npm", "run", "gen"], "outputs": [] },
  "changelog":  { "enabled": true, "fragmentDir": "changelog.d",
                  "collatedFile": "docs/CHANGELOG.md",
                  "marker": "<!-- BEGIN COLLATED changelog.d -->" },
  "guards":     { "testPathPatterns": ["tests/**"], "nonCodePatterns": ["**/*.md"],
                  "buildFailureMarkers": [] },
  "worktree":   { "linkPaths": ["node_modules"] },
  "unattended": { "enabled": false, "scheduler": "launchd",
                  "agent": { "cmd": ["claude", "-p"] } }
}
```

Every key is optional — deep-merged over `lib/config.py`'s `DEFAULTS`.

| Key | What it means |
|---|---|
| `project.protectedPaths` | Off-limits to a dispatched agent without an override. |
| `tracker.backend` | `file`, or `command` for your own tracker — [TRACKER-ADAPTER.md](TRACKER-ADAPTER.md). |
| `docs.dir` / `.theme` | What `bin/serve` serves; `theme` names a file in `lib/themes/`. |
| `suites` | What "the suites" means. `post-fold-audit` and the verifier run these; `tag` is skippable. |
| `generate` | `handoff` runs it and fails the fold if anything moves. |
| `changelog` | Whether a fragment is required per commit. Defaults on. |
| `guards` | How fail-first classifies a revert, and tells a build failure from a test failure. |
| `worktree.linkPaths` | Symlinked into every worktree. Without `node_modules` a runtime resolves out of a SIBLING worktree and the agent verifies someone else's code. |
| `unattended` | The drain loop. `scheduler` is `launchd` (macOS) or `systemd` (a `systemctl --user` timer); omit the key and `bin/drain install` detects one, refusing if neither is present. `on/off/status/now/at` work anywhere. |

## Themes and root

`docs.theme` resolves to `lib/themes/<name>.css` — `janus` (default,
dark-first, violet-accented), `high-contrast` (dark-first, blue-accented),
or `daylight` (light-first). A theme is a `:root` token block and
nothing else, so layout stays in the templates; every theme must define the same
names with a real value in the bare `:root`, since one defined only under
`[data-theme=…]` renders unstyled by default.
`tests/cases/themes-ship-and-apply.sh` catches that by diffing the name sets.
How `bin/serve` inlines it: [SERVE.md](SERVE.md).

The harness is vendored as **plain tracked files**, never a git repository of
its own — a nested `.git` shadows the enclosing repo, so commands operate on the
wrong one; `git clone` and `git submodule` are refused by name. **Root** is
always the MAIN CHECKOUT, via `--git-common-dir`, never `--show-toplevel`: they
differ inside a linked worktree, and `.entropy-machines/` lives in the main checkout.
`lib/roots.sh` is canonical; `lib/config.py` and `lib/config.mjs` mirror it.

## Rules for contributors

1. A new hardcoded path, command or noun in `bin/` or `lib/` is a bug — add a key.
2. Every key has a working default, or the harness refuses naming the missing
   key. Silent fallback is what made the original un-portable.
3. Read once per process and passed down; never re-read from library code.
4. Anything resolving root independently uses `--git-common-dir` and cites
   `lib/roots.sh`. Three implementations already drifted apart once.
