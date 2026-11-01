#!/usr/bin/env bash
# Installs Tart, which runs the browser VM, into ~/Applications. Pinned and checked: Homebrew's tap
# formula breaks on current Homebrew, and a release download is only used if its checksum matches.
set -euo pipefail
version=2.41.1
sha=e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2
app="$HOME/Applications/tart.app"

for t in /opt/homebrew/bin/tart /usr/local/bin/tart "$app/Contents/MacOS/tart"; do
  if [ -x "$t" ]; then echo "tart is installed ($t)"; exit 0; fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/tart.tar.gz" "https://github.com/cirruslabs/tart/releases/download/$version/tart.tar.gz"
got="$(shasum -a 256 "$tmp/tart.tar.gz" | cut -d' ' -f1)"
if [ "$got" != "$sha" ]; then
  echo "tart $version download does not match its checksum; not installed" >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
tar -xzf "$tmp/tart.tar.gz" -C "$HOME/Applications" tart.app
echo "installed tart $version in $app"
