#!/usr/bin/env node
/**
 * changelog-new — create one changelog fragment, print its path.
 *
 *   node lib/changelog-new.mjs -- "fix(scope): what changed" issue-id
 *
 * The filename is <YYYYMMDD>-<HHMMSS>-<slug>-<6 hex>.md.
 *
 * The timestamp is for ordering and for reading the directory by eye. The six
 * random hex characters are what make it collision-proof, and they are the
 * point: two agents in two worktrees cannot see each other, so anything
 * derived from the directory (a sequence number) is a race, and anything
 * derived from the clock alone collides at second resolution. Randomness is
 * the only per-write unique value available without coordination. Ordering
 * does not depend on it — the collator orders by the commit that added the
 * file, and falls back to filename only for fragments not yet committed.
 *
 * Fragment directory is config.json's `changelog.fragmentDir` (default
 * `changelog.d`) — see docs/CONFIG.md.
 */

import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig } from './config.mjs';

const config = loadConfig();
const REPO_ROOT = config._root;
const FRAGMENT_DIR = path.join(REPO_ROOT, config.changelog.fragmentDir);

const [, , titleArg, issueArg] = process.argv;
if (!titleArg) {
  console.error('usage: node lib/changelog-new.mjs -- "type(scope): subject" [issue-id]');
  process.exit(2);
}

const now = new Date();
const p2 = (n) => String(n).padStart(2, '0');
const day = `${now.getFullYear()}${p2(now.getMonth() + 1)}${p2(now.getDate())}`;
const time = `${p2(now.getHours())}${p2(now.getMinutes())}${p2(now.getSeconds())}`;
const date = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-${p2(now.getDate())}`;

const slugSource = issueArg || titleArg;
const slug =
  slugSource
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48) || 'entry';

const name = `${day}-${time}-${slug}-${randomBytes(3).toString('hex')}.md`;
const file = path.join(FRAGMENT_DIR, name);

fs.mkdirSync(FRAGMENT_DIR, { recursive: true });
fs.writeFileSync(
  file,
  `---
status: pending
date: ${date}
issue: ${issueArg ?? ''}
title: ${JSON.stringify(titleArg)}
---

TODO: what changed and why.

Verification: TODO — what you ran, with the numbers.
`,
);

console.log(path.relative(REPO_ROOT, file));
