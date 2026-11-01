#!/usr/bin/env bash
# One-command install or update:
#   gh api repos/robertsolves/apprentice/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
# Clones the repo to ~/.apprentice/src (or APPRENTICE_DIR), pulls if it is already there,
# then runs kit.sh. Run it again to update.
set -euo pipefail

repo="robertsolves/apprentice"
dir="${APPRENTICE_DIR:-$HOME/.apprentice/src}"

if [ "$(uname)" != "Darwin" ]; then echo "apprentice needs macOS" >&2; exit 1; fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then echo "apprentice needs macOS 14 or later (this is $(sw_vers -productVersion))" >&2; exit 1; fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is missing. Install the command-line tools, then run this again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if [ -d "$dir/.git" ]; then
  echo "updating $dir…"
  git -C "$dir" pull --ff-only
else
  echo "cloning $repo into $dir…"
  mkdir -p "$(dirname "$dir")"
  # The repo is private: gh uses your GitHub login, git falls back to your SSH key.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$repo" "$dir"
  else
    git clone "git@github.com:$repo.git" "$dir"
  fi
fi

exec "$dir/kit.sh"
