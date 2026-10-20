#!/usr/bin/env bash
#
# Set this machine up for devsync.
#
#   git clone git@github.com:Raz-Gits/dev-sync.git ~/dev-sync
#   bash ~/dev-sync/install.sh
#
# Idempotent - safe to re-run after pulling updates.

set -euo pipefail

grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
BIN_DIR="$HOME/bin"

case "$(uname -s)" in
  Darwin*) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Linux*) OS=linux ;;
  *) OS=unknown ;;
esac

bold "devsync install  (detected: $OS)"

# ------------------------------------------------------------- 1. tooling ----

mkdir -p "$BIN_DIR"

need() { ! command -v "$1" >/dev/null 2>&1; }

if need sops || need age-keygen; then
  case "$OS" in
    mac)
      if command -v brew >/dev/null 2>&1; then
        need sops       && { brew install sops; }
        need age-keygen && { brew install age; }
      else
        red "Homebrew not found. Install it first:"
        dim '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        exit 1
      fi
      ;;
    windows)
      red "Missing sops and/or age. In PowerShell:"
      dim '  winget install --id FiloSottile.age -e'
      dim '  then download sops.exe from https://github.com/getsops/sops/releases'
      dim "  into $BIN_DIR"
      exit 1
      ;;
    *)
      red "Install 'sops' and 'age' with your package manager, then re-run."
      exit 1
      ;;
  esac
fi
grn "  tooling present: sops, age"

# gitleaks guards the Obsidian vault's commits. Optional: without it the vault
# still syncs, it just isn't checked for secrets.
if need gitleaks; then
  case "$OS" in
    mac) command -v brew >/dev/null 2>&1 && brew install gitleaks ;;
    windows) yel "  gitleaks missing (vault secret check). In PowerShell: winget install gitleaks" ;;
    *) yel "  gitleaks missing (vault secret check). Install it with your package manager." ;;
  esac
fi

# graphify builds the code graphs that /resume refreshes. Same version on every
# machine, so both build the same graph and get the same Claude skill.
GRAPHIFY_VERSION="0.7.11"
if need graphify; then
  if need pipx && [ "$OS" = mac ] && command -v brew >/dev/null 2>&1; then
    brew install pipx
  fi
  if command -v pipx >/dev/null 2>&1; then
    pipx install "graphifyy==$GRAPHIFY_VERSION" && pipx ensurepath >/dev/null 2>&1 || true
  elif [ "$OS" = windows ]; then
    yel "  graphify missing (code graphs). In PowerShell:"
    dim "    py -m pip install --user pipx; py -m pipx ensurepath"
    dim "  then reopen Git Bash and re-run install.sh"
  else
    yel "  graphify missing (code graphs): install pipx, then re-run install.sh"
  fi
fi
if command -v graphify >/dev/null 2>&1; then
  [ -f "$HOME/.claude/skills/graphify/SKILL.md" ] || graphify install >/dev/null 2>&1 || true
  grn "  graphify present ($(cat "$HOME/.claude/skills/graphify/.graphify_version" 2>/dev/null | head -1 || echo 'version unknown'))"
fi

# Graphs are rebuilt per machine and must never be committed (a /handoff runs
# git add -A), so ignore graphify-out/ in every repo on this machine.
ignore_file="$(git config --global core.excludesFile 2>/dev/null || true)"
case "$ignore_file" in "~/"*) ignore_file="$HOME/${ignore_file#\~/}" ;; esac
ignore_file="${ignore_file:-${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore}"
mkdir -p "$(dirname "$ignore_file")" && touch "$ignore_file"
if ! grep -qxF 'graphify-out/' "$ignore_file"; then
  printf '# graphify code graphs: rebuilt per machine, never committed (devsync)\ngraphify-out/\n' >> "$ignore_file"
fi
grn "  graphify-out/ is ignored in every repo ($ignore_file)"

# --------------------------------------------------------------- 2. skills ----

mkdir -p "$SKILLS_DIR"
for skill in "$HERE"/skills/*/; do
  name="$(basename "$skill")"
  target="$SKILLS_DIR/$name"
  rm -rf "$target"
  # Symlink so a `git pull` in ~/dev-sync updates the skills with no reinstall.
  # Under MSYS/Git Bash `ln -s` exits 0 but silently COPIES unless Developer
  # Mode is on, so trust the -L test rather than the exit code.
  ln -s "$skill" "$target" 2>/dev/null || true
  if [ -L "$target" ]; then
    grn "  linked  /$name"
  else
    rm -rf "$target"; cp -R "$skill" "$target"
    yel "  copied  /$name"
    COPIED=1
  fi
done

if [ "${COPIED:-0}" = "1" ]; then
  echo
  yel "  Skills were copied, not linked (no symlink support on this machine)."
  yel "  After 'git pull' in ~/dev-sync, re-run install.sh to pick up changes."
fi

# ------------------------------------------------------------------ 3. PATH ----

add_path_line='export PATH="$HOME/bin:$PATH"'
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  [ -f "$rc" ] || continue
  grep -qF "$add_path_line" "$rc" 2>/dev/null || {
    printf '\n# devsync\n%s\n' "$add_path_line" >> "$rc"
    grn "  added \$HOME/bin to PATH in $(basename "$rc")"
  }
done

# Optional convenience: `devsync` callable directly.
cat > "$BIN_DIR/devsync" <<EOF
#!/usr/bin/env bash
exec bash "$HERE/scripts/devsync.sh" "\$@"
EOF
chmod +x "$BIN_DIR/devsync"
grn "  installed 'devsync' command"

# ----------------------------------------------------------------- 4. vault ----

# The Obsidian vault travels with every handoff/resume. Clone it if this
# machine doesn't have it yet, then apply its per-clone git settings.
VAULT="${DEVSYNC_VAULT:-$HOME/Main Brain}"
VAULT_REPO="${DEVSYNC_VAULT_REPO:-Raz-Gits/main-brain}"
echo
if [ -d "$VAULT/.git" ]; then
  grn "  vault present: $VAULT"
elif { command -v gh >/dev/null 2>&1 && gh repo clone "$VAULT_REPO" "$VAULT" -- --quiet; } \
     || git clone --quiet "https://github.com/$VAULT_REPO.git" "$VAULT"; then
  grn "  cloned vault to $VAULT"
  dim "    in Obsidian: Open folder as vault -> $VAULT -> Trust author and enable plugins"
else
  yel "  could not clone the vault ($VAULT_REPO) - clone it by hand, then re-run"
fi
[ -f "$VAULT/scripts/setup-machine.sh" ] && bash "$VAULT/scripts/setup-machine.sh" | sed 's/^/    /'

# ------------------------------------------------------------------- 5. key ----

KEY_MAC="$HOME/.config/sops/age/keys.txt"
KEY_WIN="${APPDATA:-$HOME/AppData/Roaming}/sops/age/keys.txt"
KEY=""
[ -f "$KEY_MAC" ] && KEY="$KEY_MAC"
[ -z "$KEY" ] && [ -f "$KEY_WIN" ] && KEY="$KEY_WIN"

echo
# This machine gets its OWN keypair. The private half never leaves it; the
# public half goes in recipients.txt so secrets get sealed to this machine too.
# Nothing secret has to travel between machines, ever.
if [ -z "$KEY" ]; then
  bold "  no age key here yet - generating one for this machine"
fi

bash "$HERE/scripts/devsync.sh" add-key || {
  red "  add-key failed - run it manually: devsync add-key"
  exit 1
}

echo
if git -C "$HERE" diff --quiet -- recipients.txt 2>/dev/null; then
  bold "this machine is ready. try: devsync doctor"
else
  yel "  recipients.txt changed - push it so your other machines learn this key:"
  dim  "    cd $HERE && git add recipients.txt \\"
  dim  "      && git commit -m 'recipients: add $(hostname)' && git push"
  echo
  dim  "  Then on repos that ALREADY have sealed secrets, run 'devsync rekey'"
  dim  "  from a machine that can currently open them."
fi
