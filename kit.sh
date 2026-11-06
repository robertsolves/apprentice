#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.apprentice/replays"

echo "building release…"
(cd "$root" && swift build -c release)

bin="$HOME/.local/bin/apprentice"
mkdir -p "$(dirname "$bin")"
# Signed beside the old binary, then swapped in with a rename: a running apprentice keeps
# its own copy, so `apprentice commit` and `update` can rebuild themselves.
new="$bin.new"
cp "$root/.build/release/apprentice" "$new"
# The new build tests itself before it replaces the old one; a failure keeps the old binary. It runs
# where it was built, the same bytes as "$new": from there it finds the repo's agent/ files even when
# install.json names no clone (the DMG's app rewrote it).
if ! "$root/.build/release/apprentice" selftest; then
  rm -f "$new"
  echo "self-test failed: kept the installed apprentice" >&2
  exit 1
fi

id="${APPRENTICE_SIGN_IDENTITY:-}"
# A stable local identity, made once, so Accessibility and Screen Recording grants survive rebuilds.
# It is self-signed and untrusted, which codesign and the permission checks accept; the VM gets the
# signed binary as is, so it needs no identity of its own.
# Read once into a variable: with pipefail, `security … | grep -q` can fail when grep stops reading early.
identities="$(security find-identity -p codesigning 2>/dev/null || true)"
if [ -z "$id" ] && [[ "$identities" != *'"apprentice"'* ]]; then
  echo "creating the local signing identity \"apprentice\"…"
  tmp="$(mktemp -d)"
  cat >"$tmp/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = apprentice
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  # macOS's own openssl (LibreSSL) writes a .p12 that `security import` reads.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:apprentice
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P apprentice -T /usr/bin/codesign >/dev/null \
    || echo "warning: could not add the identity to the login keychain"
  rm -rf "$tmp"
  identities="$(security find-identity -p codesigning 2>/dev/null || true)"
fi
if [ -z "$id" ] && [[ "$identities" == *'"apprentice"'* ]]; then
  id="apprentice"
fi
if [ -n "$id" ]; then
  codesign --force --sign "$id" "$new"
  echo "signed with $id (permissions survive rebuilds)"
else
  codesign --force --sign - "$new" 2>/dev/null || true
  echo "warning: ad-hoc signed. Set APPRENTICE_SIGN_IDENTITY to a stable local identity"
  echo "         so Accessibility and Screen Recording grants survive rebuilds."
fi

# What was installed, from where: `apprentice version` prints the commit, and apprentice finds its clone here.
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit-dirty"
# One executable, one package: Apprentice.app's own binary is the window (no arguments) and the CLI and
# daemon (with arguments), and ~/.local/bin/apprentice only links to it. The Accessibility and Screen
# Recording entries then belong to the one app, signed once with one identity, so dragging Apprentice.app into
# the two lists is all it takes and a rebuild never leaves a stale grant behind.
# It is made and signed to one side and moved in whole. macOS gives the grants to the app, so a loose binary has none: left
# at $bin or named by install.json for even a moment, whatever started from it then would ask for them again.
app="/Applications/Apprentice.app"
exe="$app/Contents/MacOS/apprentice"
staged="/Applications/.Apprentice.new.app"
rm -rf "$staged"
if "$new" app --bundle "$staged" >/dev/null \
  && codesign --force --options runtime --entitlements "$root/scripts/app.entitlements" --sign "${id:--}" "$staged"; then
  old="/Applications/.Apprentice.old.$$.app"
  [ -d "$app" ] && mv "$app" "$old"
  mv "$staged" "$app"
  rm -rf "$old" "$new" "$HOME/.apprentice/Apprentice.app"
  ln -sfn "$exe" "$bin"
  printf '{"clone":"%s","commit":"%s","built":"%s","bin":"%s"}\n' "$root" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exe" \
    >"$HOME/.apprentice/install.json"
  echo "packaged: $bin → $exe"
else
  rm -rf "$staged"
  echo "warning: could not make $app: installing the bare binary, which has no Accessibility grant" >&2
  [ -L "$bin" ] && rm -f "$bin"
  mv -f "$new" "$bin"
  printf '{"clone":"%s","commit":"%s","built":"%s","bin":"%s"}\n' "$root" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bin" \
    >"$HOME/.apprentice/install.json"
fi
# State holds URLs, page titles, screenshots and perhaps an API key: this user only.
chmod 700 "$HOME/.apprentice"

# The browser VM runs a copy of this binary; a running one gets the new build too. The daemon's own update
# sets APPRENTICE_DEFER_VM and does this at its restart, between tasks, since it can restart Chromium there.
if [ "${APPRENTICE_DEFER_VM:-0}" != 1 ] && [[ "$("$bin" vm status 2>/dev/null || true)" == *' · running · '* ]]; then
  "$bin" vm install || echo "warning: could not update the VM; run \`apprentice vm install\` once it is up"
fi

# Every coding agent on the Mac gets the skill and/or its global rules; the Claude and Cursor apps get the MCP server.
python3 "$root/agent/connect.py" "$bin"

# Playbooks live in the repo, so an update brings in what was learned upstream,
# and `apprentice learn` writes new flows straight into the working tree to commit.
playbooks="$HOME/.apprentice/playbooks"
if [ -L "$playbooks" ] || [ ! -e "$playbooks" ]; then
  ln -sfn "$root/playbooks" "$playbooks"
  echo "linked $playbooks → $root/playbooks"
else
  echo "warning: $playbooks is a real folder; move its files into $root/playbooks, delete it, and re-run"
fi
# The folder was called notes/ before; its old link points at nothing now.
[ -L "$HOME/.apprentice/notes" ] && rm -f "$HOME/.apprentice/notes"

# Settings live in ~/.apprentice; an older install that synced them keeps them in ~/.apprentice/settings.
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
if [ ! -f "$settings/budgets.json" ]; then
  cp "$root/agent/budgets.example.json" "$settings/budgets.json"
  echo "wrote $settings/budgets.json"
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
echo "next: \`apprentice doctor --fix\` checks the install, opens the two Privacy panes and runs a smoke test"
