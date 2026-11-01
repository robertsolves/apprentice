#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.apprentice/replays" "$HOME/.claude/skills/apprentice" "$HOME/.agents/skills/apprentice"

echo "building release…"
(cd "$root" && swift build -c release)

bin="$HOME/.local/bin/apprentice"
mkdir -p "$(dirname "$bin")"
# Signed beside the old binary, then swapped in with a rename: a running apprentice keeps
# its own copy, so `apprentice commit` and `update` can rebuild themselves.
new="$bin.new"
cp "$root/.build/release/apprentice" "$new"

id="${APPRENTICE_SIGN_IDENTITY:-}"
if [ -z "$id" ]; then
  # A keychain identity made when the tool was still called deskkontrol works too.
  for name in apprentice deskkontrol; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$name\""; then id="$name"; break; fi
  done
fi
if [ -n "$id" ]; then
  codesign --force --sign "$id" "$new"
  echo "signed with $id (permissions survive rebuilds)"
else
  codesign --force --sign - "$new" 2>/dev/null || true
  echo "warning: ad-hoc signed. Set APPRENTICE_SIGN_IDENTITY to a stable local identity"
  echo "         so Accessibility and Screen Recording grants survive rebuilds."
fi

mv -f "$new" "$bin"

# Claude Code reads ~/.claude/skills; Codex and opencode read the shared ~/.agents/skills.
cp "$root/agent/SKILL.md" "$HOME/.claude/skills/apprentice/SKILL.md"
cp "$root/agent/SKILL.md" "$HOME/.agents/skills/apprentice/SKILL.md"

# Clean up the install from when the tool was called deskkontrol.
rm -rf "$HOME/.claude/skills/deskkontrol"
rm -f "$HOME/.local/bin/deskkontrol"

# Codex/ChatGPT, opencode, Kilo and Gemini get the instructions; the Claude and Cursor apps get the MCP server.
python3 "$root/agent/connect.py" "$bin"
if grep -q "<!-- deskkontrol -->" "$HOME/.config/opencode/AGENTS.md" 2>/dev/null; then
  echo "note: ~/.config/opencode/AGENTS.md still has the old deskkontrol section; delete it from <!-- deskkontrol --> to the next section"
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

# Settings live in ~/.apprentice/settings when they sync with GitHub (`apprentice settings github`).
settings="$HOME/.apprentice"
[ -d "$settings/settings/.git" ] && settings="$settings/settings"
if [ ! -f "$settings/config.toml" ]; then
  cp "$root/agent/config.example.toml" "$settings/config.toml"
  echo "wrote $settings/config.toml"
fi
if [ ! -f "$settings/routes.toml" ]; then
  cp "$root/agent/routes.example.toml" "$settings/routes.toml"
  echo "wrote $settings/routes.toml"
fi

echo
echo "installed $bin"
# Agents run `apprentice` from a login shell, so ~/.local/bin goes on PATH in the profile.
case "$(basename "${SHELL:-zsh}")" in
  bash) profile="$HOME/.bash_profile" ;;
  *) profile="$HOME/.zprofile" ;;
esac
if ! grep -qs '\.local/bin' "$profile"; then
  printf '\n# apprentice\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$profile"
  echo "put ~/.local/bin on PATH in $profile (open a new terminal)"
fi
echo "grant Accessibility and Screen Recording to $bin in System Settings, then run:"
echo "  apprentice serve"
