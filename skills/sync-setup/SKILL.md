---
name: sync-setup
description: Prepare a repo for cross-machine sync. Run once per repo, including every new repo you create. Configures cross-platform git settings, writes .gitattributes and .gitignore, seals existing .env secrets with sops, and untracks any plaintext secrets already committed. Use when starting a new project, cloning a repo for the first time, or when handoff/resume reports a repo is not set up.
---

# sync-setup

Run **once per repo**, including every new repo you start.

## Run it

Use the **Bash** tool (not PowerShell: the script is bash and must run under
Git Bash on Windows):

```bash
export PATH="$HOME/bin:$PATH"
bash ~/dev-sync/scripts/devsync.sh init
```

Then review and commit what it changed:

```bash
git add -A && git commit -m "devsync: set up cross-machine sync"
```

## What it does

1. Sets `core.autocrlf=false`, `core.filemode=false`, `core.longpaths=true`:
   the three settings that cause phantom diffs and checkout failures when the
   same repo lives on both macOS and Windows
2. Appends `.gitattributes` pinning `eol=lf`, and marks `*.sops` as binary.
   **This rule is load-bearing**: if git ever rewrites an encrypted file to
   CRLF, sops cannot parse its timestamp and decryption fails with an error
   that does not point at the cause
3. Adds secrets and rebuildable artifacts to `.gitignore`
4. Writes `.sops.yaml` naming this user's age public key as recipient
5. Seals any existing `.env*` into `.env*.sops`
6. **Untracks plaintext secrets that were already committed**. Adding a path
   to `.gitignore` does nothing if git already tracks it

## Reporting back

Two warnings need to be surfaced prominently, not buried:

- **"it was committed in plaintext"**: untracking stops future leakage but the
  credential is still in git history and on GitHub. Tell the user plainly to
  rotate that credential. Do not soften this.
- **"node_modules is committed"**: those are platform-native binaries built on
  one OS. The repo will fail on the other. Offer the fix:
  `git rm -r --cached node_modules && git commit -m "untrack node_modules"`

## First time on a new machine

Before this works at all, the machine needs the tooling and the age key.
Check with:

```bash
bash ~/dev-sync/scripts/devsync.sh doctor
```

Setup instructions for a fresh machine are in `~/dev-sync/README.md`.
