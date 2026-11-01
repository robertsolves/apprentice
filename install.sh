#!/usr/bin/env bash
# One-command install or update:
#   gh api repos/robertsolves/apprentice/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
# Asks for your GitHub account (or an organisation), forks the repo there, or reuses the fork you
# already have whatever it is called, and clones it to ~/.apprentice/src (or APPRENTICE_DIR), then
# runs kit.sh. The repo's owner gets a clone of the repo itself. An existing install is updated in
# place wherever it lives. apprentice commits its own fixes to that clone as you use it;
# `apprentice pr` sends them upstream and `apprentice update` brings in everyone else's.
# APPRENTICE_UPSTREAM=owner/name installs from another upstream repo.
set -euo pipefail

upstream="$(echo "${APPRENTICE_UPSTREAM:-robertsolves/apprentice}" | tr '[:upper:]' '[:lower:]')"
owner="${upstream%%/*}"

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

lower() { tr '[:upper:]' '[:lower:]'; }
die() { echo "$*" >&2; exit 1; }

# owner/name of a remote of the clone in $1, lower case, or nothing.
slug() {
  local url
  url="$(git -C "$1" remote get-url "$2" 2>/dev/null)" || return 0
  url="${url%.git}"
  echo "${url//://}" | awk -F/ '{print $(NF-1) "/" $NF}' | lower
}

# Whether owner/name is the upstream repo or a fork of it.
is_apprentice() {
  [ -n "$1" ] || return 1
  [ "$1" = "$upstream" ] && return 0
  [ "$(gh api "repos/$1" -q '.parent.full_name // ""' 2>/dev/null | lower)" = "$upstream" ]
}

# The account's fork of upstream, whatever it is called, or nothing.
find_fork() {
  gh api "repos/$upstream/forks" --paginate \
    -q ".[] | select((.owner.login | ascii_downcase) == \"$account\") | .full_name" 2>/dev/null | head -1 | lower || true
}

# The script arrives on stdin, so questions are read from the terminal.
tty=/dev/tty
[ -r "$tty" ] || tty=""
if ! gh auth status >/dev/null 2>&1; then
  [ -n "$tty" ] || die "sign in to GitHub first: gh auth login"
  gh auth login <"$tty"
fi
signed_in="$(gh api user -q .login | lower)"
account="$signed_in"
if [ -n "$tty" ]; then
  printf 'GitHub account or organisation to fork apprentice into [%s]: ' "$signed_in"
  read -r answer <"$tty" || true
  account="$(echo "${answer:-$signed_in}" | lower)"
fi
org=""
if [ "$account" != "$signed_in" ]; then
  if [ "$(gh api "users/$account" -q .type 2>/dev/null)" = "Organization" ]; then
    org="$account"
  else
    gh auth switch --user "$account" >/dev/null 2>&1 || gh auth login <"${tty:-/dev/null}"
    [ "$(gh api user -q .login | lower)" = "$account" ] || die "gh is not signed in as $account"
  fi
fi
# git uses gh's login for https, so fetch and push work on the private repo.
gh auth setup-git

# Where your commits go: the repo itself for its owner, otherwise your fork, made if needed.
fork=""
if [ "$account" != "$owner" ]; then
  fork="$(find_fork)"
  if [ -n "$fork" ]; then
    echo "using your fork $fork"
  else
    echo "forking $upstream into $account…"
    gh repo fork "$upstream" --clone=false --default-branch-only ${org:+--org "$org"} >/dev/null 2>&1 || true
    # A new fork can take a few seconds to appear.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      fork="$(find_fork)"
      [ -n "$fork" ] && break
      sleep 5
    done
    [ -n "$fork" ] || die "could not fork $upstream into $account: ask for access to $upstream"
  fi
fi
repo="${fork:-$upstream}"

# The clone: APPRENTICE_DIR, else the one an earlier install linked ~/.apprentice/notes to
# (the owner's working copy, say), else ~/.apprentice/src.
dir="${APPRENTICE_DIR:-}"
if [ -z "$dir" ] && [ -L "$HOME/.apprentice/notes" ]; then
  linked="$(cd -P "$HOME/.apprentice/notes" 2>/dev/null && cd .. && pwd)" || linked=""
  if [ -n "$linked" ] && [ -d "$linked/.git" ]; then dir="$linked"; fi
fi
dir="${dir:-$HOME/.apprentice/src}"

fresh=""
if [ -d "$dir/.git" ]; then
  is_apprentice "$(slug "$dir" origin)" || is_apprentice "$(slug "$dir" upstream)" ||
    die "$dir is a clone of something else; move it or set APPRENTICE_DIR to another folder"
elif [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
  die "$dir exists and is not a clone of apprentice; move it or set APPRENTICE_DIR to another folder"
else
  echo "cloning $repo into $dir…"
  mkdir -p "$(dirname "$dir")"
  git clone -q "https://github.com/$repo.git" "$dir"
  fresh=1
fi

# Remotes as Repo.swift expects them: origin is where your commits go, and a fork also has
# upstream. A plain clone of the repo by someone else gets their fork as origin.
if [ -n "$fork" ]; then
  if ! git -C "$dir" remote | grep -qx upstream; then
    if [ "$(slug "$dir" origin)" = "$upstream" ]; then
      git -C "$dir" remote rename origin upstream
    else
      git -C "$dir" remote add upstream "https://github.com/$upstream.git"
    fi
  fi
  if ! git -C "$dir" remote | grep -qx origin; then
    git -C "$dir" remote add origin "https://github.com/$fork.git"
  elif [ "$(slug "$dir" origin)" != "$fork" ]; then
    echo "pointing origin at $fork"
    git -C "$dir" remote set-url origin "https://github.com/$fork.git"
  fi
fi

if [ -z "$fresh" ]; then
  remote=origin
  git -C "$dir" remote | grep -qx upstream && remote=upstream
  base="$(git -C "$dir" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null)" || base=""
  base="${base#"$remote"/}"
  base="${base:-main}"
  branch="$(git -C "$dir" branch --show-current)"
  if [ "$branch" != "$base" ]; then
    echo "$dir is on ${branch:-a detached HEAD}, not $base; left as it is"
  else
    echo "updating $dir…"
    git -C "$dir" fetch -q "$remote"
    git -C "$dir" rebase -q --autostash "$remote/$base" || {
      git -C "$dir" rebase --abort
      die "your commits in $dir conflict with $remote; nothing changed. Resolve by hand: git -C $dir rebase $remote/$base"
    }
  fi
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
