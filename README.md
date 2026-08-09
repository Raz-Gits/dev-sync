# dev-sync

Move a repo between the Mac and the PC without losing half-finished work,
without leaking secrets, and without the two machines fighting over line
endings.

Three commands. Two are daily; one is once per repo.

---

## Daily use

**Before you leave a machine:**

```
/handoff
```

Seals your `.env`, commits everything including half-finished work, pushes.

**When you sit down at the other machine:**

```
/resume
```

Pulls, puts your half-finished work back exactly as it was, decrypts your
`.env`, and tells you if you need to reinstall dependencies.

That's the whole loop. You do not need to commit properly, write a message, or
remember what you were doing. Park it and go.

---

## When you start a new repo

Run this **once**, right after `git init` or your first clone:

```
/sync-setup
```

Then commit what it changed. Do this **before** your first `/handoff` in that
repo — otherwise your `.env` will not travel and you will get plaintext
secrets committed by accident.

Order for a brand new project:

```
mkdir myproject && cd myproject
git init
gh repo create Raz-Gits/myproject --private --source=. --remote=origin
/sync-setup
git add -A && git commit -m "initial + devsync"
git push -u origin main
```

Order for a repo that already exists on GitHub but has never been synced:

```
gh repo clone Raz-Gits/thatrepo && cd thatrepo
/sync-setup
git add -A && git commit -m "devsync setup" && git push
```

You only ever run `/sync-setup` **once per repo**, not once per machine. Once
it is committed, the other machine gets the setup by pulling.

---

## Setting up the second machine

On the Mac, once:

```bash
git clone git@github.com:Raz-Gits/dev-sync.git ~/dev-sync
bash ~/dev-sync/install.sh
```

That installs `sops` and `age` via Homebrew, and installs the three skills into
`~/.claude/skills/`.

`install.sh` generates **that machine's own keypair** and registers its public
key in `recipients.txt`. Push that change so the other machines learn it:

```bash
cd ~/dev-sync
git add recipients.txt && git commit -m "recipients: add mac" && git push
```

On your other machines, `git pull` in `~/dev-sync` to pick it up.

Verify:

```bash
devsync doctor
```

### Why no key ever has to travel

Each machine holds its own private key, which never leaves it. Every secret is
encrypted to **all** public keys in `recipients.txt`, so any registered machine
opens it with its own key. There is no single key file to AirDrop, paste, or
lose — and no moment where the thing protecting every one of your secrets is
sitting in a chat window or a USB stick.

`recipients.txt` holds only *public* keys. Those can encrypt but never decrypt,
so committing them is safe.

### Adding a machine later

```bash
devsync add-key      # on the new machine: generates + registers its key
# commit and push recipients.txt, then pull it everywhere
```

Repos set up *after* that need nothing. Repos that **already** have sealed
secrets were encrypted to the old recipient list, so the new machine cannot
read them until you re-seal — run this from a machine that can already decrypt:

```bash
devsync rekey        # per repo, then commit and push
```

---

## What travels, and what doesn't

| Thing | Travels? | How |
|---|---|---|
| Committed code | yes | git |
| Half-finished uncommitted work | yes | parked commit, unpacked on arrival |
| `.env` secrets | yes | encrypted to `.env.sops`, committed, decrypted on arrival |
| `node_modules`, `.venv` | **no, deliberately** | contains OS-native binaries; reinstall from the lockfile |
| Local databases, `*.pem`, stray keys | no | `/handoff` lists these so you know they stayed behind |

If something in that last row matters, rename it to `.env.something` and
devsync will seal and carry it.

---

## Why parked commits don't pollute history

`/handoff` writes a commit called `wip(machine): timestamp`. `/resume` removes
it with `reset --soft`, so the work comes back as uncommitted changes and the
commit disappears. There is never more than one parked commit alive at a time,
and none of them survive into your real history.

Force-pushing is used only to replace a parked commit with a newer parked
commit. If the remote tip is real work, the push is refused rather than forced.

---

## Cross-platform settings `/sync-setup` applies

These exist because the same repo living on both macOS and Windows breaks in
specific, boring ways:

| Setting | Prevents |
|---|---|
| `core.autocrlf=false` + `.gitattributes eol=lf` | every file showing as modified after switching machines |
| `*.sops -text` | git rewriting encrypted files to CRLF, which breaks decryption |
| `core.longpaths=true` | Windows' 260-character path limit, which deep `node_modules` trees exceed |
| `core.filemode=false` | scripts showing as modified because Windows can't store the Unix executable bit |

---

## Troubleshooting

**"branch diverged"** — both machines have real commits. `/resume` stops and
changes nothing. Look at `git log --oneline --graph HEAD origin/main` and merge
or rebase by hand. This is the one case that needs a human.

**"failed to decrypt"** — this machine does not have the age key. See the
setup section above.

**"push rejected and origin is real work"** — the script is refusing to force
over something that is not a parked commit. Run `git pull --rebase`, then
`/handoff` again.

**Decryption suddenly fails on Windows** — check `.gitattributes` still has
`*.sops -text`. Without it, git converts the encrypted file to CRLF and sops
cannot parse its timestamp.
