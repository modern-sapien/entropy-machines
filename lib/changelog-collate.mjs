#!/usr/bin/env node
/**
 * changelog-collate — turn fragment files into changelog sections.
 *
 * WHY THIS EXISTS
 * ---------------
 * The naive design has every commit edit the TOP of one shared changelog
 * file. Under concurrent agents editing in parallel worktrees, that file is
 * the one place their otherwise-disjoint changes collide — three parallel
 * merges landing at once is enough to guarantee a conflict there and nowhere
 * else in the diff. The usual mitigation is procedural (one session writes
 * all the entries, everyone else is forbidden to touch the file), which
 * serialises a step that should be parallel. One file per entry removes the
 * shared write instead: two agents produce two adds, and two adds never
 * conflict.
 *
 * ORDER
 * -----
 * Not the filename. A fragment authored earlier on a branch that merges
 * after one authored later belongs *after* it in history, so the order of
 * record is the order the fragments entered git — `git log --diff-filter=A`
 * over the fragment directory, newest first, which is exactly the order the
 * file reads in. Fragments that are not committed yet are the in-flight
 * commit: they sort to the top by filename, descending, and render with a
 * `HEAD` hash. Filename order is the fallback when git is unavailable.
 *
 * STATUS
 * ------
 * The ⏳/✅ marker in the `##` heading comes from the fragment's `status:`
 * line, not from the collated file. A project may wire an external hook to
 * flip the newest pending fragment's status and re-collate — after a QA pass,
 * say, or a CI job — but that integration is optional and lives outside this
 * script; nothing here assumes it exists or names what triggers it. Status is
 * deliberately NOT derived from commit ancestry against some checkpoint file:
 * a repo that cherry-picks onto its main branch rewrites hashes, and an
 * ancestry-derived marker would silently reset.
 *
 * MODES
 *   (none)    print the collated block to stdout
 *   --write   splice it into the collated file between the collation markers
 *   --init    insert the markers if absent, then --write
 *   --check   validate every fragment; with markers present, also verify the
 *             collated region in the collated file is not stale
 *
 * --write refuses to act when the markers are absent. That keeps the change
 * inert until someone runs --init once on purpose: the collated file is the
 * file this whole exercise is about not touching by surprise.
 *
 * Fragment directory, collated-file path and the marker text all come from
 * entropy.json's `changelog.*` keys — see docs/CONFIG.md.
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig } from './config.mjs';

const config = loadConfig();
const REPO_ROOT = config._root;
const FRAGMENT_DIR = path.join(REPO_ROOT, config.changelog.fragmentDir);
const FRAGMENT_PREFIX = `${config.changelog.fragmentDir}/`;
const CHANGELOG = path.join(REPO_ROOT, config.changelog.collatedFile);

const CHANGELOG_REL = config.changelog.collatedFile;
const COLLATE_CMD = config.changelog.collateCmd ?? 'node lib/changelog-collate.mjs';

const BEGIN = config.changelog.marker;
if (!BEGIN.includes('BEGIN')) {
  throw new Error(
    `changelog.marker (${JSON.stringify(BEGIN)}) must contain the literal text "BEGIN" — ` +
      'the matching end marker is derived by swapping it for "END".',
  );
}
const END = BEGIN.replace('BEGIN', 'END');

const STATUS_MARKER = {
  pending: '⏳',
  verified: '✅',
  broken: '🚫',
};

/** Fragment files, in plain descending filename order. `_`-prefixed are skipped. */
function listFragments() {
  if (!fs.existsSync(FRAGMENT_DIR)) return [];
  return fs
    .readdirSync(FRAGMENT_DIR)
    .filter((n) => n.endsWith('.md') && !n.startsWith('_') && !n.startsWith('.'))
    .sort()
    .reverse();
}

/**
 * Parse the `---`-delimited header. Values may be quoted; a `#` inside a value
 * is not a comment (titles contain them). Returns {header, body}.
 */
function parseFragment(name, text) {
  const lines = text.split('\n');
  let i = 0;
  while (i < lines.length && lines[i].trim() === '') i++;
  if (lines[i]?.trim() !== '---') {
    throw new Error(`${name}: expected a \`---\` header block on the first non-blank line`);
  }
  i++;
  const header = {};
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '---') {
      i++;
      break;
    }
    const m = /^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/.exec(line);
    if (!m) throw new Error(`${name}: unparseable header line ${i + 1}: ${JSON.stringify(line)}`);
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
      (value.startsWith("'") && value.endsWith("'") && value.length > 1)
    ) {
      value = value.slice(1, -1);
    }
    header[m[1]] = value;
  }
  return { header, body: lines.slice(i).join('\n').trim() };
}

function validate(name, header, body) {
  const problems = [];
  for (const key of ['status', 'date', 'title']) {
    if (!header[key]) problems.push(`missing \`${key}:\``);
  }
  if (header.status && !STATUS_MARKER[header.status]) {
    problems.push(
      `status \`${header.status}\` is not one of ${Object.keys(STATUS_MARKER).join(' / ')}`,
    );
  }
  if (header.date && !/^\d{4}-\d{2}-\d{2}$/.test(header.date)) {
    problems.push(`date \`${header.date}\` is not YYYY-MM-DD`);
  }
  if (!body) problems.push('empty body');
  return problems.map((p) => `${name}: ${p}`);
}

/**
 * name -> short hash of the commit that ADDED it. Absent for fragments that
 * are not committed yet. Insertion order of the returned Map is the git order:
 * newest commit first.
 */
function gitAddOrder() {
  const order = new Map();
  let out;
  try {
    out = execFileSync(
      'git',
      [
        '-C',
        REPO_ROOT,
        'log',
        '--diff-filter=A',
        '--format=%h',
        '--name-only',
        '--',
        FRAGMENT_PREFIX,
      ],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    );
  } catch {
    return order; // not a repo, or git missing — filename order is the fallback
  }
  let hash = null;
  for (const raw of out.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (/^[0-9a-f]{7,40}$/.test(line) && !line.endsWith('.md')) {
      hash = line;
      continue;
    }
    if (line.startsWith(FRAGMENT_PREFIX)) {
      const name = line.slice(FRAGMENT_PREFIX.length);
      if (!order.has(name)) order.set(name, hash);
    }
  }
  return order;
}

function collectEntries() {
  const byFilename = listFragments();
  const added = gitAddOrder();
  const problems = [];
  const parsed = new Map();

  for (const name of byFilename) {
    const text = fs.readFileSync(path.join(FRAGMENT_DIR, name), 'utf8');
    try {
      const { header, body } = parseFragment(name, text);
      problems.push(...validate(name, header, body));
      parsed.set(name, { name, header, body });
    } catch (err) {
      problems.push(String(err.message));
    }
  }

  // Uncommitted first (filename-descending), then committed in git order.
  const uncommitted = byFilename.filter((n) => !added.has(n));
  const committed = [...added.keys()].filter((n) => parsed.has(n));

  const entries = [];
  for (const name of uncommitted) {
    if (parsed.has(name)) entries.push({ ...parsed.get(name), hash: 'HEAD' });
  }
  for (const name of committed) {
    entries.push({ ...parsed.get(name), hash: added.get(name) ?? 'HEAD' });
  }
  return { entries, problems };
}

function render(entries) {
  if (entries.length === 0) return '';
  return entries
    .map((e) => {
      const marker = STATUS_MARKER[e.header.status] ?? '⏳';
      const issue = e.header.issue ? ` (${e.header.issue})` : '';
      const title = e.header.title.endsWith(issue) ? e.header.title : `${e.header.title}${issue}`;
      return `## ${marker} ${e.hash} — ${e.header.date} — ${title}\n\n${e.body}\n\n---\n`;
    })
    .join('\n');
}

function readChangelog() {
  return fs.readFileSync(CHANGELOG, 'utf8');
}

function spliceInto(text, block) {
  const b = text.indexOf(BEGIN);
  const e = text.indexOf(END);
  if (b === -1 || e === -1 || e < b) return null;
  const before = text.slice(0, b + BEGIN.length);
  const after = text.slice(e);
  return `${before}\n\n${block}${block ? '\n' : ''}${after}`;
}

/** Insert an empty marker pair immediately above the first `## ` section. */
function insertMarkers(text) {
  if (text.includes(BEGIN)) return text;
  const lines = text.split('\n');
  let at = lines.findIndex((l) => l.startsWith('## '));
  if (at === -1) at = lines.length;
  const head = lines.slice(0, at);
  // Drop the trailing `---` rule the old header ended with; the last collated
  // entry supplies its own, so keeping both would double the rule.
  while (head.length && head[head.length - 1].trim() === '') head.pop();
  if (head.length && head[head.length - 1].trim() === '---') head.pop();
  while (head.length && head[head.length - 1].trim() === '') head.pop();
  return [...head, '', BEGIN, '', '---', '', END, '', ...lines.slice(at)].join('\n');
}

function main() {
  const args = process.argv.slice(2);
  const mode = args.find((a) => a.startsWith('--')) ?? '';
  const { entries, problems } = collectEntries();

  if (problems.length) {
    for (const p of problems) console.error(`changelog: ${p}`);
    if (mode === '--check') {
      console.error(`\nchangelog: ${problems.length} malformed fragment(s). See ${config.changelog.fragmentDir}/_template.md.`);
      process.exit(1);
    }
    process.exit(1);
  }

  const block = render(entries);

  if (mode === '--check') {
    const text = fs.existsSync(CHANGELOG) ? readChangelog() : '';
    if (!text.includes(BEGIN)) {
      console.log(
        `changelog: ${entries.length} fragment(s) OK. ${CHANGELOG_REL} has no collation markers yet (run --init when you want them).`,
      );
      return;
    }
    // Compare with heading hashes normalised away. A fragment added by the
    // commit under test renders as `HEAD` while it is uncommitted and as its
    // real short hash once it lands, so a literal comparison reports "stale"
    // for every commit that adds an entry — a state the author cannot fix,
    // because the hash does not exist until after the commit does. Found by
    // dogfooding this on its own landing commit. Content drift is the thing
    // worth guarding; hash resolution is bookkeeping that `--write` does at
    // build time.
    const unhash = (s) => s.replace(/^## (✅|⏳|🚫) [0-9a-f]{7,40} —/gm, '## $1 <hash> —')
                           .replace(/^## (✅|⏳|🚫) HEAD —/gm, '## $1 <hash> —');
    const want = spliceInto(text, block);
    if (unhash(want) !== unhash(text)) {
      console.error(
        `changelog: ${CHANGELOG_REL} collated region is stale. Run \`${COLLATE_CMD}\`.`,
      );
      process.exit(1);
    }
    console.log(`changelog: ${entries.length} fragment(s) OK, collated region current.`);
    return;
  }

  if (mode === '--write' || mode === '--init') {
    let text = readChangelog();
    if (!text.includes(BEGIN)) {
      if (mode !== '--init') {
        console.error(
          `changelog: ${CHANGELOG_REL} has no collation markers. Run \`${COLLATE_CMD} --init\` once to add them (this is the only edit that touches the existing file).`,
        );
        process.exit(2);
      }
      text = insertMarkers(text);
    }
    const next = spliceInto(text, block);
    if (next === null) {
      console.error('changelog: markers present but malformed (END before BEGIN?).');
      process.exit(2);
    }
    if (next !== readChangelog()) {
      fs.writeFileSync(CHANGELOG, next);
      console.log(`changelog: wrote ${entries.length} fragment(s) into ${CHANGELOG_REL}.`);
    } else {
      console.log(`changelog: ${CHANGELOG_REL} already current (${entries.length} fragment(s)).`);
    }
    return;
  }

  process.stdout.write(block);
}

main();
