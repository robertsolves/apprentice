#!/usr/bin/env bash
# Cuts a release: bumps the version in Build.swift, builds, self-tests and packages the DMG locally,
# then commits and tags. It never pushes; it prints the one command that does, which starts release.yml.
#
#   scripts/release.sh 0.2.0
set -euo pipefail

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]]; then
  echo "usage: scripts/release.sh <version, e.g. 0.2.0>" >&2; exit 5
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "the tree has uncommitted changes: commit or stash them first" >&2; exit 5
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "v$version is already tagged" >&2; exit 5
fi

file=Sources/apprentice/Build.swift
current="$(sed -n 's/.*static let number = "\(.*\)".*/\1/p' "$file")"
echo "apprentice $current → $version"
sed -i '' "s/static let number = \"$current\"/static let number = \"$version\"/" "$file"
grep -qF "static let number = \"$version\"" "$file" || { echo "could not bump $file" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/apprentice"
HOME="$(mktemp -d)" "$bin" selftest
scripts/make-dmg.sh "$bin" "$(mktemp -d)" >/dev/null

git commit -q -m "Release v$version" -- "$file"
git tag -a "v$version" -m "apprentice v$version"
echo "tagged v$version. Publish it with:"
echo "  git push origin $(git branch --show-current) v$version"
