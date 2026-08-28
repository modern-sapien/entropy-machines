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
protected paths, changelog disabled) and seeds issue `q-1`, "Orient the
factory to this repo." The starter file is deliberately incomplete — it does
not guess at a suite command or anything else it hasn't verified, because a
fabricated suite is worse than an empty list — completing it is what `q-1`
is for. `bin/init` refuses to overwrite an existing `entropy.json` unless you
pass `--force`.

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
    "scheduler": "launchd",          // "launchd" | "systemd"
    "label": "com.entropy.drain",
    "agent": { "cmd": ["claude", "-p"] }
  }
}
```

## Rules for contributors

1. A new hardcoded path, command, or product noun in `bin/` or `lib/` is a bug.
   Add a config key instead.
2. Every key must have a working default, or the harness must refuse with a
   message naming the missing key. Silent fallback is what made the original
   un-portable.
3. `entropy.json` is read once per process and passed down. Do not re-read it
   from library code.
