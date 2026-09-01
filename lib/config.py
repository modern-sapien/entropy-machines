#!/usr/bin/env python3
"""config — load config.json once per process, fill in defaults, and refuse
with a named key when a key has no safe default and the project did not
supply one.

Mirrors lib/config.mjs. Two implementations exist because this harness's own
tooling is a mix of Node and Python; both read the same config.json and
apply the same defaults independently, so a consuming project edits exactly
one file and either loader sees it the same way. Neither reads the file more
than once per process (docs/CONFIG.md rule 3) — call load_config() once at
each entry point and pass the result down.
"""
import json
import os
import re as _re
import subprocess
import sys

CONFIG_FILENAME = "config.json"

# Defaults for every key that has a safe one. A default here must be inert —
# "do nothing" or "match everything" — never a guess at a project's
# toolchain. `suites` defaults to an empty list, not to a set of npm scripts.
DEFAULTS = {
    "project": {"name": None, "protectedPaths": []},
    "tracker": {
        "backend": "file",
        "file": {"path": ".entropy-machines/issues.json"},
        "command": {"bin": None},
    },
    "suites": [],
    "generate": {"cmd": None, "outputs": []},
    "changelog": {
        "enabled": True,
        "fragmentDir": "changelog.d",
        "collatedFile": "docs/CHANGELOG.md",
        "marker": "<!-- BEGIN COLLATED changelog.d -->",
        # Not in docs/CONFIG.md yet — see lib/changelog-guard.sh's header.
        "watchedPathPatterns": ["**"],
        # Not in docs/CONFIG.md yet. Display text only (changelog-guard.sh's
        # failure message) — not shelled out to.
        "newFragmentCmd": "node lib/changelog-new.mjs --",
        # Not in docs/CONFIG.md yet. Display text only (changelog-collate.mjs's
        # "you need to re-collate" message) — not shelled out to.
        "collateCmd": "node lib/changelog-collate.mjs",
    },
    "guards": {
        "testPathPatterns": ["**/*.test.*", "tests/**"],
        "nonCodePatterns": ["**/*.md", "docs/**"],
        "buildFailureMarkers": [],
        # Not in docs/CONFIG.md yet — see lib/fail-first.mjs's runTest().
        "testEnv": {},
    },
    "worktree": {"linkPaths": ["node_modules"]},
    "unattended": {
        "enabled": False,
        "stateHome": "~/.entropy-machines",
        "scheduler": "launchd",
        "label": "com.entropy-machines.drain",
        "agent": {"cmd": ["claude", "-p"]},
    },
}


def _is_dict(v):
    return isinstance(v, dict)


def _deep_merge(base, override):
    if not _is_dict(base) or not _is_dict(override):
        return override if override is not None else base
    out = dict(base)
    for k, v in override.items():
        if _is_dict(base.get(k)) and _is_dict(v):
            out[k] = _deep_merge(base[k], v)
        else:
            out[k] = v
    return out


def _git_root(start):
    """The main checkout of the git repository containing `start`, or None.

    `--git-common-dir`, NOT `--show-toplevel`. Mirrors lib/roots.sh's
    entropy_machines_root(), which is canonical — read its header for why. The short
    version: from inside a LINKED WORKTREE --show-toplevel prints the
    worktree, --git-common-dir names the main checkout, and the main checkout
    is where config.json and .entropy-machines/ live. This loader used to say
    --show-toplevel, so from a worktree it read a DIFFERENT config.json than
    the shell scripts calling it did; that was invisible only because the
    file is tracked and the two copies were identical.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=start,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    common = out.stdout.strip()
    if not os.path.isabs(common):
        # git printed it relative to the directory it ran in.
        common = os.path.join(start, common)
    return os.path.realpath(os.path.join(common, os.pardir))


def refuse_nested_clone(tool, harness_dir=None):
    """Exit 2 if the harness is a git repo nested inside another git repo.

    The Python mirror of lib/roots.sh's entropy_machines_refuse_nested_clone(). The
    harness is meant to be VENDORED as plain tracked files; a nested .git
    shadows the enclosing repo for every git query, so commands run from
    inside it resolve to the harness and silently operate on the wrong
    repository.

    Every shell entry point gets this through entropy_machines_require_root(). The
    Python ones resolve the root themselves and so have to ask explicitly --
    which is exactly how bin/init came to be the one command exempt from a
    refusal whose whole purpose is to stop it writing into the harness.
    """
    if harness_dir is None:
        harness_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if not os.path.exists(os.path.join(harness_dir, ".git")):
        return
    inner = _git_root(harness_dir)
    parent = os.path.dirname(harness_dir)
    outer = _git_root(parent) if parent and parent != harness_dir else None
    if not outer or not inner or os.path.realpath(outer) == os.path.realpath(inner):
        return
    sys.stderr.write(
        "%s: REFUSED — the harness at %s is a git repository of its own,\n"
        "  nested inside %s.\n"
        "  A nested .git shadows the enclosing repo, so commands run here\n"
        "  resolve to the harness and operate on the wrong repository.\n"
        "  Fix: remove %s/.git and commit these files into the project, or\n"
        "  re-vendor the harness as plain files.\n"
        % (tool, harness_dir, outer, harness_dir))
    sys.exit(2)


def find_repo_root(start=None):
    """The ONE root: the repository's main checkout. Agrees with lib/roots.sh.

    Precedence:
      1. an explicit `start` — resolved with git from there. This is a seam
         (lib/fail-first.mjs's FAIL_FIRST_REPO is the Node twin) for pointing
         the loader at a repo other than the ambient one, so it must win.
      2. $ENTROPY_MACHINES_ROOT — already resolved by lib/roots.sh's
         entropy_machines_require_root(), which exports it. Honouring it is what makes
         the shell entry points and this loader agree BY CONSTRUCTION rather
         than by two implementations happening to compute the same path. It
         is not a user knob and not the deleted ENTROPY_PROJECT override:
         nothing sets it but roots.sh, and it is ignored unless it names an
         existing directory.
      3. the process cwd.
    Falls back to walking up for config.json when there is no git.
    """
    if start is None:
        env_root = os.environ.get("ENTROPY_MACHINES_ROOT")
        if env_root and os.path.isdir(env_root):
            return os.path.realpath(env_root)
        start = os.getcwd()
    root = _git_root(start)
    if root:
        return root
    d = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(d, CONFIG_FILENAME)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.abspath(start)
        d = parent


def _validate(cfg):
    """Keys with no safe default: named and refused, per docs/CONFIG.md rule 2."""
    missing = []
    if cfg["tracker"]["backend"] == "command" and not cfg["tracker"]["command"].get("bin"):
        missing.append('tracker.command.bin (required because tracker.backend is "command")')
    if cfg["unattended"]["enabled"] and not cfg["unattended"]["agent"].get("cmd"):
        missing.append("unattended.agent.cmd (required because unattended.enabled is true)")
    if missing:
        lines = "\n".join("  - %s" % m for m in missing)
        raise SystemExit(
            "config.json is missing required configuration:\n%s\nSee docs/CONFIG.md." % lines
        )


_cached = None


_HARNESS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_config(cwd=None, force=False):
    """Load and validate config.json. Cached per process; `force` is for tests only."""
    global _cached
    if _cached is not None and not force:
        return _cached
    root = find_repo_root(cwd)
    # config.json lives in the harness dir, not at the git root.
    file_path = os.path.join(_HARNESS_DIR, CONFIG_FILENAME)
    user = {}
    if os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8") as f:
            try:
                user = json.load(f)
            except json.JSONDecodeError as e:
                raise SystemExit("%s: invalid JSON — %s" % (file_path, e))
    merged = _deep_merge(DEFAULTS, user)
    if not merged["project"].get("name"):
        merged["project"]["name"] = os.path.basename(root)
    _validate(merged)
    merged["_root"] = root
    merged["_path"] = file_path if os.path.exists(file_path) else None
    _cached = merged
    return merged


_ERE_META = set(".^$+()|[]{}\\")


def _escape_ere(s):
    return "".join(("\\" + c) if c in _ERE_META else c for c in s)


def _glob_to_ere(glob):
    """`**`/`*`/`?` glob -> POSIX ERE fragment (unanchored). For grep -E, not Python's `re`."""
    out = []
    i = 0
    n = len(glob)
    while i < n:
        c = glob[i]
        if c == "*":
            if i + 1 < n and glob[i + 1] == "*":
                out.append(".*")
                i += 2
                if i < n and glob[i] == "/":
                    i += 1
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append(".")
            i += 1
            continue
        out.append(_escape_ere(c) if c in _ERE_META else c)
        i += 1
    return "".join(out)


def glob_to_regex(glob):
    """`**`/`*`/`?` glob -> compiled Python regex, anchored to the whole string."""
    return _re.compile("^" + _glob_to_ere(glob) + "$")


def matches_any(patterns, p):
    return any(glob_to_regex(pat).match(p) for pat in patterns)


def _get_path(cfg, dotted):
    v = cfg
    for part in dotted.split("."):
        if not isinstance(v, dict) or part not in v:
            return None, False
        v = v[part]
    return v, True


def _cli_main(argv):
    if not argv:
        print("usage: config.py [root | get <dotted.key> | glob-re <dotted.key> | changelog-fragment-re]", file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "root":
        print(load_config()["_root"])
        return 0
    if cmd == "get":
        if len(argv) < 2:
            print("usage: config.py get <dotted.key>", file=sys.stderr)
            return 2
        value, found = _get_path(load_config(), argv[1])
        if not found:
            print("config.py: no such key %s" % argv[1], file=sys.stderr)
            return 1
        print(value if isinstance(value, str) else json.dumps(value))
        return 0
    if cmd == "glob-re":
        # A list-of-globs key -> one POSIX ERE alternation, anchored at the
        # start only (a prefix/contains test over a bare path, the shape
        # lib/changelog-guard.sh's `grep -Eq` wants).
        if len(argv) < 2:
            print("usage: config.py glob-re <dotted.key>", file=sys.stderr)
            return 2
        value, found = _get_path(load_config(), argv[1])
        if not found or not isinstance(value, list):
            print("config.py: %s is not a list key" % argv[1], file=sys.stderr)
            return 1
        print("^(" + "|".join(_glob_to_ere(p) for p in value) + ")")
        return 0
    if cmd == "changelog-fragment-re":
        cfg = load_config()
        print("^" + _escape_ere(cfg["changelog"]["fragmentDir"]) + r"/[^_].*\.md$")
        return 0
    print("usage: config.py [root | get <dotted.key> | glob-re <dotted.key> | changelog-fragment-re]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli_main(sys.argv[1:]))
