---
name: resume
description: Pick up work in the current repo after arriving at a machine. Pulls, unpacks parked work, decrypts .env secrets, and flags dependency reinstalls. Use when the user says they just sat down, switched machines, are back on the PC/Mac, or asks to resume / catch up / pull down their work.
---

# resume

Pick up where the other machine left off.

## Run it

Use the **Bash** tool (not PowerShell — the script is bash and must run under
Git Bash on Windows):

```bash
export PATH="$HOME/bin:$PATH"
bash ~/dev-sync/scripts/devsync.sh resume
```

Run it from inside the repo. If it is a repo the user has never cloned here,
clone it first with `gh repo clone Raz-Gits/<name>`, then run resume.

## What it does

1. Refuses to run if there are uncommitted local changes — those must be
   handed off first, or the pull would clobber them
2. Drops this machine's stale parked commit, but only when doing so leaves the
   branch fast-forwardable (never discards real unpushed work)
3. Fast-forwards to `origin/<branch>`
4. Unpacks the incoming parked commit with `reset --soft`, so the work returns
   as staged-but-uncommitted changes and history stays clean
5. Decrypts `.env*.sops` back to plaintext `.env*`, backing up any existing
   file to `.bak-devsync` first
6. Compares dependency lockfiles before and after, and prints the exact
   reinstall command if they changed

## Reporting back

Relay the output. Act on these:

- **"branch diverged"** — resume stopped and changed nothing. Both machines
  have real commits. Show the user `git log --oneline --graph HEAD origin/<br>`
  and help them reconcile; do not force anything.
- **"dependency lockfile changed"** — offer to run the printed install command.
  This matters most crossing macOS↔Windows, where native binaries differ.
- **decryption failed** — this machine is missing the age key. The fix is
  copying `keys.txt` from the other machine (see `~/dev-sync/README.md`).
