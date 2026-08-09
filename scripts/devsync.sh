#!/usr/bin/env bash
#
# devsync - move a repo between machines without losing work or secrets.
#
#   devsync init      set this repo up for cross-machine sync (run once per repo)
#   devsync handoff   park everything and push it, before you leave a machine
#   devsync resume    pick everything up, when you arrive at a machine
#   devsync doctor    check that this machine has the tooling and keys
#
# Works on macOS and on Windows under Git Bash. Keep it bash-3.2 compatible
# (macOS ships bash 3.2), so: no associative arrays, no mapfile, no ${x,,}.

set -euo pipefail

# ---------------------------------------------------------------- output ----

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "error: $*" >&2; exit 1; }

# ------------------------------------------------------------- discovery ----

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null \
    || die "not inside a git repository (cd into one first)"
}

branch_name() { git rev-parse --abbrev-ref HEAD; }

machine_name() {
  if [ -n "${DEVSYNC_MACHINE:-}" ]; then
    printf '%s' "$DEVSYNC_MACHINE"
  else
    hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-24
  fi
}

# Where age keeps the private key. sops looks here on its own, but we resolve it
# explicitly so `doctor` can give a real answer and so SOPS_AGE_KEY_FILE is set
# even when the platform default differs.
age_key_file() {
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -f "${SOPS_AGE_KEY_FILE}" ]; then
    printf '%s' "$SOPS_AGE_KEY_FILE"; return
  fi
  for candidate in \
    "$HOME/.config/sops/age/keys.txt" \
    "${APPDATA:-$HOME/AppData/Roaming}/sops/age/keys.txt" \
    "$HOME/AppData/Roaming/sops/age/keys.txt"
  do
    if [ -f "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  printf ''
}

age_pubkey() {
  local kf; kf="$(age_key_file)"
  [ -n "$kf" ] || die "no age key on this machine. Run: devsync doctor"
  age-keygen -y "$kf" 2>/dev/null | head -n1
}

# sops resolves the default key location with Go's os.UserConfigDir(), which on
# macOS is ~/Library/Application Support - NOT the ~/.config path this tooling
# writes to. Windows agrees on %APPDATA% by luck. Export the resolved path so
# sops decrypts with the same key that doctor reports, on every platform.
_devsync_kf="$(age_key_file)"
[ -n "$_devsync_kf" ] && export SOPS_AGE_KEY_FILE="$_devsync_kf"

# Where devsync itself lives, so we can find the shared recipient list.
DEVSYNC_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECIPIENTS_FILE="${DEVSYNC_RECIPIENTS:-$DEVSYNC_HOME/recipients.txt}"

# Every machine's PUBLIC key. Secrets are encrypted to all of them, so each
# machine opens them with its own private key and no private key ever travels.
age_recipients() {
  [ -f "$RECIPIENTS_FILE" ] || die "missing $RECIPIENTS_FILE - pull the dev-sync repo"
  local keys
  keys="$(sed 's/#.*//' "$RECIPIENTS_FILE" | tr -d ' \t\r' | grep -E '^age1[a-z0-9]+$' | paste -sd, -)"
  [ -n "$keys" ] || die "no age recipients in $RECIPIENTS_FILE - run: devsync add-key"
  printf '%s' "$keys"
}

recipient_count() { age_recipients | tr ',' '\n' | grep -c . ; }

# Is this machine's key actually one of the recipients? If not, it can seal
# secrets it will never be able to reopen.
this_machine_is_recipient() {
  local mine; mine="$(age_pubkey)"
  age_recipients | tr ',' '\n' | grep -qxF "$mine"
}

# ---------------------------------------------------------------- secrets ----

# Every plaintext secret file we manage, and its encrypted twin.
# .env -> .env.sops, .env.local -> .env.local.sops, and so on.
secret_files() {
  # Recursive: monorepos keep .env files in subdirectories (apps/web/.env).
  # Prunes dependency trees so we never seal a package's bundled .env.
  # Excludes .example (a template, meant to be committed) and .sops (already
  # sealed - encrypting it again would produce .env.sops.sops and then fail).
  find . \( -name node_modules -o -name .venv -o -name venv -o -name .git \
            -o -name vendor -o -name .cache -o -name __pycache__ \) -prune -o \
    -type f -name '.env*' -print 2>/dev/null \
  | sed 's|^\./||' \
  | grep -E '(^|/)\.env(\.[A-Za-z0-9_-]+)?$' \
  | grep -vE '\.(example|sample|template|sops|bak-devsync)$' || true
}

encrypted_files() {
  find . \( -name node_modules -o -name .venv -o -name venv -o -name .git \
            -o -name vendor -o -name .cache -o -name __pycache__ \) -prune -o \
    -type f -name '.env*.sops' -print 2>/dev/null \
  | sed 's|^\./||' \
  | grep -E '(^|/)\.env(\.[A-Za-z0-9_-]+)?\.sops$' || true
}

encrypt_secrets() {
  local pub changed=0 f
  pub="$(age_recipients)"
  # Sealing to a recipient list that excludes this machine would produce files
  # this machine can never reopen. Refuse rather than create that trap.
  this_machine_is_recipient \
    || die "this machine's key is not in $RECIPIENTS_FILE - run: devsync add-key"
  # while-read, not for-in: paths may contain spaces
  while IFS= read -r f; do
    local out="$f.sops"
    # Re-encrypt only when the plaintext differs from what's already sealed;
    # sops output is nondeterministic, so comparing ciphertext would always
    # report a change and dirty the repo on every handoff.
    if [ -f "$out" ] && sops decrypt --input-type dotenv --output-type dotenv "$out" 2>/dev/null \
         | diff -q - "$f" >/dev/null 2>&1; then
      continue
    fi
    sops encrypt --input-type dotenv --output-type dotenv --age "$pub" "$f" > "$out.tmp" \
      || { rm -f "$out.tmp"; die "failed to encrypt $f"; }
    mv "$out.tmp" "$out"
    grn "  sealed  $f -> $out"
    changed=1
  done < <(secret_files)
  return 0
}

decrypt_secrets() {
  local f
  while IFS= read -r f; do
    local plain="${f%.sops}"
    if [ -f "$plain" ] && sops decrypt --input-type dotenv --output-type dotenv "$f" 2>/dev/null \
         | diff -q - "$plain" >/dev/null 2>&1; then
      dim "  unchanged  $plain"
      continue
    fi
    if [ -f "$plain" ]; then
      cp "$plain" "$plain.bak-devsync"
      yel "  existing $plain backed up to $plain.bak-devsync"
    fi
    sops decrypt --input-type dotenv --output-type dotenv "$f" > "$plain.tmp" \
      || { rm -f "$plain.tmp"; die "failed to decrypt $f - is your age key on this machine?"; }
    mv "$plain.tmp" "$plain"
    grn "  opened  $f -> $plain"
  done < <(encrypted_files)
}

# ------------------------------------------------------- unsynced warning ----

# Files that exist on disk, are ignored by git, and look like something you
# would actually miss on the other machine. Deliberately narrow: listing every
# ignored file would just print node_modules forever.
report_unsynced() {
  local found=0 f
  # NUL-delimited: git status quotes paths containing spaces, which used to
  # word-split into garbage here. ls-files -z gives raw paths.
  while IFS= read -r -d '' f; do
    case "$f" in
      node_modules/*|node_modules|*/node_modules/*) continue ;;
      .venv/*|.venv|venv/*|__pycache__/*|.next/*|dist/*|build/*|.turbo/*) continue ;;
      *.env.sops|*.bak-devsync) continue ;;
    esac
    # A plaintext secret with a sealed twin IS travelling - don't cry wolf.
    [ -f "$f.sops" ] && continue
    case "$f" in
      *.env|*.env.*|*.pem|*.key|*.p12|*credentials*.json|*service-account*.json|*.sqlite|*.sqlite3|*.db)
        [ "$found" -eq 0 ] && { yel "not carried over (ignored by git):"; found=1; }
        printf '    %s\n' "$f"
        ;;
    esac
  done < <(git ls-files --others --ignored --exclude-standard -z 2>/dev/null)
  if [ "$found" -eq 1 ]; then
    dim "    ^ if any of these matter, add them as .env* so devsync can seal them"
  fi
}

# ------------------------------------------------------------------ init ----

cmd_init() {
  local root; root="$(repo_root)"; cd "$root"
  bold "devsync init - $(basename "$root")"

  # 1. Cross-platform git behaviour. These are the Mac<->Windows footguns:
  #    line endings rewritten on checkout, the 260-char path limit, and the
  #    Unix executable bit Windows cannot represent.
  git config core.autocrlf false
  git config core.filemode false
  git config core.longpaths true
  grn "  git configured for cross-platform checkout"

  # 2. .gitattributes. The .sops rule is load-bearing: if git ever converts an
  #    encrypted file to CRLF, sops cannot parse its timestamp and decryption
  #    fails with a confusing error.
  if [ ! -f .gitattributes ] || ! grep -q 'devsync' .gitattributes 2>/dev/null; then
    cat >> .gitattributes <<'EOF'

# --- devsync: keep checkouts identical on macOS and Windows ---
* text=auto eol=lf
*.env.sops -text
*.sops -text
*.png binary
*.jpg binary
*.pdf binary
*.sh text eol=lf
*.bat text eol=crlf
EOF
    grn "  wrote .gitattributes"
  else
    dim "  .gitattributes already has devsync rules"
  fi

  # 3. .gitignore - plaintext secrets and rebuildable artifacts must never land.
  touch .gitignore
  for pat in '.env' '.env.*' '!.env.example' '!*.env.sops' '!.env.*.sops' \
             'node_modules/' '.venv/' '__pycache__/' '*.bak-devsync'
  do
    grep -qxF "$pat" .gitignore 2>/dev/null || printf '%s\n' "$pat" >> .gitignore
  done
  grn "  .gitignore covers secrets and build artifacts"

  # 4. sops recipients for this repo - every machine's public key, so each one
  #    decrypts with its own private key and no private key ever travels.
  local pub; pub="$(age_recipients)"
  if [ ! -f .sops.yaml ] || ! grep -qF "$pub" .sops.yaml 2>/dev/null; then
    cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: \\.env(\\..*)?\$
    age: $pub
EOF
    grn "  wrote .sops.yaml ($(recipient_count) recipient machine(s))"
  else
    dim "  .sops.yaml already lists the current recipients"
  fi

  # 5. Seal whatever secrets are sitting here right now.
  local secrets; secrets="$(secret_files)"
  if [ -n "$secrets" ]; then
    encrypt_secrets
  else
    dim "  no .env files here to seal"
  fi

  # 5b. Adding a path to .gitignore does nothing if git already tracks it.
  #     Untrack any plaintext secret so future commits stop carrying it.
  local leaked=0 f
  while IFS= read -r f; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      git rm --cached --quiet "$f"
      yel "  untracked $f (it was committed in plaintext)"
      leaked=1
    fi
  done < <(secret_files)
  if [ "$leaked" -eq 1 ]; then
    red "  NOTE: past commits still contain that plaintext in history."
    red "  Untracking stops the bleeding; it does not erase the past."
    red "  Rotate any real credential that was in there."
  fi

  # 6. If node_modules was committed, say so loudly. Committed dependencies
  #    carry platform-native binaries and will not run on the other OS.
  if git ls-files --error-unmatch node_modules >/dev/null 2>&1; then
    red "  WARNING: node_modules is committed to this repo."
    red "  It contains binaries built for one OS and will break on the other."
    red "  Fix: git rm -r --cached node_modules && git commit -m 'untrack node_modules'"
  fi

  echo
  grn "ready. commit these changes, then use: devsync handoff / devsync resume"
}

# --------------------------------------------------------------- handoff ----

cmd_handoff() {
  local root; root="$(repo_root)"; cd "$root"
  local br mach stamp
  br="$(branch_name)"; mach="$(machine_name)"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  bold "devsync handoff - $(basename "$root") [$br] from $mach"

  [ "$br" = "HEAD" ] && die "detached HEAD; checkout a branch first"

  encrypt_secrets

  # Fail-safe: never commit a plaintext secret. If a .env is not gitignored,
  # init never ran here and the 'git add -A' below would publish it to GitHub.
  local f
  while IFS= read -r f; do
    git check-ignore -q "$f" 2>/dev/null \
      || die "plaintext '$f' is not gitignored - run 'devsync init' (/sync-setup) in this repo first"
  done < <(secret_files)

  git add -A

  if git diff --cached --quiet; then
    dim "  nothing new to commit"
  else
    local prev; prev="$(git log -1 --format=%s 2>/dev/null || echo '')"
    case "$prev" in
      "wip($mach):"*)
        # Fold into the existing parked commit so the tip never accumulates a
        # pile of wip entries.
        git commit --quiet --amend -m "wip($mach): $stamp"
        grn "  amended parked commit"
        ;;
      *)
        git commit --quiet -m "wip($mach): $stamp"
        grn "  parked a new commit"
        ;;
    esac
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    yel "  no 'origin' remote - committed locally only"
    report_unsynced
    return 0
  fi

  # Push. A force is only ever acceptable when the thing being overwritten is
  # one of our own parked commits - never someone's real work.
  if git push --quiet origin "$br" 2>/dev/null; then
    grn "  pushed to origin/$br"
  else
    git fetch --quiet origin "$br" 2>/dev/null || true
    local remote_subject; remote_subject="$(git log -1 --format=%s "origin/$br" 2>/dev/null || echo '')"
    case "$remote_subject" in
      "wip("*)
        if git push --quiet --force-with-lease origin "$br"; then
          grn "  pushed to origin/$br (replaced the old parked commit)"
        else
          die "push rejected. Someone else moved origin/$br - resolve by hand."
        fi
        ;;
      *)
        die "push rejected and origin/$br is real work, not a parked commit.
     Refusing to force. Run 'git pull --rebase' and try again."
        ;;
    esac
  fi

  report_unsynced
  echo
  grn "handed off. On the other machine run: devsync resume"
}

# ---------------------------------------------------------------- resume ----

cmd_resume() {
  local root; root="$(repo_root)"; cd "$root"
  local br mach; br="$(branch_name)"; mach="$(machine_name)"
  bold "devsync resume - $(basename "$root") [$br] on $mach"

  if ! git remote get-url origin >/dev/null 2>&1; then
    die "no 'origin' remote to resume from"
  fi

  # Refuse to clobber local edits that were never handed off.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    red "  you have uncommitted changes here."
    red "  Run 'devsync handoff' on THIS machine first, or stash them."
    exit 1
  fi

  local lock_before; lock_before="$(git_lockfile_hashes)"

  git fetch --quiet origin "$br"

  # The common round-trip: you parked here, worked on the other machine, and
  # came back. This machine still holds its own stale parked commit while the
  # remote holds the newer one, so the branches look diverged.
  #
  # A parked commit is disposable scaffolding - its content was pushed, and the
  # other machine resumed from it, so the newer parked commit already contains
  # it. Drop it, but ONLY when dropping it makes us fast-forwardable. If the
  # commit underneath is not on the remote, that is real unpushed work and we
  # must not touch it.
  local head_subject; head_subject="$(git log -1 --format=%s)"
  case "$head_subject" in
    "wip("*)
      if git merge-base --is-ancestor HEAD~1 "origin/$br" 2>/dev/null; then
        local dropped; dropped="$(git rev-parse --short HEAD)"
        git reset --quiet --hard HEAD~1
        dim "  dropped this machine's stale parked commit ($dropped)"
        dim "  recover it if ever needed with: git reflog / git show $dropped"
      fi
      ;;
  esac

  if git merge --ff-only "origin/$br" --quiet 2>/dev/null; then
    grn "  fast-forwarded to origin/$br"
  else
    yel "  branch diverged from origin/$br - not touching it automatically"
    dim "  inspect with: git log --oneline --graph HEAD origin/$br"
    exit 1
  fi

  # Unpack a parked commit back into your working tree, so you continue exactly
  # where you left off and the wip commit disappears from history.
  local subject; subject="$(git log -1 --format=%s)"
  case "$subject" in
    "wip("*)
      git reset --quiet --soft HEAD~1
      grn "  unpacked parked commit - your changes are staged and uncommitted"
      dim "  ($subject)"
      ;;
  esac

  decrypt_secrets

  local lock_after; lock_after="$(git_lockfile_hashes)"
  if [ "$lock_before" != "$lock_after" ]; then
    echo
    yel "dependency lockfile changed - reinstall before running:"
    [ -f package-lock.json ] && dim "    npm ci"
    [ -f pnpm-lock.yaml ]    && dim "    pnpm install --frozen-lockfile"
    [ -f yarn.lock ]         && dim "    yarn install --immutable"
    [ -f poetry.lock ]       && dim "    poetry install"
    [ -f uv.lock ]           && dim "    uv sync"
    [ -f requirements.txt ]  && dim "    pip install -r requirements.txt"
  fi

  echo
  grn "resumed. you are up to date."
}

git_lockfile_hashes() {
  git ls-files -s -- package-lock.json pnpm-lock.yaml yarn.lock poetry.lock uv.lock requirements.txt 2>/dev/null \
    | awk '{print $2}' | tr '\n' ' '
}

# --------------------------------------------------------------- add-key ----

# Register THIS machine as a recipient. Run once per machine, then commit and
# push dev-sync so the other machines learn about it.
cmd_addkey() {
  local kf mine label
  kf="$(age_key_file)"

  if [ -z "$kf" ]; then
    # No key here yet - make one. The private half never leaves this machine.
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) kf="${APPDATA:-$HOME/AppData/Roaming}/sops/age/keys.txt" ;;
      *)                    kf="$HOME/.config/sops/age/keys.txt" ;;
    esac
    mkdir -p "$(dirname "$kf")"
    age-keygen -o "$kf" >/dev/null 2>&1 || die "age-keygen failed"
    chmod 600 "$kf" 2>/dev/null || true
    grn "  generated a new age key for this machine"
    dim "    $kf"
  fi

  mine="$(age-keygen -y "$kf" 2>/dev/null | head -n1)"
  [ -n "$mine" ] || die "could not read a public key from $kf"

  [ -f "$RECIPIENTS_FILE" ] || die "missing $RECIPIENTS_FILE - pull the dev-sync repo"

  if grep -qF "$mine" "$RECIPIENTS_FILE"; then
    grn "  this machine is already a recipient"
    dim "    $mine"
    return 0
  fi

  label="$(machine_name)"
  printf '%s  # %s\n' "$mine" "$label" >> "$RECIPIENTS_FILE"
  grn "  added this machine as a recipient"
  dim "    $mine  # $label"
  echo
  bold "  next:"
  dim  "    cd $DEVSYNC_HOME && git add recipients.txt \\"
  dim  "      && git commit -m 'recipients: add $label' && git push"
  echo
  dim  "  Then in each repo that already has sealed secrets, run 'devsync rekey'"
  dim  "  so this machine can open them. Repos set up after this need nothing."
}

# ----------------------------------------------------------------- rekey ----

# Re-seal this repo's secrets for the CURRENT recipient list. Needed after a
# machine is added, because existing files were encrypted to the old list.
cmd_rekey() {
  local root; root="$(repo_root)"; cd "$root"
  bold "devsync rekey - $(basename "$root")"

  local pub; pub="$(age_recipients)"
  this_machine_is_recipient \
    || die "this machine's key is not in $RECIPIENTS_FILE - run: devsync add-key"

  # Refresh .sops.yaml so future files pick up the same list.
  cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: \\.env(\\..*)?\$
    age: $pub
EOF

  local n=0 f
  while IFS= read -r f; do
    local plain="${f%.sops}"
    # Decrypt with whatever key opens it today, re-seal to the full list.
    sops decrypt --input-type dotenv --output-type dotenv "$f" > "$plain.rekey.tmp" 2>/dev/null \
      || { rm -f "$plain.rekey.tmp"; die "cannot decrypt $f on this machine - rekey from a machine that can"; }
    sops encrypt --input-type dotenv --output-type dotenv --age "$pub" "$plain.rekey.tmp" > "$f.tmp" \
      || { rm -f "$plain.rekey.tmp" "$f.tmp"; die "failed to re-seal $f"; }
    mv "$f.tmp" "$f"; rm -f "$plain.rekey.tmp"
    grn "  re-sealed  $f"
    n=$((n + 1))
  done < <(encrypted_files)

  if [ "$n" -eq 0 ]; then
    dim "  no sealed files here - nothing to re-seal"
  fi
  echo
  grn "rekeyed for $(recipient_count) machine(s). Commit and push."
}

# ---------------------------------------------------------------- doctor ----

cmd_doctor() {
  bold "devsync doctor - $(machine_name)"
  local ok=0

  for tool in git sops age-keygen; do
    if command -v "$tool" >/dev/null 2>&1; then
      grn "  ok    $tool  ($(command -v "$tool"))"
    else
      red "  MISS  $tool is not on PATH"; ok=1
    fi
  done

  local kf; kf="$(age_key_file)"
  if [ -n "$kf" ]; then
    grn "  ok    age key  ($kf)"
    dim "        public: $(age-keygen -y "$kf" 2>/dev/null | head -n1)"
  else
    red "  MISS  no age key on this machine"
    dim "        create one and register it:  devsync add-key"
    ok=1
  fi

  # Recipients: every machine that can open sealed secrets.
  if [ -f "$RECIPIENTS_FILE" ]; then
    grn "  ok    recipients  ($(recipient_count) machine(s))"
    sed 's/#.*//' "$RECIPIENTS_FILE" | tr -d ' \t\r' | grep -E '^age1' | while read -r k; do
      local who; who="$(grep -F "$k" "$RECIPIENTS_FILE" | sed -n 's/.*#[[:space:]]*//p')"
      dim "        ${k:0:22}...  ${who:-unlabelled}"
    done
    if [ -n "$kf" ] && ! this_machine_is_recipient 2>/dev/null; then
      red "  MISS  this machine's key is NOT a recipient"
      dim "        it could seal secrets it can never reopen. Fix: devsync add-key"
      ok=1
    fi
  else
    red "  MISS  no recipients file ($RECIPIENTS_FILE)"
    dim "        pull the dev-sync repo, then: devsync add-key"
    ok=1
  fi

  # Roundtrip: prove sops can actually encrypt AND decrypt with this machine's
  # key. Catches path-resolution mismatches that existence checks cannot.
  if [ -n "$kf" ] && command -v sops >/dev/null 2>&1; then
    local tmp; tmp="${TMPDIR:-/tmp}/devsync-doctor-$$.env"
    printf 'DEVSYNC_DOCTOR=ok\n' > "$tmp"
    if sops encrypt --input-type dotenv --output-type dotenv \
         --age "$(age-keygen -y "$kf" 2>/dev/null | head -n1)" "$tmp" 2>/dev/null \
       | sops decrypt --input-type dotenv --output-type dotenv /dev/stdin 2>/dev/null \
       | grep -q 'DEVSYNC_DOCTOR=ok'; then
      grn "  ok    encrypt/decrypt roundtrip"
    else
      red "  MISS  sops cannot complete an encrypt/decrypt roundtrip"
      dim "        sops may be looking for the key somewhere else."
      dim "        expected: SOPS_AGE_KEY_FILE=$kf"
      ok=1
    fi
    rm -f "$tmp"
  fi

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    local root; root="$(repo_root)"
    dim "  repo: $(basename "$root") [$(branch_name)]"
    [ -f "$root/.sops.yaml" ] && grn "  ok    this repo is initialised" \
                              || yel "  todo  run 'devsync init' in this repo"
  fi

  [ "$ok" -eq 0 ] && { echo; grn "this machine is ready."; } \
                  || { echo; red "fix the MISS lines above first."; return 1; }
}

# ------------------------------------------------------------------ main ----

usage() {
  cat <<'EOF'
devsync - move a repo between machines without losing work or secrets

  devsync init      set this repo up for sync   (once per repo)
  devsync handoff   park + push, before leaving a machine
  devsync resume    pull + unpack, on arriving at a machine

  devsync add-key   register THIS machine as a secrets recipient (once per machine)
  devsync rekey     re-seal this repo's secrets after a machine was added
  devsync doctor    check tooling, keys, and recipients on this machine
EOF
}

case "${1:-}" in
  init)             shift; cmd_init "$@" ;;
  handoff)          shift; cmd_handoff "$@" ;;
  resume)           shift; cmd_resume "$@" ;;
  add-key|addkey)   shift; cmd_addkey "$@" ;;
  rekey)            shift; cmd_rekey "$@" ;;
  doctor)           shift; cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$1' (try: devsync help)" ;;
esac
