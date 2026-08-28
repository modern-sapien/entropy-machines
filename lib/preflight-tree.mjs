#!/usr/bin/env node
/**
 * Refuse to run a suite from a tree that cannot resolve its own dependencies.
 * (i-a-worktree-s-empty-node-modules)
 *
 * THE FAILURE THIS EXISTS FOR. A git worktree has no `node_modules`. Node then
 * walks UP from the worktree looking for one — and on 2026-08-17 a dispatched
 * agent's `npm run e2e` resolved `playwright` out of a SIBLING agent's worktree
 * and ran with that worktree as cwd. It tested someone else's code and reported
 * the result as its own. Green, confident, wrong. The agent caught it only by
 * watching the output; nothing in the tooling would have told it, or the
 * session landing its work.
 *
 * That is worse than the already-known symptom (an empty ENOENT from a missing
 * .bin/tsc), because a spurious red gets investigated and a spurious green does
 * not. A worktree isolates the filesystem; it does not isolate node resolution.
 *
 * THE CHECK. Every package a suite spawns must be present under THIS tree's own
 * node_modules. A symlink to the main checkout satisfies that and is the fix we
 * recommend — what must never happen is no entry at all, because that is the
 * only case where resolution leaves the tree.
 *
 * Silent and fast on the happy path: one `git rev-parse` and four `stat`s.
 */
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

// Anything a suite spawns or imports from the tree root. Keep this list to
// things whose absence produces a WRONG ANSWER rather than a clean crash.
const NEEDED = ['playwright', 'vitest', 'typescript', 'esbuild'];

function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}

let root;
try {
  root = git('rev-parse', '--show-toplevel');
} catch {
  process.exit(0); // not a git checkout — nothing to be confused about
}

const nodeModules = join(root, 'node_modules');
const missing = existsSync(nodeModules)
  ? NEEDED.filter((p) => !existsSync(join(nodeModules, p)))
  : NEEDED;

if (missing.length === 0) process.exit(0);

// Where a worktree should point. --git-common-dir is the MAIN checkout's .git
// even when called from a worktree, so its parent is the tree that has the
// real node_modules.
let mainTree = null;
try {
  const commonDir = git('rev-parse', '--path-format=absolute', '--git-common-dir');
  const candidate = dirname(commonDir);
  if (candidate !== root && existsSync(join(candidate, 'node_modules'))) mainTree = candidate;
} catch {
  /* older git without --path-format; the message still works without it */
}

const lines = [
  '',
  'preflight: this tree cannot resolve its own dependencies — refusing to run.',
  '',
  `  tree:    ${root}`,
  `  missing: ${missing.join(', ')}${existsSync(nodeModules) ? ' (node_modules exists but is incomplete)' : ' (no node_modules at all)'}`,
  '',
  '  Node would search UPWARD from here and can land in another worktree, which',
  '  means testing someone else\'s code and reporting it as yours. That has',
  '  happened once already (i-a-worktree-s-empty-node-modules).',
  '',
];
lines.push(
  mainTree
    ? `  Fix:  ln -s ${JSON.stringify(join(mainTree, 'node_modules'))} ${JSON.stringify(nodeModules)}`
    : '  Fix:  symlink or install node_modules in this tree (npm ci).'
);
lines.push('');
console.error(lines.join('\n'));
process.exit(1);
