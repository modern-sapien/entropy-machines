# The npm package

`npx entropy-machines init` is a **delivery mechanism, not a runtime**. It
copies the harness into your repository as plain tracked files and runs
`bin/init`. After that npm is gone: nothing vendored imports from
`node_modules`, nothing shells out to `node`, and the harness runs on git, a
POSIX shell and Python 3. Deleting `node_modules/` changes nothing.

The other route is identical in outcome and needs no Node at all — clone this
repo and copy `bin/`, `lib/`, `docs/`, `doctrine/`, `hooks/` and `agents/`
into your project.

## Usage

```sh
npx entropy-machines init            # -> entropy-machines/ at the repo root
npx entropy-machines init --dir .    # -> vendored at the repo root instead
npx entropy-machines --help
npx entropy-machines --version
```

`init` copies the six directories plus `LICENSE`, then runs the vendored
`bin/init` with the repository root as its working directory. To undo it,
delete the directory. There is no uninstall command, no install receipt and
no version check, on purpose.

## Why a subdirectory by default

`entropy-machines/` is the default because vendoring at the repo root merges
the harness's `bin/`, `lib/` and `docs/` into whatever the project already
has under those names, and those are three of the most commonly taken
directory names there are. A subdirectory has none of that: it is one
directory to add, one to `rm -rf`, and `git log` on it shows only harness
changes. `lib/roots.sh` derives `ENTROPY_HOME` from each script's own `$0`,
so both layouts work; `docs/QUICKSTART.md` already tells the agent to prefix
every `bin/…` command with the vendored path.

This is **not** the old nested clone. There is no `.git` in the vendored
directory, so `git` from anywhere inside your project still answers with your
project — one root, as `lib/roots.sh` requires. `entropy_refuse_nested_clone`
refuses the layout that does have one.

Use `--dir .` if you want the root layout the README describes, and every
`bin/…` command in the docs verbatim.

## What it refuses, before writing anything

| Situation | Why |
|---|---|
| Not inside a git repository | Vendored files have to be tracked by something. |
| The destination already holds any of the six directories | An older harness may have edited doctrine in it; your own `bin/` is not ours to merge into. Pass `--dir <path>`. |
| The destination is inside the package's own directory, or a checkout of this package is inside the destination | It would copy itself over itself, and in a `npm link`ed checkout that tree is where a real `.git` lives. An *installed* copy at `<repo>/node_modules/entropy-machines` is exempt — that is what `npm i -D entropy-machines` plus `--dir .` looks like, and the two trees never overlap. |
| The destination is outside the repository | Vendoring means committed alongside your code. |

A `.git` directory is never copied, at any depth — filtered by path segment,
not by trusting the tarball to lack one. A nested `.git` shadows the parent
repo for every git query and silently misroutes every command in the harness;
it is the single failure the vendored layout exists to prevent. `__pycache__`,
`node_modules` and `.DS_Store` are dropped the same way.

## Publishing

`package.json` has no dependencies and no build step.

```sh
npm pack --dry-run      # the exact file list that will ship
npm publish
```

`files` is a whitelist of the six directories, with `!**/__pycache__` and
`!**/*.pyc` negations — a `.npmignore` does **not** filter inside a
whitelisted directory, so the negations are what keeps compiled Python out.
`planning/`, `.entropy/`, `tests/`, `example/`, `entropy-docs/` and
`CONTRIBUTING.md` are excluded by not being listed; npm excludes `.git`
unconditionally. `LICENSE`, `README.md` and `package.json` are always
included — they ship even though `files` does not name them, so the shipped
list is the six directories plus those three.

Verified against a real `npm pack` on 2026-08-30: the tarball's file list is
exactly the six directories' tracked contents plus those three, with every
executable bit intact (20 of the vendored files land as `100755`).
`bin/entropy-machines-init` is the one packaged file NOT vendored, because it
is the npm wrapper rather than part of the harness.

`npm pack` reads the WORKING TREE, not HEAD. An uncommitted or untracked file
inside one of the six directories ships. Pack from a clean tree, and read the
`npm notice` file list before publishing rather than trusting `files`.

The package version is the npm artifact's version. It is not a harness
version and nothing checks it — there is no staleness detection anywhere in
this project.
