#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.apprentice/replays" "$HOME/.claude/skills/apprentice"

echo "building release…"
(cd "$root" && swift build -c release)

bin="$HOME/.local/bin/apprentice"
mkdir -p "$(dirname "$bin")"
cp "$root/.build/release/apprentice" "$bin"

id="${APPRENTICE_SIGN_IDENTITY:-}"
if [ -z "$id" ]; then
  # A keychain identity made when the tool was still called deskkontrol works too.
  for name in apprentice deskkontrol; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then id="$name"; break; fi
  done
fi
if [ -n "$id" ]; then
  codesign --force --sign "$id" "$bin"
  echo "signed with $id (permissions survive rebuilds)"
else
  codesign --force --sign - "$bin" 2>/dev/null || true
  echo "warning: ad-hoc signed. Set APPRENTICE_SIGN_IDENTITY to a stable local identity"
  echo "         so Accessibility and Screen Recording grants survive rebuilds."
fi

cp "$root/agent/SKILL.md" "$HOME/.claude/skills/apprentice/SKILL.md"

# Clean up the install from when the tool was called deskkontrol.
rm -rf "$HOME/.claude/skills/deskkontrol"
rm -f "$HOME/.local/bin/deskkontrol"

agents="$HOME/.config/opencode/AGENTS.md"
mkdir -p "$(dirname "$agents")"
if touch "$agents" && ! grep -q "<!-- apprentice -->" "$agents" 2>/dev/null; then
  printf '\n<!-- apprentice -->\n' >> "$agents"
  cat "$root/agent/AGENTS.md" >> "$agents"
  echo "appended the apprentice section to $agents"
fi
if grep -q "<!-- deskkontrol -->" "$agents" 2>/dev/null; then
  echo "note: $agents still has the old deskkontrol section; delete it from <!-- deskkontrol --> to the next section"
fi

# Notes live in the repo, so `git pull` brings in what was learned on other machines,
# and `apprentice learn` writes new flows straight into the working tree to commit.
notes="$HOME/.apprentice/notes"
if [ -L "$notes" ] || [ ! -e "$notes" ]; then
  ln -sfn "$root/notes" "$notes"
  echo "linked $notes → $root/notes"
else
  echo "warning: $notes is a real folder; move its files into $root/notes, delete it, and re-run"
fi

if [ ! -f "$HOME/.apprentice/config.toml" ]; then
  cp "$root/agent/config.example.toml" "$HOME/.apprentice/config.toml"
  echo "wrote ~/.apprentice/config.toml"
fi
if [ ! -f "$HOME/.apprentice/routes.toml" ]; then
  cp "$root/agent/routes.example.toml" "$HOME/.apprentice/routes.toml"
  echo "wrote ~/.apprentice/routes.toml"
fi

echo
echo "installed $bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo "grant Accessibility and Screen Recording to $bin in System Settings, then run:"
echo "  apprentice serve"
