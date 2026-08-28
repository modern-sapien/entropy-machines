#!/usr/bin/env node
/**
 * config — load entropy.json once per process, fill in defaults, and refuse
 * with a named key when a key has no safe default and the project did not
 * supply one.
 *
 * Every value the rest of this harness used to hardcode about its host
 * project lives in entropy.json at the repo root (see docs/CONFIG.md). This
 * is the one place that reads the file; every entry point calls loadConfig()
 * once and passes the object down. A previous version of the tooling this
 * harness grew from read its own state file from four independent places,
 * each with a slightly different idea of what was optional, and reconciling
 * them after the fact was worse than writing one loader up front.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CONFIG_FILENAME = 'entropy.json';

/**
 * Defaults for every key that has a safe one. A default here must be inert —
 * "do nothing" or "match everything", never a guess at what a project's
 * toolchain looks like. `suites` defaults to an empty list, not to a set of
 * npm scripts; a consuming Go-only or shell-only project must not see this
 * harness silently assume it is Node.
 */
const DEFAULTS = {
  project: { name: null, protectedPaths: [] },
  tracker: {
    backend: 'file',
    file: { path: '.entropy/issues.json' },
    command: { bin: null },
  },
  suites: [],
  generate: { cmd: null, outputs: [] },
  changelog: {
    enabled: true,
    fragmentDir: 'changelog.d',
    collatedFile: 'docs/CHANGELOG.md',
    marker: '<!-- BEGIN COLLATED changelog.d -->',
    // Not in docs/CONFIG.md yet — see lib/changelog-guard.sh's header comment.
    // Paths whose change requires a fragment. Default: everything, i.e. "one
    // fragment per commit" until a project narrows it.
    watchedPathPatterns: ['**'],
    // Not in docs/CONFIG.md yet. Display text only (changelog-guard.sh's
    // failure message) — not shelled out to.
    newFragmentCmd: 'node lib/changelog-new.mjs --',
    // Not in docs/CONFIG.md yet. Display text only (changelog-collate.mjs's
    // "you need to re-collate" message) — not shelled out to.
    collateCmd: 'node lib/changelog-collate.mjs',
  },
  guards: {
    testPathPatterns: ['**/*.test.*', 'tests/**'],
    nonCodePatterns: ['**/*.md', 'docs/**'],
    buildFailureMarkers: [],
    // Not in docs/CONFIG.md yet — see lib/fail-first.mjs's runTest(). Extra
    // environment variables applied to every guard-test invocation. This is
    // how a project that uses Go's test result cache opts into
    // `{ "GOFLAGS": "-count=1" }`; the harness no longer injects it for you.
    testEnv: {},
  },
  worktree: { linkPaths: ['node_modules'] },
  unattended: {
    enabled: false,
    stateHome: '~/.entropy',
    scheduler: 'launchd',
    label: 'com.entropy.drain',
    agent: { cmd: ['claude', '-p'] },
  },
};

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function deepMerge(base, override) {
  if (!isPlainObject(base) || !isPlainObject(override)) return override ?? base;
  const out = { ...base };
  for (const [k, v] of Object.entries(override)) {
    out[k] = isPlainObject(base[k]) && isPlainObject(v) ? deepMerge(base[k], v) : v;
  }
  return out;
}

/** `git rev-parse --show-toplevel`, falling back to walking up for entropy.json when there is no git. */
export function findRepoRoot(start = process.cwd()) {
  try {
    return execFileSync('git', ['-C', start, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    let dir = path.resolve(start);
    for (;;) {
      if (fs.existsSync(path.join(dir, CONFIG_FILENAME))) return dir;
      const parent = path.dirname(dir);
      if (parent === dir) return path.resolve(start);
      dir = parent;
    }
  }
}

/** Keys with no safe default: named and refused, per docs/CONFIG.md rule 2. */
function validate(cfg) {
  const missing = [];
  if (cfg.tracker.backend === 'command' && !cfg.tracker.command?.bin) {
    missing.push('tracker.command.bin (required because tracker.backend is "command")');
  }
  if (cfg.unattended.enabled && !(cfg.unattended.agent?.cmd?.length)) {
    missing.push('unattended.agent.cmd (required because unattended.enabled is true)');
  }
  if (missing.length) {
    throw new Error(
      `entropy.json is missing required configuration:\n${missing
        .map((m) => `  - ${m}`)
        .join('\n')}\nSee docs/CONFIG.md.`,
    );
  }
}

let cached = null;

/**
 * Load and validate entropy.json. Cached per process (docs/CONFIG.md rule 3)
 * — call this once at each entry point and pass the result down; do not call
 * it again from a library function. `force` is for tests only.
 */
export function loadConfig({ cwd, force = false } = {}) {
  if (cached && !force) return cached;
  const root = findRepoRoot(cwd);
  const file = path.join(root, CONFIG_FILENAME);
  let user = {};
  if (fs.existsSync(file)) {
    try {
      user = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
      throw new Error(`${file}: invalid JSON — ${err.message}`);
    }
  }
  const merged = deepMerge(DEFAULTS, user);
  if (!merged.project.name) merged.project.name = path.basename(root);
  validate(merged);
  Object.defineProperty(merged, '_root', { value: root, enumerable: false });
  Object.defineProperty(merged, '_path', {
    value: fs.existsSync(file) ? file : null,
    enumerable: false,
  });
  cached = merged;
  return merged;
}

/**
 * `**`/`*`/`?` glob -> RegExp, anchored to the whole string. Enough for the
 * path-pattern lists in entropy.json (`guards.testPathPatterns` and
 * friends); not a full minimatch, and not meant to be one.
 */
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        re += '.*';
        i++;
        if (glob[i + 1] === '/') i++;
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else if ('.+^${}()|[]\\'.includes(c)) {
      re += `\\${c}`;
    } else {
      re += c;
    }
  }
  return new RegExp(`^${re}$`);
}

export function matchesAny(patterns, p) {
  return patterns.some((pat) => globToRegExp(pat).test(p));
}

// --- CLI: `node lib/config.mjs [root | get <dotted.key>]` — for callers that need one value and don't want to embed Node. ---
function cliMain(argv) {
  const cfg = loadConfig();
  const [cmd, ...rest] = argv;
  if (cmd === 'root') {
    console.log(cfg._root);
    return 0;
  }
  if (cmd === 'get') {
    const key = rest[0];
    if (!key) {
      console.error('usage: config.mjs get <dotted.key>');
      return 2;
    }
    let v = cfg;
    for (const part of key.split('.')) v = v?.[part];
    if (v === undefined) {
      console.error(`config.mjs: no such key ${key}`);
      return 1;
    }
    console.log(typeof v === 'string' ? v : JSON.stringify(v));
    return 0;
  }
  console.error('usage: config.mjs [root | get <dotted.key>]');
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exit(cliMain(process.argv.slice(2)));
  } catch (err) {
    console.error(`config.mjs: ${err.message}`);
    process.exit(1);
  }
}
