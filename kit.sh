#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.deskkontrol/replays" "$HOME/.claude/skills/deskkontrol"

echo "building release…"
(cd "$root" && swift build -c release)

bin="$HOME/.local/bin/deskkontrol"
mkdir -p "$(dirname "$bin")"
cp "$root/.build/release/deskkontrol" "$bin"

id="${DESKKONTROL_SIGN_IDENTITY:-}"
if [ -z "$id" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "deskkontrol"; then
  id="deskkontrol"
fi
if [ -n "$id" ]; then
  codesign --force --sign "$id" "$bin"
  echo "signed with $id (permissions survive rebuilds)"
else
  codesign --force --sign - "$bin" 2>/dev/null || true
  echo "warning: ad-hoc signed. Set DESKKONTROL_SIGN_IDENTITY to a stable local identity"
  echo "         so Accessibility and Screen Recording grants survive rebuilds."
fi

cp "$root/agent/SKILL.md" "$HOME/.claude/skills/deskkontrol/SKILL.md"

agents="$HOME/.config/opencode/AGENTS.md"
mkdir -p "$(dirname "$agents")"
if touch "$agents" && ! grep -q "<!-- deskkontrol -->" "$agents" 2>/dev/null; then
  printf '\n<!-- deskkontrol -->\n' >> "$agents"
  cat "$root/agent/AGENTS.md" >> "$agents"
  echo "appended the deskkontrol section to $agents"
fi

# Notes live in the repo, so `git pull` brings in what was learned on other machines,
# and `deskkontrol learn` writes new flows straight into the working tree to commit.
notes="$HOME/.deskkontrol/notes"
if [ -L "$notes" ] || [ ! -e "$notes" ]; then
  ln -sfn "$root/notes" "$notes"
  echo "linked $notes → $root/notes"
else
  echo "warning: $notes is a real folder; move its files into $root/notes, delete it, and re-run"
fi

if [ ! -f "$HOME/.deskkontrol/config.toml" ]; then
  cp "$root/agent/config.example.toml" "$HOME/.deskkontrol/config.toml"
  echo "wrote ~/.deskkontrol/config.toml"
fi
if [ ! -f "$HOME/.deskkontrol/routes.toml" ]; then
  cp "$root/agent/routes.example.toml" "$HOME/.deskkontrol/routes.toml"
  echo "wrote ~/.deskkontrol/routes.toml"
fi

echo
echo "installed $bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo "grant Accessibility and Screen Recording to $bin in System Settings, then run:"
echo "  deskkontrol serve"
