# entropy.json — the project contract

Every hardcoded assumption the harness used to make about its host project
lives here. A consuming project drops `entropy.json` at its repo root.
Nothing in `bin/` or `lib/` may name a language, a package manager, or a
directory that is not read from this file.

## Getting a first entropy.json

Every other entry point refuses to run without `entropy.json` at the project
root (rule 2 below) — on purpose, but that leaves a brand-new project with no
way in. Run `bin/init` from inside it. It writes a starter file (project
name, the file tracker backend, and otherwise empty/off: no suites, no
protected paths, changelog disabled) and installs the orientation PRD into
the project's docs directory, where `bin/serve` renders it.

It files **no issues**. A PRD is the upstream artifact — it is what creates
issues — so seeding a task here would invert that and skip the owner's
ruling. The starter file is deliberately incomplete: it does not guess at a
suite command or anything else it has not verified, because the harness would
report a fabricated command as a failing project rather than an unconfigured
one. Completing it is one of the issues the orientation PRD asks you to file.
`bin/init` refuses to overwrite an existing `entropy.json` unless you pass
`--force`.

```jsonc
{
  "project": {
    "name": "my-project",
    // Paths that must never be edited by a dispatched agent without an
    // explicit override. Append-only interfaces, generated bundles, etc.
    "protectedPaths": []
  },

  "tracker": {
    // "file" is the built-in flat backend. "command" shells out to an
    // external tracker via the adapter contract in docs/TRACKER-ADAPTER.md.
    "backend": "file",
    "file":    { "path": ".entropy/issues.json" },
    "command": { "bin": "bd" }
  },

  // Where planning docs live: what bin/serve serves, where bin/init drops
  // PRD-001, and where bin/status looks for unanswered questions. Defaults to
  // "entropy-docs" when absent.
  "docs": { "dir": "entropy-docs" },

  // What "the suites" means here. post-fold-audit and the verifier run these.
  // "tag" groups them: a tag can be skipped with --skip <tag>.
  "suites": [
    { "name": "typecheck", "cmd": ["npm", "run", "typecheck"] },
    { "name": "unit",      "cmd": ["npm", "test"] },
    { "name": "e2e",       "cmd": ["npm", "run", "e2e"], "tag": "slow" }
  ],

  // Regenerating committed artefacts. handoff runs this and fails the fold
  // if anything moves — a generated file that differs means the committed
  // bundle does not match the committed source.
  "generate": { "cmd": ["npm", "run", "gen"], "outputs": [] },

  "changelog": {
    "enabled": true,
    "fragmentDir": "changelog.d",
    "collatedFile": "docs/CHANGELOG.md",
    "marker": "<!-- BEGIN COLLATED changelog.d -->"
  },

  // Used by fail-first (the mutation prover) to classify a revert and to
  // recognise a build failure as distinct from a test failure.
  "guards": {
    "testPathPatterns": ["**/*.test.*", "tests/**"],
    "nonCodePatterns":  ["**/*.md", "docs/**"],
    "buildFailureMarkers": []
  },

  // Symlinked into every new agent worktree by the post-checkout hook.
  // node_modules is the classic case: without it, the runtime resolves out
  // of a SIBLING worktree and the agent verifies someone else's code.
  "worktree": { "linkPaths": ["node_modules"] },

  "unattended": {
    "enabled": false,
    "stateHome": "~/.entropy",
    // "launchd" is the only value `bin/drain install` implements, and it
    // is macOS-only. Off macOS the installer refuses and installs nothing;
    // run bin/drain-run.sh from a cron entry or systemd unit you write
    // yourself — bin/drain on/off/status/now/at work on any POSIX box.
    "scheduler": "launchd",
    "label": "com.entropy.drain",
    "agent": { "cmd": ["claude", "-p"] }
  }
}
```

## Where the harness lives, and what "root" means

The harness is **vendored as plain tracked files** inside your project — at
the repo root, or in a subdirectory (`tools/`, `entropy-machines/`, anything)
— and committed alongside your code, the same way a `scripts/` directory is.

It must not be a git repository of its own. A nested `.git` shadows the
enclosing repo for every git query, so commands run from inside it resolve to
the harness and operate on the wrong repository. `git clone` and `git
submodule` are both refused by name, pointing at the directory at fault.
Copy the files in, or use `npx entropy-machines init`.

**Root** always means the repository's MAIN CHECKOUT, resolved with
`git rev-parse --git-common-dir` — never `--show-toplevel`. The two differ
inside a linked worktree: `--show-toplevel` gives the worktree, and the issue
store (`.entropy/`) lives in the main checkout. Workers run in worktrees, so
resolving to the worktree sends their state somewhere nothing else reads.
`lib/roots.sh` is canonical; `lib/config.py` and `lib/config.mjs` mirror it.

## Rules for contributors

1. A new hardcoded path, command, or product noun in `bin/` or `lib/` is a bug.
   Add a config key instead.
2. Every key must have a working default, or the harness must refuse with a
   message naming the missing key. Silent fallback is what made the original
   un-portable.
3. `entropy.json` is read once per process and passed down. Do not re-read it
   from library code.
4. Anything that resolves the repository root independently must use
   `git rev-parse --git-common-dir` and cite `lib/roots.sh`. Three
   implementations of this rule have already drifted apart once — two used
   `--show-toplevel` and disagreed with the fourth about which directory the
   config lived in, masked only because the file happened to be identical in
   both.
