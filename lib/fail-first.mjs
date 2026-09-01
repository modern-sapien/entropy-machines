#!/usr/bin/env node
/**
 * fail-first — a commit that claims a regression guard must SHOW the guard red
 * against the unfixed code.
 *
 * WHAT IT PROVES, AND WHAT IT DOES NOT
 * ------------------------------------
 * It proves one thing: the named test passes at the commit and does NOT pass
 * once the commit's fix is reverted out from under it. That is the "fail-first"
 * ritual, done by machine instead of by an agent remembering to do it and a
 * human re-running it by hand.
 *
 * It does NOT read the assertion. A test can be red for the wrong reason and
 * still satisfy this job — and, more importantly, an assertion that is vacuous
 * in a way unrelated to the fix will sail through. The real case this cannot
 * catch: a config-validation guard whose nested-key check matched a leaf name
 * ANYWHERE in the document, so an unrelated sibling field satisfied a check
 * meant for a specific nested key. It reported most of the missing keys, hid
 * one of the exact cases it was written for, and it would have gone red on
 * the unfixed file all the same. Nothing here would have noticed. Reading the
 * assertion is still a human's job.
 *
 * Two further limits, stated so nobody reads more into a green run:
 *
 *   - A commit that introduces the code and its test together often has no
 *     "unfixed" state the test can even COMPILE against. Reverting the source
 *     breaks the build; the run is red for a reason that proves nothing. That
 *     is reported as `inconclusive`, not as a pass — narrow `guard-revert` to
 *     specific hunks, or take the escape hatch.
 *   - Build-error detection is a short list of markers (see BUILD_MARKERS).
 *     A compile failure this list misses is counted as red. `guard-red:` is
 *     the fix for that: give the failure text you actually saw, and the
 *     reverted run has to produce it.
 *
 * DECLARATION
 * -----------
 * A commit declares a guard in the changelog fragment it already adds (the
 * fragment directory is config.json's `changelog.fragmentDir`). It is
 * opt-in and there is no inference from the diff: intent cannot be read off
 * a patch, and a job that guesses produces false positives on ordinary
 * refactors. A job that cries wolf gets ignored, which is worse than no job.
 * A commit that declares nothing is a silent pass — most commits are not
 * guards.
 *
 *   ---
 *   status: pending
 *   date: 2026-08-05
 *   issue: i-example
 *   title: "fix(parser): flagKeys mapped a flag no command declares"
 *   guard-test: go test ./internal/config -run '^TestFlagKeysAreRealFlags$'
 *   guard-cwd: backend
 *   guard-revert: backend/internal/config/resolve.go
 *   guard-red: cmd/app/run.go declares no such flag
 *   ---
 *
 *   guard-test    (required to claim a guard) the command, run through `sh -c`.
 *                 Point it at ONE test. It is run twice.
 *   guard-cwd     directory to run it in, relative to the repo root. Default `.`.
 *   guard-revert  whitespace-separated paths whose change this commit made and
 *                 that get reverted. Default: every path the commit touched
 *                 that is not a test, a doc, or a fragment. A path may name
 *                 hunks — `path#1,3` — numbered as they appear in
 *                 `git show <sha> -- <path>`, for when reverting the whole file
 *                 takes the test's own scaffolding with it.
 *   guard-red     text the reverted run's output must contain. Optional and
 *                 worth writing: it is what separates "the test failed" from
 *                 "the tree stopped compiling".
 *   guard-skip    a reason. The escape hatch — same shape as SKIP_CHANGELOG=1:
 *                 explicit, recorded in the repo, and greppable later. One form
 *                 only, unlike changelog-guard's two, because there is only one
 *                 caller and it reads the fragment.
 *
 * WHERE A BAD DECLARATION IS CAUGHT
 * ---------------------------------
 * `--lint` reads the fragments on disk and nothing else, so it can only decide
 * whether a declaration is WELL-FORMED: known keys, a spec that parses. It has
 * no commit, so it cannot know whether `guard-revert: src/shrared/x.ts` names a
 * real path — a misspelling, or a path renamed by a later commit, lints clean
 * forever and is only found when someone runs `--range` over that commit, which
 * for a local-first repo may be never. A batch of fragments shipped an
 * unrunnable spec that way once, all lint-clean, because lint had validated
 * the key names and never looked at whether the value pointed anywhere real.
 *
 * So the half that needs a commit lives in `--scan`, which already walks the
 * range: for every guard a commit declares, `resolveRevertSpecs` says whether
 * the spec parses, names anything at all, and names only paths that commit
 * actually changes. That is still git-and-node-builtins cheap, it runs before
 * anything is installed, and it fails AT the commit that introduced the bad
 * path. `checkGuard` calls the same function — the point is not to move the
 * check out of the per-commit run, it is to reach it without one.
 *
 * What it still cannot say: that the path is the RIGHT one. A guard-revert
 * naming a real file the commit changed but not the file carrying the fix is
 * well-formed, runnable, and wrong; only the two runs show that, as `not-red`.
 *
 * HOW THE REVERT IS DONE
 * ----------------------
 * The commit's tree is extracted to a temp directory with `git archive` — the
 * repo is never mutated, no worktree is registered, nothing is checked out.
 * Whole-file reverts write the parent's blob (or delete a file the commit
 * added), so they cannot fail to apply. Hunk selection is the only form that
 * can: it reverse-applies a filtered patch with `git apply -R`, and a refusal
 * is reported as `revert-unclean` rather than swallowed.
 *
 * MODES
 *   --commit <sha>            check one commit
 *   --range A..B              check every non-merge commit in the range
 *   --scan --range A..B       print has_guards=true|false; also lints every
 *                             fragment's guard-* keys AND every guard-revert
 *                             path in the range against the commit that
 *                             declared it (see below). Git and node builtins
 *                             only — this is the cheap CI gate that decides
 *                             whether the expensive setup runs at all. Exits
 *                             non-zero on a declaration git alone can already
 *                             call unrunnable.
 *   --lint                    lint guard-* keys in all fragments, nothing else
 *   --try <sha>               ad-hoc run against a commit, taking the
 *                             declaration from flags instead of a fragment:
 *                             --test / --cwd / --revert / --red. For proving a
 *                             guard before you commit it.
 */

import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, matchesAny } from './config.mjs';

/**
 * FAIL_FIRST_REPO points the whole script at another repository. It exists for
 * one reason: a test can build a throwaway repo with a real commit that really
 * declares a guard, and run this script against it. Without the seam the only
 * thing exercisable end to end is `--try`, and the path CI actually takes —
 * fragment -> declaration -> revert -> two runs -> exit code — would ship
 * untested.
 */
export const REPO_ROOT = process.env.FAIL_FIRST_REPO
  ? path.resolve(process.env.FAIL_FIRST_REPO)
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/**
 * config.json, loaded once against REPO_ROOT rather than the process cwd —
 * this file's own REPO_ROOT seam exists precisely so it can be pointed at a
 * repo other than the one it lives in, and the config it reads has to follow
 * that same seam or a test repo would be checked against the harness's own
 * settings instead of its own.
 */
const CONFIG = loadConfig({ cwd: REPO_ROOT });

const FRAGMENT_PREFIX = 'changelog.d/';
const DEFAULT_TIMEOUT_MS = 20 * 60 * 1000;

/** Known guard keys. Anything else starting with `guard` is a typo, not a feature. */
export const GUARD_KEYS = ['guard-test', 'guard-cwd', 'guard-revert', 'guard-red', 'guard-skip'];

/**
 * Substrings that mean the run never got as far as running the test. Narrow on
 * purpose: a false positive here turns a genuine red into `inconclusive` and
 * blocks a correct commit. A false negative counts a compile error as red,
 * which `guard-red:` is there to close.
 *
 * Sourced from config.json's `guards.buildFailureMarkers` — empty by default,
 * per docs/CONFIG.md's rule that a default must be inert rather than a guess
 * at a toolchain. What a "tree didn't build" message looks like is specific
 * to one language's compiler and one project's test runner; a project names
 * its own (e.g. `Cannot find module` for a Node resolver, `no required module
 * provides package` for `go build`) instead of inheriting someone else's.
 */
export const BUILD_MARKERS = CONFIG.guards.buildFailureMarkers;

/**
 * Paths whose revert would take the guard itself away, making the check
 * vacuous. Sourced from config.json's `guards.testPathPatterns` — this file
 * no longer guesses a test-file convention (it used to assume `tests/`,
 * `_test.go` and `.test.ts`/`.spec.js` specifically); a project names its own.
 */
export function isTestPath(p) {
  return matchesAny(CONFIG.guards.testPathPatterns, p);
}

/**
 * Paths that are not code, so reverting them proves nothing about a fix.
 * The fragment directory is always excluded — a guard reverting its own
 * declaration is a different bug than the one this file is checking for.
 * Everything else is config.json's `guards.nonCodePatterns`.
 */
export function isNonCodePath(p) {
  return p.startsWith(FRAGMENT_PREFIX) || matchesAny(CONFIG.guards.nonCodePatterns, p);
}

/** Default revert set: what the commit changed, minus tests, docs and fragments. */
export function deriveRevertPaths(changedPaths) {
  return changedPaths.filter((p) => !isTestPath(p) && !isNonCodePath(p));
}

/** `a/b.go c/d.go#1,3` -> [{path:'a/b.go',hunks:null},{path:'c/d.go',hunks:[1,3]}] */
export function parseRevertSpec(spec) {
  const out = [];
  for (const token of spec.split(/\s+/).filter(Boolean)) {
    const hash = token.indexOf('#');
    if (hash === -1) {
      // A comma here is always a mistake, and it used to be a SILENT one: this
      // spec is whitespace-separated, the comma separates HUNKS inside
      // `path#1,3`, so `guard-revert: a.ts,b.ts` parsed as one path literally
      // named "a.ts,b.ts" and the commit check then reported it as a path the
      // commit does not change. Six fragments shipped that way on 2026-08-25
      // and --lint passed all of them, because it validated key names and never
      // looked inside the value. Caught here so both --lint and the per-commit
      // path reject it, and the message names the fix.
      if (token.includes(',')) {
        throw new Error(
          `revert spec ${JSON.stringify(token)} contains a comma: paths are separated by ` +
            `SPACES, and a comma only separates hunk numbers after a '#' (path#1,3). ` +
            `Write: ${token.split(',').filter(Boolean).join(' ')}`
        );
      }
      out.push({ path: token, hunks: null });
      continue;
    }
    const p = token.slice(0, hash);
    const rest = token.slice(hash + 1);
    const hunks = rest
      .split(',')
      .filter(Boolean)
      .map((n) => {
        if (!/^\d+$/.test(n)) throw new Error(`bad hunk number ${JSON.stringify(n)} in ${token}`);
        return Number(n);
      });
    if (!p) throw new Error(`revert spec ${JSON.stringify(token)} has no path`);
    if (hunks.length === 0) throw new Error(`revert spec ${JSON.stringify(token)} names no hunks`);
    out.push({ path: p, hunks });
  }
  return out;
}

/**
 * Settle a declaration's revert set against the paths a commit changed.
 * Returns `{specs}` when it is runnable, or `{problem:{code,detail}}` when git
 * alone can already say it is not.
 *
 * Everything here needs the commit's name-only diff and nothing else — no
 * checkout, no archive, no toolchain — which is why both `--scan` and
 * `checkGuard` call it. Keeping the two in one function is the point: they used
 * to disagree about when a spec was usable, and the cheap gate that runs on
 * every push was the one that did not look.
 */
export function resolveRevertSpecs(decl, changed) {
  let specs;
  try {
    specs = decl.revert
      ? parseRevertSpec(decl.revert)
      : deriveRevertPaths(changed).map((p) => ({ path: p, hunks: null }));
  } catch (err) {
    return { problem: { code: 'bad-revert-spec', detail: err.message } };
  }

  if (specs.length === 0) {
    return {
      problem: {
        code: 'revert-empty',
        detail:
          'nothing to revert: every path this commit touches is a test, a doc or a fragment. ' +
          'Name the fix explicitly with guard-revert, or take guard-skip with a reason.',
      },
    };
  }

  for (const { path: p } of specs) {
    if (!changed.includes(p)) {
      return {
        problem: {
          code: 'bad-revert-spec',
          detail: `guard-revert names ${p}, which this commit does not change`,
        },
      };
    }
  }
  return { specs };
}

/**
 * Keep only the numbered hunks of a single-file patch. Hunks are numbered in
 * the order `git show` prints them, 1-based.
 */
export function filterHunks(patch, wanted) {
  const lines = patch.split('\n');
  const firstHunk = lines.findIndex((l) => l.startsWith('@@'));
  if (firstHunk === -1) {
    throw new Error('patch has no @@ hunks (binary, rename or mode-only change?)');
  }
  const head = lines.slice(0, firstHunk);
  const hunks = [];
  let current = null;
  for (const line of lines.slice(firstHunk)) {
    if (line.startsWith('@@')) {
      if (current) hunks.push(current);
      current = [line];
    } else if (current) {
      current.push(line);
    }
  }
  if (current) hunks.push(current);

  for (const n of wanted) {
    if (n < 1 || n > hunks.length) {
      throw new Error(`hunk ${n} does not exist (${hunks.length} hunk(s) in this file's diff)`);
    }
  }
  const kept = wanted
    .slice()
    .sort((a, b) => a - b)
    .map((n) => hunks[n - 1].join('\n'));
  return `${head.join('\n')}\n${kept.join('\n')}`.replace(/\n*$/, '\n');
}

/**
 * What a reverted run's result means.
 *   exit 0                          -> not-red: the guard proves nothing
 *   non-zero, guard-red set+missing -> wrong-red
 *   non-zero, build marker, no red  -> inconclusive
 *   non-zero                        -> red
 */
export function classifyReverted({ code, output, red }) {
  if (code === 0) return { outcome: 'not-red' };
  if (red) {
    return output.includes(red) ? { outcome: 'red' } : { outcome: 'wrong-red', needle: red };
  }
  const marker = BUILD_MARKERS.find((m) => output.includes(m));
  if (marker) return { outcome: 'inconclusive', marker };
  return { outcome: 'red' };
}

/** Parse a `---`-delimited fragment header. Same shape changelog-collate reads. */
export function parseHeader(name, text) {
  const lines = text.split('\n');
  let i = 0;
  while (i < lines.length && lines[i].trim() === '') i++;
  if (lines[i]?.trim() !== '---') {
    throw new Error(`${name}: expected a \`---\` header block on the first non-blank line`);
  }
  i++;
  const header = {};
  for (; i < lines.length; i++) {
    if (lines[i].trim() === '---') break;
    const m = /^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/.exec(lines[i]);
    if (!m) continue; // collate is the parser of record for malformed headers
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
      (value.startsWith("'") && value.endsWith("'") && value.length > 1)
    ) {
      value = value.slice(1, -1);
    }
    header[m[1]] = value;
  }
  return header;
}

/**
 * Turn a fragment header into a declaration.
 *   {kind:'none'}  no claim -> silent pass
 *   {kind:'skip', reason}
 *   {kind:'guard', test, cwd, revert, red}
 * Throws on a header that claims something it cannot mean.
 */
export function readDeclaration(name, header) {
  // Case-sensitive on purpose: `Guard-Test:` would otherwise parse as a header
  // key, be looked up under the lowercase name, come back undefined, and the
  // commit would pass as claiming nothing. A claim that silently does not exist
  // is the failure this whole file is about.
  const unknown = Object.keys(header).filter((k) => /^guard/i.test(k) && !GUARD_KEYS.includes(k));
  if (unknown.length) {
    throw new Error(
      `${name}: unknown key(s) ${unknown.join(', ')} — did you mean one of ${GUARD_KEYS.join(', ')}?`,
    );
  }
  const skip = header['guard-skip'];
  const test = header['guard-test'];
  if (skip !== undefined) {
    if (!skip.trim()) throw new Error(`${name}: guard-skip needs a reason, not an empty value`);
    return { kind: 'skip', reason: skip.trim(), test: test?.trim() || null };
  }
  if (!test) {
    for (const k of ['guard-revert', 'guard-red', 'guard-cwd']) {
      if (header[k]) throw new Error(`${name}: ${k} without guard-test — nothing would run it`);
    }
    return { kind: 'none' };
  }
  if (!test.trim()) throw new Error(`${name}: guard-test is empty`);
  return {
    kind: 'guard',
    test: test.trim(),
    cwd: (header['guard-cwd'] || '.').trim(),
    revert: header['guard-revert']?.trim() || null,
    red: header['guard-red']?.trim() || null,
  };
}

// ---------------------------------------------------------------------------
// git + process plumbing
// ---------------------------------------------------------------------------

function git(args, opts = {}) {
  return execFileSync('git', ['-C', REPO_ROOT, ...args], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    ...opts,
  });
}

function gitOk(args) {
  const r = spawnSync('git', ['-C', REPO_ROOT, ...args], { encoding: 'utf8' });
  return r.status === 0;
}

function shortLog(sha) {
  return git(['log', '-1', '--format=%h %s', sha]).trim();
}

function changedPaths(sha) {
  return git(['show', '--pretty=format:', '--name-only', '--no-renames', '--diff-filter=ACMRD', sha])
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
}

/** Fragments this commit ADDED, as [{name, header}]. */
function addedFragments(sha) {
  const names = git([
    'show',
    '--pretty=format:',
    '--name-only',
    '--diff-filter=A',
    sha,
    '--',
    FRAGMENT_PREFIX,
  ])
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.endsWith('.md') && !path.basename(l).startsWith('_'));

  return names.map((name) => ({
    name,
    header: parseHeader(name, git(['show', `${sha}:${name}`])),
  }));
}

/**
 * Does `p`, at this commit, define a test the guard command names?
 *
 * Pulls the test identifiers out of guard-test — Go's `-run '^TestFoo$'` and
 * vitest/jest path arguments both end up as bare words — and looks for a
 * definition of one inside the file. Deliberately conservative: when the
 * command names nothing recognisable, or the blob cannot be read, it answers
 * TRUE, so an unparseable declaration keeps the old blanket rejection rather
 * than silently permitting a vacuous revert.
 */
function definesGuardTest(sha, p, testCmd) {
  // A path argument to the runner is the guard's own file, plainly.
  if (testCmd.includes(p) || testCmd.includes(path.basename(p))) return true;
  const names = [...testCmd.matchAll(/\b(Test[A-Za-z0-9_]+)\b/g)].map((m) => m[1]);
  if (names.length === 0) return true;
  let blob;
  try {
    blob = git(['show', `${sha}:${p}`]);
  } catch {
    return true;
  }
  return names.some((n) => new RegExp(`func\\s+${n}\\s*\\(`).test(blob));
}

function extractTree(sha, dest) {
  fs.mkdirSync(dest, { recursive: true });
  const tar = path.join(dest, '..', `tree-${process.pid}.tar`);
  git(['archive', '--format=tar', '-o', tar, sha]);
  execFileSync('tar', ['-xf', tar, '-C', dest]);
  fs.rmSync(tar, { force: true });
  // vitest and anything else node-side needs the deps; the archive has none.
  const deps = path.join(REPO_ROOT, 'node_modules');
  if (fs.existsSync(deps) && !fs.existsSync(path.join(dest, 'node_modules'))) {
    fs.symlinkSync(deps, path.join(dest, 'node_modules'), 'dir');
  }
  regenerate(dest);
}

/**
 * Run `generate.cmd` from config.json inside the extracted tree.
 *
 * WHY THIS STEP EXISTS AT ALL. `git archive` carries TRACKED files only, and a
 * project's generated modules are usually gitignored on purpose. Anything
 * importing one fails to RESOLVE inside the archive, which surfaces here as
 * `control-not-green` — on a guard that passes perfectly well in the working
 * tree.
 *
 * That is worse than it sounds. The failure is indistinguishable from "your
 * test is broken", so the natural response is to mark the guard skipped — and
 * then every guard whose module graph reaches a generated file drifts into
 * being skipped, one at a time, each for a locally reasonable reason. The job
 * stays green while quietly covering less and less. This was found exactly
 * that way: a guard whose only sin was importing a generated module.
 *
 * Best-effort by design: a project with no generate.cmd, or one whose generate
 * fails, still gets the run — it just fails the same way it would have anyway.
 * A regeneration step that can veto the whole job would be a worse trade.
 */
function regenerate(dest) {
  if (!fs.existsSync(path.join(dest, 'package.json'))) return;
  try {
    execFileSync('npm', ['run', 'gen', '--silent'], {
      cwd: dest, stdio: 'ignore', timeout: 120_000,
    });
  } catch {
    // leave the tree as-extracted; the run below reports the real failure
  }
}

/**
 * Undo the commit's change to the given paths inside `tree`.
 * Whole-file: write the parent's blob, or delete a file the commit added.
 * Hunk-selected: reverse-apply a filtered patch, which can refuse.
 */
function applyRevert(sha, tree, specs) {
  const parent = `${sha}^`;
  for (const { path: rel, hunks } of specs) {
    const target = path.join(tree, rel);
    if (hunks) {
      const patch = git(['diff', '--no-renames', '--no-color', parent, sha, '--', rel]);
      if (!patch.trim()) throw new Error(`${rel}: this commit does not change it`);
      const filtered = filterHunks(patch, hunks);
      const file = path.join(tree, `.fail-first-${path.basename(rel)}.patch`);
      fs.writeFileSync(file, filtered);
      const r = spawnSync('git', ['apply', '-R', '--verbose', file], {
        cwd: tree,
        encoding: 'utf8',
      });
      fs.rmSync(file, { force: true });
      if (r.status !== 0) {
        throw new Error(`revert-unclean: git apply -R refused ${rel}#${hunks.join(',')}\n${r.stderr}`);
      }
      continue;
    }
    if (gitOk(['cat-file', '-e', `${parent}:${rel}`])) {
      const before = git(['show', `${parent}:${rel}`], { encoding: 'buffer' });
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, before);
    } else {
      fs.rmSync(target, { force: true }); // the commit added it
    }
  }
}

function runTest(cmd, cwd, timeout) {
  const r = spawnSync('sh', ['-c', cmd], {
    cwd,
    encoding: 'utf8',
    timeout,
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...process.env,
      CI: process.env.CI ?? '1',
      // `go test` caches passing results, and the two runs here differ only in
      // a file the test opens at runtime. Caught during development:
      // the control run cached a PASS for the guard test and
      // the reverted run was served that cache, so the job reported `not-red`
      // for a guard that is red the moment you run it by hand. A cached green is
      // the exact failure this whole check exists to stop, so -count=1 goes in
      // the environment where the author cannot forget it. The BUILD cache is
      // untouched; only the result cache is bypassed.
      GOFLAGS: `${process.env.GOFLAGS ? `${process.env.GOFLAGS} ` : ''}-count=1`,
    },
  });
  const output = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.error && r.error.code === 'ETIMEDOUT') {
    return { code: 124, output: `${output}\nfail-first: timed out after ${timeout}ms` };
  }
  if (r.error) return { code: 125, output: `${output}\nfail-first: ${r.error.message}` };
  return { code: r.status ?? 1, output };
}

function tail(text, n = 40) {
  const lines = text.trimEnd().split('\n');
  return lines
    .slice(-n)
    .map((l) => `      | ${l}`)
    .join('\n');
}

// ---------------------------------------------------------------------------
// the check
// ---------------------------------------------------------------------------

/**
 * Run one declared guard against one commit.
 * Returns {ok, code, detail}. `code` is a stable label for the report.
 */
export function checkGuard(sha, decl, { timeout = DEFAULT_TIMEOUT_MS, log = console.log } = {}) {
  if (!gitOk(['rev-parse', '--verify', `${sha}^{commit}`])) {
    return { ok: false, code: 'no-such-commit', detail: sha };
  }
  if (!gitOk(['rev-parse', '--verify', `${sha}^^{commit}`])) {
    return { ok: false, code: 'no-parent', detail: 'a root commit has no unfixed state to revert to' };
  }

  const changed = changedPaths(sha);
  // Parse, non-empty and path-exists all live in resolveRevertSpecs, because
  // --scan reaches the same verdicts from git alone, before anything installs.
  const { specs, problem } = resolveRevertSpecs(decl, changed);
  if (problem) return { ok: false, code: problem.code, detail: problem.detail };

  for (const { path: p } of specs) {
    // Reverting the file that DEFINES the guard is vacuous — the check would
    // not be running against unfixed code, it would not be running. But this
    // rejected EVERY *_test.go, which is too blunt: when a commit's fix and its
    // sibling tests land together, those siblings reference symbols the
    // reverted source no longer has, and keeping them turns an assertion-red
    // into a compile-red. A compile-red proves the tree does not build, not
    // that the guard catches the defect.
    //
    // Found on a change whose guard test lived in one file while the revert
    // legitimately needed two OTHER test files reverted alongside it. The
    // author's by-hand A/B had done exactly that and was sound; only the
    // declaration could not express it.
    if (isTestPath(p) && definesGuardTest(sha, p, decl.test)) {
      return {
        ok: false,
        code: 'bad-revert-spec',
        detail: `guard-revert names ${p}, which defines the guard test itself — reverting the guard along with the fix makes the check vacuous`,
      };
    }
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fail-first-'));
  const tree = path.join(tmp, 'tree');
  try {
    extractTree(sha, tree);
    const cwd = path.resolve(tree, decl.cwd);
    if (!fs.existsSync(cwd)) {
      return { ok: false, code: 'bad-cwd', detail: `guard-cwd ${decl.cwd} does not exist at this commit` };
    }

    log(`      control  $ ${decl.test}`);
    const control = runTest(decl.test, cwd, timeout);
    if (control.code !== 0) {
      return {
        ok: false,
        code: 'control-not-green',
        detail:
          `the test does not pass at this commit (exit ${control.code}), so a red run below would ` +
          `prove nothing about the fix. Check the command names a real, passing test.\n${tail(control.output)}`,
      };
    }

    try {
      applyRevert(sha, tree, specs);
    } catch (err) {
      const unclean = String(err.message).startsWith('revert-unclean');
      return {
        ok: false,
        code: unclean ? 'revert-unclean' : 'bad-revert-spec',
        detail: String(err.message),
      };
    }

    log(`      reverted $ ${decl.test}   [reverted: ${specs.map((s) => (s.hunks ? `${s.path}#${s.hunks.join(',')}` : s.path)).join(' ')}]`);
    const reverted = runTest(decl.test, cwd, timeout);
    const verdict = classifyReverted({ code: reverted.code, output: reverted.output, red: decl.red });

    if (verdict.outcome === 'red') {
      return { ok: true, code: 'red', detail: `exit ${reverted.code} with the fix reverted` };
    }
    if (verdict.outcome === 'not-red') {
      return {
        ok: false,
        code: 'not-red',
        detail:
          'the test PASSES with the fix reverted. It does not guard what the commit claims — ' +
          'either it asserts something the fix did not change, or guard-revert is pointed at the wrong hunk.',
      };
    }
    if (verdict.outcome === 'wrong-red') {
      return {
        ok: false,
        code: 'wrong-red',
        detail: `red, but the output does not contain guard-red ${JSON.stringify(verdict.needle)}.\n${tail(reverted.output)}`,
      };
    }
    return {
      ok: false,
      code: 'inconclusive',
      detail:
        `red, but the output carries ${JSON.stringify(verdict.marker)} — the tree stopped building, so the ` +
        `test never ran and nothing is proven. Narrow guard-revert to hunks (path#1,3), set guard-red to the ` +
        `failure you actually saw, or take guard-skip with a reason.\n${tail(reverted.output)}`,
    };
  } finally {
    // FAIL_FIRST_KEEP=1 leaves the reverted tree on disk. The only way to see
    // what a red run was actually looking at.
    if (process.env.FAIL_FIRST_KEEP === '1') log(`      kept ${tree}`);
    else fs.rmSync(tmp, { recursive: true, force: true });
  }
}

/** Every declaration a commit makes, one per fragment it adds. */
function declarationsFor(sha) {
  return addedFragments(sha).map(({ name, header }) => ({
    name,
    decl: readDeclaration(name, header),
  }));
}

function checkCommit(sha, opts = {}) {
  const label = shortLog(sha);
  let decls;
  try {
    decls = declarationsFor(sha);
  } catch (err) {
    console.error(`fail-first: ${label}\n  ${err.message}`);
    return { checked: 0, failed: 1, skipped: 0 };
  }

  let checked = 0;
  let failed = 0;
  let skipped = 0;
  for (const { name, decl } of decls) {
    if (decl.kind === 'none') continue;
    if (decl.kind === 'skip') {
      skipped++;
      console.log(`fail-first: ${label}\n  ~ ${name}: guard-skip — ${decl.reason}`);
      continue;
    }
    checked++;
    console.log(`fail-first: ${label}\n  ? ${name}`);
    const r = checkGuard(sha, decl, opts);
    if (r.ok) {
      console.log(`  ✓ fail-first proven: ${r.detail}`);
    } else {
      failed++;
      console.error(`  ✗ ${r.code}: ${r.detail}`);
      if (process.env.GITHUB_ACTIONS) {
        console.error(`::error::fail-first ${r.code} — ${label} (${name})`);
      }
    }
  }
  return { checked, failed, skipped };
}

function listFragmentFiles() {
  const dir = path.join(REPO_ROOT, 'changelog.d');
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((n) => n.endsWith('.md') && !n.startsWith('_') && !n.startsWith('.'))
    .sort();
}

/** Guard-key lint over every fragment on disk. Node builtins only. */
function lintAll() {
  const problems = [];
  let claims = 0;
  for (const name of listFragmentFiles()) {
    const text = fs.readFileSync(path.join(REPO_ROOT, 'changelog.d', name), 'utf8');
    try {
      const decl = readDeclaration(name, parseHeader(name, text));
      if (decl.kind !== 'none') claims++;
    } catch (err) {
      problems.push(err.message);
    }
  }
  for (const p of problems) console.error(`fail-first: ${p}`);
  return { problems: problems.length, claims };
}

function rangeCommits(range) {
  return git(['rev-list', '--no-merges', '--reverse', range])
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
}

function flag(args, name) {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
}

function main() {
  const args = process.argv.slice(2);
  const timeout = Number(flag(args, '--timeout') ?? DEFAULT_TIMEOUT_MS);

  if (args.includes('--lint')) {
    const { problems, claims } = lintAll();
    if (problems) process.exit(1);
    console.log(`fail-first: fragment guard keys OK (${claims} carry a claim).`);
    return;
  }

  if (args.includes('--scan')) {
    const { problems } = lintAll();
    if (problems) process.exit(1);
    const range = flag(args, '--range');
    const one = flag(args, '--commit');
    const shas = range ? rangeCommits(range) : one ? [one] : [];
    let any = false;
    let bad = 0;
    // No early break once a guard is found, unlike before: the point of walking
    // the whole range is to check every declaration's revert set against its
    // OWN commit. It is still one `git show --name-only` per commit.
    for (const sha of shas) {
      let decls;
      try {
        decls = declarationsFor(sha);
      } catch {
        any = true; // malformed: let the real run report it
        continue;
      }
      const guards = decls.filter((d) => d.decl.kind === 'guard');
      if (guards.length) any = true;
      let changed = null;
      for (const { name, decl } of guards) {
        changed ??= changedPaths(sha);
        const { problem } = resolveRevertSpecs(decl, changed);
        if (!problem) continue;
        bad++;
        console.error(`fail-first: ${shortLog(sha)}\n  ✗ ${problem.code}: ${name}: ${problem.detail}`);
        if (process.env.GITHUB_ACTIONS) {
          console.error(`::error::fail-first ${problem.code} — ${shortLog(sha)} (${name})`);
        }
      }
    }
    if (bad) {
      console.error(
        `\nfail-first: ${bad} guard declaration(s) name a revert set this commit cannot use. ` +
          `Nothing was run — fix the declaration, or take guard-skip with a reason.`,
      );
      process.exit(1);
    }
    const line = `has_guards=${any}`;
    console.log(line);
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `${line}\n`);
    return;
  }

  const trySha = flag(args, '--try');
  if (trySha) {
    const test = flag(args, '--test');
    if (!test) {
      console.error('--try needs --test "<command>"');
      process.exit(2);
    }
    const decl = {
      kind: 'guard',
      test,
      cwd: flag(args, '--cwd') ?? '.',
      revert: flag(args, '--revert') ?? null,
      red: flag(args, '--red') ?? null,
    };
    console.log(`fail-first: ${shortLog(trySha)}\n  ? --try`);
    const r = checkGuard(trySha, decl, { timeout });
    if (r.ok) {
      console.log(`  ✓ fail-first proven: ${r.detail}`);
      return;
    }
    console.error(`  ✗ ${r.code}: ${r.detail}`);
    process.exit(1);
  }

  const one = flag(args, '--commit');
  const range = flag(args, '--range');
  if (!one && !range) {
    console.error(
      'usage: fail-first.mjs [--commit <sha> | --range A..B | --scan --range A..B | --lint | --try <sha> --test "<cmd>"]',
    );
    process.exit(2);
  }

  const { problems } = lintAll();
  if (problems) process.exit(1);

  const shas = one ? [one] : rangeCommits(range);
  let checked = 0;
  let failed = 0;
  let skipped = 0;
  for (const sha of shas) {
    const r = checkCommit(sha, { timeout });
    checked += r.checked;
    failed += r.failed;
    skipped += r.skipped;
  }

  if (failed) {
    console.error(`\nfail-first: ${failed} of ${checked} claimed guard(s) not proven.`);
    process.exit(1);
  }
  console.log(
    `fail-first: ${shas.length} commit(s), ${checked} guard(s) proven, ${skipped} skipped by guard-skip.`,
  );
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
