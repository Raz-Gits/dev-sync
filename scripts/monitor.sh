#!/usr/bin/env bash
#
# monitor.sh - bridge health sweep. Quiet unless something needs attention.
#
#   bash monitor.sh [root-dir]        default: $HOME
#
# Checks every git repo for the things the daily /handoff -> /resume loop can
# silently miss: work left behind without a handoff, secrets that exist only
# as plaintext, seals that have gone stale, and plaintext that ended up
# tracked by git.
#
# Exit 0 = all clear. Exit 1 = at least one repo needs attention.
# Read-only. Changes nothing, anywhere.
#
# Ignore rules live in ../monitor-ignore.txt (see comments there). Lines:
#   repo:<substring>      skip a repo entirely
#   secrets:<substring>   skip only the secret checks for a repo
#   stash:<substring>     skip only the stash check for a repo
#
# bash-3.2 compatible; BSD-safe find flags; works under Git Bash on Windows.

set -uo pipefail

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

ROOT="${1:-$HOME}"
[ -d "$ROOT" ] || { red "not a directory: $ROOT"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNORE_FILE="$HERE/../monitor-ignore.txt"

# sops resolves its default key via Go os.UserConfigDir() (~/Library/Application
# Support on macOS), not ~/.config. Point it at the key devsync manages.
if [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  for c in "$HOME/.config/sops/age/keys.txt" \
           "${APPDATA:-$HOME/AppData/Roaming}/sops/age/keys.txt"; do
    [ -f "$c" ] && export SOPS_AGE_KEY_FILE="$c" && break
  done
fi

ignored() {  # $1 = rule prefix, $2 = repo display name
  local prefix="$1" name="$2" line pat
  [ -f "$IGNORE_FILE" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      \#*|'') continue ;;
      "$prefix":*)
        pat="${line#"$prefix":}"
        case "$name" in *"$pat"*) return 0 ;; esac ;;
    esac
  done < "$IGNORE_FILE"
  return 1
}

# Same normalization the devsync seal-check uses: the sops dotenv store drops
# blank lines, so compare modulo blanks or every sealed file looks stale.
same_dotenv() {  # $1 = plaintext file; stdin = decrypted content
  local a b
  a="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null)"
  b="$(grep -v '^[[:space:]]*$')"
  [ "$a" = "$b" ]
}

n_repos=0; n_flagged=0
issues=""
add() { issues="${issues}\n    $*"; }

while IFS= read -r -d '' gitdir; do
  repo="$(dirname "$gitdir")"
  cd "$repo" 2>/dev/null || continue
  name="${repo#"$ROOT"/}"; [ "$name" = "$repo" ] && name="$repo"

  ignored repo "$name" && continue
  n_repos=$((n_repos + 1))
  issues=""

  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

  # Empty init with nothing in it: nothing can be lost, skip silently.
  if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    [ -z "$(git status --porcelain 2>/dev/null)" ] && continue
  fi

  # 1. Work sitting here that a /handoff would have carried across.
  n_dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n_dirty:-0}" -gt 0 ] && add "${n_dirty} uncommitted change(s) - left without /handoff?"

  # 2. Current branch ahead of (or unknown to) the remote.
  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "${ahead:-0}" -gt 0 ] && add "${ahead} unpushed commit(s) on ${branch}"
  elif git remote get-url origin >/dev/null 2>&1 \
       && git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    add "branch '${branch}' has never been pushed"
  fi

  # 3. No remote at all - this repo exists nowhere but here.
  git remote get-url origin >/dev/null 2>&1 || add "NO REMOTE - exists only on this machine"

  # 4. Stashes: invisible to every remote, easy to forget.
  if ! ignored stash "$name"; then
    stashes="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
    [ "${stashes:-0}" -gt 0 ] && add "${stashes} stash(es) that will not travel"
  fi

  # 5. Secrets: plaintext without a sealed twin, stale seals, tracked plaintext.
  if ! ignored secrets "$name"; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        add "SECRET TRACKED BY GIT: $f - it will be pushed in plaintext. Run /sync-setup."
      fi
      if [ ! -f "$f.sops" ]; then
        add "secret not sealed: $f (run /sync-setup, then /handoff)"
      elif command -v sops >/dev/null 2>&1; then
        if out="$(sops decrypt --input-type dotenv --output-type dotenv "$f.sops" 2>/dev/null)"; then
          printf '%s\n' "$out" | same_dotenv "$f" \
            || add "seal is STALE: $f changed since $f.sops (run /handoff)"
        else
          add "cannot decrypt $f.sops on this machine - key problem? run: devsync doctor"
        fi
      fi
    done < <(find . \( -name node_modules -o -name .venv -o -name venv -o -name .git \
                       -o -name vendor -o -name .cache -o -name __pycache__ \) -prune -o \
               -type f -name '.env*' -print 2>/dev/null \
             | sed 's|^\./||' \
             | grep -E '(^|/)\.env(\.[A-Za-z0-9_-]+)?$' \
             | grep -vE '\.(example|sample|template|sops|bak-devsync)$')
  fi

  if [ -n "$issues" ]; then
    n_flagged=$((n_flagged + 1))
    yel "  $name  [$branch]"
    printf "$issues\n"
    echo
  fi
done < <(find "$ROOT" \
    \( -name node_modules -o -name .venv -o -name venv -o -name Library \
       -o -name .Trash -o -name vendor -o -name .cache \
       -o -name .codex -o -name .cursor -o -name .claude \) -prune -o \
    -type d -name .git -print0 2>/dev/null)

# Machine-level health: no key means nothing new can be sealed or opened.
if [ -z "${SOPS_AGE_KEY_FILE:-}" ] || [ ! -f "${SOPS_AGE_KEY_FILE:-/nonexistent}" ]; then
  red "NO AGE KEY on this machine - run: devsync doctor"
  n_flagged=$((n_flagged + 1))
fi

if [ "$n_flagged" -eq 0 ]; then
  grn "bridge healthy: $n_repos repos checked, nothing stranded, all secrets sealed."
  exit 0
else
  bold "$n_flagged of $n_repos repos need attention (see above)."
  dim  "fix-it moves: /handoff parks and pushes; /sync-setup seals a new repo's secrets."
  exit 1
fi
