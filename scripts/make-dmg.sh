#!/usr/bin/env bash
# Packages a built apprentice binary as the release install: Apprentice.app in a DMG with an
# Applications link. The app holds the window (Contents/MacOS), the CLI and daemon (Contents/Helpers)
# and the repo's agent/, skills/ and playbooks/ (Contents/Resources/share), so it needs no clone and
# updates from GitHub releases (Release.swift).
#
#   scripts/make-dmg.sh <binary> <out-dir> [signing identity]
#
# With an identity (a "Developer ID Application" one in CI) both executables are signed with the
# hardened runtime and a timestamp; without one, ad hoc, for a local test.
set -euo pipefail

bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$2"
id="${3:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$out/Apprentice.app"

mkdir -p "$out"
rm -rf "$app" "$out/apprentice-macos.dmg"
# Building writes nothing into the user's own ~/.apprentice.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
HOME="$scratch" "$bin" app --bundle "$app" --release

mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/share"
cp "$bin" "$app/Contents/Helpers/apprentice"
for dir in agent skills playbooks; do
  ditto "$root/$dir" "$app/Contents/Resources/share/$dir"
done
# The docs the window's Help tab reads (an agent answering questions from them).
for doc in README.md SPEC.md FEATURES.md; do
  cp "$root/$doc" "$app/Contents/Resources/share/$doc"
done
find "$app/Contents/Resources/share" -name .DS_Store -delete

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
sign=(--force --options runtime)
if [ -n "$id" ]; then sign+=(--timestamp --sign "$id"); else sign+=(--sign -); fi
# Inside out: the helper first, keeping the CLI's own identifier, then the bundle around it.
codesign "${sign[@]}" --identifier apprentice "$app/Contents/Helpers/apprentice"
codesign "${sign[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

stage="$scratch/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/Apprentice.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "apprentice $version" -srcfolder "$stage" -ov -format UDZO "$out/apprentice-macos.dmg"
if [ -n "$id" ]; then codesign --force --timestamp --sign "$id" "$out/apprentice-macos.dmg"; fi
echo "built $out/apprentice-macos.dmg (apprentice $version)"
