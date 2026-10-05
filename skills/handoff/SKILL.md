---
name: handoff
description: Park all work in the current repo and push it, before switching to your other machine. Seals .env secrets, commits everything including half-finished work, and pushes. Use when the user says they are switching machines, leaving the PC/Mac, done for now, or asks to hand off / park / save work to continue elsewhere.
---

# handoff

Park everything in the current repo so the other machine can pick it up.

## Run it

Use the **Bash** tool (not PowerShell: the script is bash and must run under
Git Bash on Windows):

```bash
export PATH="$HOME/bin:$PATH"
bash ~/dev-sync/scripts/devsync.sh handoff
```

Run it from inside the repo the user is working in. If the current directory is
not a git repo, ask which repo they mean rather than guessing.

## What it does

1. Encrypts every top-level `.env*` file to a `.env*.sops` twin (age/sops)
2. `git add -A` stages everything, including untracked files
3. Commits as `wip(<machine>): <timestamp>`, amending if the tip is already a
   parked commit from this machine, so the tip never accumulates wip entries
4. Pushes. Force is used **only** when the commit being overwritten is itself a
   parked commit, never real work
5. Reports any ignored files that did not travel (stray keys, local databases)

## Reporting back

Relay the script's output plainly. Two things always deserve a callout:

- Anything under "not carried over": those files exist only on this machine
- A push that was refused means the branch has real remote work; the user
  needs `git pull --rebase` first, and the script deliberately will not force

If the repo has never been set up, the script still works but secrets will not
travel. Suggest `/sync-setup` in that case.
