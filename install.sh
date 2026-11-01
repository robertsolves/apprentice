#!/usr/bin/env bash
# One-command install or update, from a clone:
#   git clone https://github.com/robertsolves/apprentice.git ~/.apprentice/src && ~/.apprentice/src/install.sh
# or piped (APPRENTICE_UPSTREAM is any git URL: a server, a folder, another Mac's clone):
#   curl -fsSL <raw install.sh> | APPRENTICE_UPSTREAM=<git url> bash
# The clone is your own copy. apprentice commits its fixes there and they stay there; `upstream` is only
# fetched, and apprentice updates itself from it (set [update] auto = false in config.toml to only be told).
# An existing install is updated in place wherever it lives.
set -euo pipefail

url="${APPRENTICE_UPSTREAM:-https://github.com/robertsolves/apprentice.git}"

if [ "$(uname)" != "Darwin" ]; then echo "apprentice needs macOS" >&2; exit 1; fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then echo "apprentice needs macOS 14 or later (this is $(sw_vers -productVersion))" >&2; exit 1; fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install the command-line tools, then run this again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

die() { echo "$*" >&2; exit 1; }

# The clone: the one this script runs from, else APPRENTICE_DIR, else the one an earlier install linked
# ~/.apprentice/notes to, else ~/.apprentice/src.
dir="${APPRENTICE_DIR:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)" || here=""
if [ -z "$dir" ] && [ -n "$here" ] && [ -f "$here/kit.sh" ] && [ -d "$here/.git" ]; then dir="$here"; fi
if [ -z "$dir" ] && [ -L "$HOME/.apprentice/notes" ]; then
  linked="$(cd -P "$HOME/.apprentice/notes" 2>/dev/null && cd .. && pwd)" || linked=""
  if [ -n "$linked" ] && [ -d "$linked/.git" ]; then dir="$linked"; fi
fi
dir="${dir:-$HOME/.apprentice/src}"

if [ -d "$dir/.git" ]; then
  [ -f "$dir/kit.sh" ] && [ -d "$dir/Sources/apprentice" ] ||
    die "$dir is a clone of something else; move it or set APPRENTICE_DIR to another folder"
elif [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
  die "$dir exists and is not a clone of apprentice; move it or set APPRENTICE_DIR to another folder"
else
  echo "cloning $url into $dir…"
  mkdir -p "$(dirname "$dir")"
  git clone -q -o upstream "$url" "$dir"
  # Fetch only: your commits stay in this clone.
  git -C "$dir" remote set-url --push upstream no-push
fi

# Updates come from `upstream`; a clone made before it had that name uses origin.
remote=origin
git -C "$dir" remote | grep -qx upstream && remote=upstream
base="$(git -C "$dir" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null)" || base=""
base="${base#"$remote"/}"
base="${base:-main}"
branch="$(git -C "$dir" branch --show-current)"
if [ "$branch" != "$base" ]; then
  echo "$dir is on ${branch:-a detached HEAD}, not $base; left as it is"
else
  echo "updating $dir from $remote…"
  git -C "$dir" fetch -q "$remote" || echo "warning: could not fetch $remote; installing what is here"
  git -C "$dir" rebase -q --autostash "$remote/$base" 2>/dev/null || {
    git -C "$dir" rebase --abort 2>/dev/null || true
    die "your commits in $dir conflict with $remote; nothing changed. Resolve by hand: git -C $dir rebase $remote/$base"
  }
fi
# apprentice commits its own fixes, so the clone needs an author.
git -C "$dir" config user.name >/dev/null || git -C "$dir" config user.name "apprentice"
git -C "$dir" config user.email >/dev/null || git -C "$dir" config user.email "apprentice@$(hostname -s 2>/dev/null || echo mac).local"

"$dir/kit.sh"
