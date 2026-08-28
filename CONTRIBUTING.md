# Contributing

## Sign your commits (DCO)

This project is under a source-available license, and the maintainer may offer
commercial licenses. That means a contribution has to come with permission to
relicense it — otherwise your code could not be included in a commercial grant,
and untangling that after the fact is impractical.

Every commit must carry a `Signed-off-by` line:

```sh
git commit -s -m "your message"
```

By signing off you certify the [Developer Certificate of Origin](https://developercertificate.org/)
and grant the maintainer the right to license your contribution under both the
Elastic License 2.0 and any other terms, including commercial terms.

Unsigned commits will be asked to sign off before merge. No CLA to sign, no
account to create.

## What makes a good change here

**A new working rule names what enforces it.** A wrapper, a gate, a refusal, or
a CI job — or it says explicitly that nothing does. An incident that repeats
after being written down gets a mechanism, not a better note. This is the
project's central conviction; a PR that adds advice with no enforcement will be
asked what enforces it.

**A new hardcoded path, command, or product noun in `bin/` or `lib/` is a bug.**
Add a key to `entropy.json` instead. See [docs/CONFIG.md](docs/CONFIG.md).

**Reasoning comments are load-bearing.** This codebase explains *why* a guard
exists, usually with the failure that caused it. Keep that style. If you remove
a guard, say which incident you believe can no longer happen.

**Claims about tests need to be provable.** If you call something a regression
guard, show it going red without the fix — `node lib/fail-first.mjs --try <sha>
--test "<cmd>"`. "I ran it and it passed" is not evidence anyone can check.

## Before you open a PR

- [ ] Shell scripts pass `sh -n`, JS passes `node --check`, Python passes
      `python3 -m py_compile`.
- [ ] No product nouns from your own repo leaked into the harness.
- [ ] Commits signed off.
