#!/usr/bin/env bash
# One-command install or update:
#   gh api repos/robertsolves/apprentice/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
# Asks for your GitHub account, forks the repo there and clones the fork to ~/.apprentice/src
# (or APPRENTICE_DIR), then runs kit.sh. apprentice commits its own fixes to that clone as you
# use it; `apprentice pr` sends them upstream and `apprentice update` brings in everyone else's.
set -euo pipefail

upstream="robertsolves/apprentice"
dir="${APPRENTICE_DIR:-$HOME/.apprentice/src}"

if [ "$(uname)" != "Darwin" ]; then echo "apprentice needs macOS" >&2; exit 1; fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then echo "apprentice needs macOS 14 or later (this is $(sw_vers -productVersion))" >&2; exit 1; fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install the command-line tools, then run this again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "The GitHub CLI is missing. Install it, then run this again:" >&2
  echo "  brew install gh" >&2
  exit 1
fi

# The script arrives on stdin, so questions are read from the terminal.
tty=/dev/tty
[ -r "$tty" ] || tty=""
if ! gh auth status >/dev/null 2>&1; then
  [ -n "$tty" ] || { echo "sign in to GitHub first: gh auth login" >&2; exit 1; }
  gh auth login <"$tty"
fi
signed_in="$(gh api user -q .login)"
account="$signed_in"
if [ -n "$tty" ]; then
  printf 'GitHub account to fork apprentice into [%s]: ' "$signed_in"
  read -r answer <"$tty" || true
  account="${answer:-$signed_in}"
fi
if [ "$account" != "$signed_in" ]; then
  gh auth switch --user "$account" >/dev/null 2>&1 || gh auth login <"${tty:-/dev/null}"
  [ "$(gh api user -q .login)" = "$account" ] || { echo "gh is not signed in as $account" >&2; exit 1; }
fi
# git uses gh's login for https, so fetch and push work on the private repo.
gh auth setup-git

if [ -d "$dir/.git" ]; then
  echo "updating $dir…"
  remote=origin
  git -C "$dir" remote | grep -qx upstream && remote=upstream
  git -C "$dir" fetch -q "$remote"
  git -C "$dir" rebase -q --autostash "$remote/main" || {
    git -C "$dir" rebase --abort
    echo "your commits in $dir conflict with $remote; nothing changed. Resolve by hand: git -C $dir rebase $remote/main" >&2
    exit 1
  }
elif [ "$account" = "${upstream%%/*}" ]; then
  echo "cloning $upstream into $dir…"
  mkdir -p "$(dirname "$dir")"
  gh repo clone "$upstream" "$dir"
else
  echo "forking $upstream into $account…"
  gh repo fork "$upstream" --clone=false --default-branch-only >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$dir")"
  # A new fork can take a few seconds to appear.
  for _ in 1 2 3 4 5 6; do
    gh repo clone "$account/${upstream#*/}" "$dir" 2>/dev/null && break
    sleep 5
  done
  [ -d "$dir/.git" ] || { echo "could not clone $account/${upstream#*/}: ask for access to $upstream" >&2; exit 1; }
  git -C "$dir" remote | grep -qx upstream || git -C "$dir" remote add upstream "https://github.com/$upstream.git"
fi
git -C "$dir" config user.name >/dev/null || git -C "$dir" config user.name "$account"
git -C "$dir" config user.email >/dev/null || git -C "$dir" config user.email "$account@users.noreply.github.com"

# Settings: this Mac only, or a private repo every Mac you install on shares.
store="local"
if [ -d "$HOME/.apprentice/settings/.git" ]; then
  store="github"
elif [ -n "$tty" ]; then
  echo "Where should apprentice keep your settings (config.toml, routes.toml)?"
  echo "  1) on this Mac only"
  echo "  2) in a private GitHub repo, $account/apprentice-settings, shared by every Mac you install on"
  printf 'Choose 1 or 2 [1]: '
  read -r choice <"$tty" || true
  [ "${choice:-1}" = "2" ] && store="github"
fi

"$dir/kit.sh"
if [ "$store" = "github" ]; then
  "$HOME/.local/bin/apprentice" settings github
fi
