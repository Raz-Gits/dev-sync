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

# ------------------------------------------------------------------- 4. key ----

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
