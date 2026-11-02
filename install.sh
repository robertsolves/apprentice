#!/usr/bin/env bash
# One-command install or update, from a clone:
#   git clone https://github.com/robertsolves/apprentice.git ~/.apprentice/src && ~/.apprentice/src/install.sh
# or piped (APPRENTICE_UPSTREAM is any git URL: a server, a folder, another Mac's clone):
#   curl -fsSL <raw install.sh> | APPRENTICE_UPSTREAM=<git url> bash
# The clone is your own copy. apprentice commits its fixes there and they stay there; `upstream` is only
# fetched, and apprentice updates itself from it (set [update] auto = false in config.toml to only be told).
# An existing install is updated in place wherever it lives.
#
# Which version: a new install takes the latest release (the newest vX.Y.Z tag upstream; main if there is
# none yet) and then updates itself from release to release. Run again, it keeps what the clone follows.
#   install.sh --latest          follow releases
#   install.sh --version 0.2.0   a specific release (v0.2.0 works too), which stays until you run this again
#   install.sh --main            the tip of main, the development version, which keeps itself up to date
# Your own commits in the clone are kept on top of whichever version you pick.
set -euo pipefail

want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || { echo "--version needs a version, e.g. --version 0.2.0" >&2; exit 2; }; want="${2#v}"; shift 2 ;;
    --version=*) want="${1#--version=}"; want="${want#v}"; shift ;;
    --main) want=main; shift ;;
    --latest) want=latest; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    *) echo "unknown option: $1 (try --version X.Y.Z, --main or --help)" >&2; exit 2 ;;
  esac
done

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
# ~/.apprentice/playbooks (or, before the rename, ~/.apprentice/notes) to, else ~/.apprentice/src.
dir="${APPRENTICE_DIR:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)" || here=""
if [ -z "$dir" ] && [ -n "$here" ] && [ -f "$here/kit.sh" ] && [ -d "$here/.git" ]; then dir="$here"; fi
for link in "$HOME/.apprentice/playbooks" "$HOME/.apprentice/notes"; do
  if [ -z "$dir" ] && [ -L "$link" ]; then
    # An old notes link may dangle after the rename, so resolve the link itself, not the folder.
    linked="$(cd "$(dirname "$(readlink "$link")")" 2>/dev/null && pwd)" || linked=""
    if [ -n "$linked" ] && [ -d "$linked/.git" ]; then dir="$linked"; fi
  fi
done
dir="${dir:-$HOME/.apprentice/src}"

if [ -d "$dir/.git" ]; then
  [ -f "$dir/kit.sh" ] && [ -d "$dir/Sources/apprentice" ] ||
    die "$dir is a clone of something else; move it or set APPRENTICE_DIR to another folder"
elif [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
  die "$dir exists and is not a clone of apprentice; move it or set APPRENTICE_DIR to another folder"
else
  fresh=1
  echo "cloning $url into ${dir}…"
  mkdir -p "$(dirname "$dir")"
  git clone -q -o upstream "$url" "$dir"
  # Fetch only: your commits stay in this clone.
  git -C "$dir" remote set-url --push upstream no-push
fi

# No flag: what the clone already follows; a new clone follows releases, an older one main.
if [ -z "$want" ]; then
  want="$(git -C "$dir" config --get apprentice.follow 2>/dev/null)" || want=""
  want="${want#v}"
  [ "$want" = release ] && want=latest
  [ -z "$want" ] && { [ "${fresh:-0}" = 1 ] && want=latest || want=main; }
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
  echo "updating $dir from ${remote}…"
  git -C "$dir" fetch -q --tags "$remote" || echo "warning: could not fetch $remote; installing what is here"
  # The target: a release tag (the newest stable one, or the one asked for), else the tip of the base branch.
  target="$remote/$base"
  case "$want" in
    main) ;;
    latest)
      tag="$(git -C "$dir" tag -l 'v[0-9]*.[0-9]*.[0-9]*' | grep -Ev -- '-' | sort -V | tail -1)"
      if [ -n "$tag" ]; then target="refs/tags/$tag"; else echo "no release yet; installing $base"; fi ;;
    *)
      git -C "$dir" rev-parse -q --verify "refs/tags/v$want" >/dev/null ||
        die "there is no release v$want. Releases: $(git -C "$dir" tag -l 'v[0-9]*' | sort -V | tr '\n' ' ')"
      target="refs/tags/v$want" ;;
  esac
  echo "installing ${target#refs/tags/}"
  # Replays only your own commits (the ones upstream's branch does not have) on the target, so this moves
  # forward or back between releases.
  git -C "$dir" rebase -q --autostash --onto "$target" "$remote/$base" 2>/dev/null || {
    git -C "$dir" rebase --abort 2>/dev/null || true
    die "your commits in $dir conflict with ${target#refs/tags/}; nothing changed. Resolve by hand: git -C $dir rebase --onto $target $remote/$base"
  }
  # What the daemon's auto-update follows from now on (`Repo.follow`): the newest release, this one, or main.
  case "$want" in
    latest) git -C "$dir" config apprentice.follow release ;;
    *) git -C "$dir" config apprentice.follow "$want" ;;
  esac
fi
# apprentice commits its own fixes, so the clone needs an author.
git -C "$dir" config user.name >/dev/null || git -C "$dir" config user.name "apprentice"
git -C "$dir" config user.email >/dev/null || git -C "$dir" config user.email "apprentice@$(hostname -s 2>/dev/null || echo mac).local"

"$dir/kit.sh"

# The browser VM: Tart and a small Debian guest with Chromium (under 1 GB to download, about 2 GB on
# disk), so the agent browses with its own cursor and keyboard. APPRENTICE_SKIP_VM=1 skips it.
if [ "${APPRENTICE_SKIP_VM:-0}" != 1 ]; then
  bash "$dir/agent/vm/get-tart.sh" && env -u APPRENTICE_VM "$HOME/.local/bin/apprentice" vm setup ||
    echo "warning: the browser VM is not set up; run \`apprentice vm setup\` later"
fi

# Checks the permissions, signature, PATH and clone. In a terminal it opens the two Privacy panes, waits for
# the grants and runs a smoke test on Finder; piped, it only reports.
if [ -t 0 ] && [ -t 1 ]; then
  "$HOME/.local/bin/apprentice" doctor --fix || echo "run \`apprentice doctor --fix\` once you are ready to grant the permissions"
else
  "$HOME/.local/bin/apprentice" doctor || true
fi

echo
echo "installed. Now ask your agent to do something on your Mac, e.g.:"
echo "  “Download my January internet bill and put it in ~/Documents/Bills.”"
