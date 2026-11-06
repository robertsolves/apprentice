#!/bin/bash
# A throwaway copy of the window to test against: its own home folder, a demo project and stand-in agents that spend
# nothing. It is signed with the same identity and entitlements as the installed app (kit.sh), so the Accessibility,
# Screen Recording and Keychain approvals the user gave once cover it. An ad-hoc signature is a new app to macOS on every
# rebuild, and asks for the user's password each time: never sign a test copy that way. HOME stays the user's too, since
# codesign and the Keychain look for their keychain there; only APPRENTICE_HOME (all of apprentice's state) moves.
#
#   scripts/uitest.sh build    swift build (debug), make and sign the copy
#   scripts/uitest.sh run      open it, in the foreground; apprentice can then bind to "Apprentice Test"
#   scripts/uitest.sh stop     close the copy and the daemon it started
#   scripts/uitest.sh          both
#   scripts/uitest.sh drive tree | press 3 | shot /tmp/w.png …    one UIDrive command to the running copy, and its answer
#
# A debug build also takes APPRENTICE_APP_UIDRIVE=<folder> (set here, to .build/uitest/drive): see UIDrive in AppWork.swift.
# `drive` is the way to test the window with nothing of apprentice's in between: no daemon driving, no cursor, no kill switch.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/.build/uitest"
home="$work/home"
app="$work/Apprentice Test.app"
bin="$root/.build/debug/apprentice"
id="${APPRENTICE_SIGN_IDENTITY:-apprentice}"

build() {
  identities="$(security find-identity -p codesigning 2>/dev/null || true)"
  if [[ "$identities" != *"\"$id\""* ]]; then
    echo "no signing identity \"$id\": run ./kit.sh once, which makes it, rather than signing this copy ad hoc" >&2
    exit 1
  fi
  (cd "$root" && swift build 2>&1 | tail -1) || { (cd "$root" && swift build 2>&1 | grep error: | sort -u) >&2; exit 1; }
  # The debug binary starts the copy's daemon, so it is signed as the app is: same identity, same grants, no new dialogs.
  codesign --force --options runtime --identifier com.apprentice.app --sign "$id" "$bin"
  mkdir -p "$home/.apprentice" "$home/bin"
  # The copy's own binary inside its bundle: macOS gives the approvals to an app, so a loose binary has none, however it is signed.
  printf '{"clone":"%s","commit":"uitest","built":"x","bin":"%s"}' "$root" "$app/Contents/MacOS/apprentice" >"$home/.apprentice/install.json"
  ln -sf "$app/Contents/MacOS/apprentice" "$home/bin/apprentice"
  # Stand-ins named like the real CLIs, run by full path, so nothing here can start a real one.
  cat >"$work/standin.c" <<'C'
#include <stdio.h>
#include <unistd.h>
int main(void){ printf("stand-in agent ready\n"); fflush(stdout); char b[4096]; ssize_t n; while((n=read(0,b,sizeof b))>0) write(1,b,n); return 0; }
C
  cc -o "$home/bin/claude" "$work/standin.c"
  # Says yes to the audit, and otherwise what it was asked, so a run goes on as it would with an agent.
  cat >"$home/bin/fakerun" <<'F'
#!/bin/sh
sleep 2
case "$1" in
  *"You audit a pipeline"*) echo '{"ok": true}' ;;
  *) printf "stand-in did: "; printf "%s" "$1" | tail -c 120; echo ;;
esac
F
  chmod +x "$home/bin/fakerun"
  : >"$home/.apprentice/agents.toml"
  for c in claude codex gemini opencode kilo agy; do
    printf '[agent.%s]\nlabel = "Stand-in %s"\nopen = "%s"\ndetect = ["fakerun"]\nrun = ["%s/bin/fakerun", "{prompt}"]\nskills_dir = ".claude/skills"\ncommands_dir = ".claude/commands"\nskill_prefix = "/"\n\n' "$c" "$c" "$c" "$home" >>"$home/.apprentice/agents.toml"
  done
  touch "$home/.apprentice/welcome-done"
  # The test home's daemon would put a second icon in the user's menu bar, and one that outlives the test.
  printf '[agent]\nmenu_bar = false\n' >"$home/.apprentice/config.toml"
  export APPRENTICE_HOME="$home/.apprentice" PATH="$home/bin:$PATH"
  if [ ! -d "$home/Demo" ]; then
    (cd "$home" && "$bin" project new Demo --no-vm --dir "$home/Demo" --about "UI test project" >/dev/null)
    (cd "$home/Demo" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm start \
      && "$bin" pipeline new "Morning round" "Do A" "Do B" >/dev/null \
      && mkdir -p .apprentice/skills/general && printf '# Say hi\n\nSay hi.\n' >.apprentice/skills/general/say-hi.md)
  fi
  rm -rf "$app" "$work/T.app"
  (cd "$home" && "$bin" app --bundle "$work/T.app" >/dev/null)
  mv "$work/T.app" "$app"
  plutil -replace CFBundleName -string "Apprentice Test" "$app/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Apprentice Test" "$app/Contents/Info.plist"
  # The same command kit.sh signs the installed app with.
  codesign --force --options runtime --entitlements "$root/scripts/app.entitlements" --sign "$id" "$app"
  echo "built $app, signed with $id"
}

run() {
  mkdir -p "$work/drive"
  rm -f "$work/drive/in" "$work/drive/out"
  export APPRENTICE_HOME="$home/.apprentice" PATH="$home/bin:$PATH" APPRENTICE_APP_UIDRIVE="$work/drive"
  cd "$home"
  exec "$app/Contents/MacOS/apprentice"
}

# A daemon the test started, so it does not stay behind (its own folder, so never the user's).
stop() { APPRENTICE_HOME="$home/.apprentice" "$bin" stop >/dev/null 2>&1 || true; pkill -f "$work/Apprentice Test.app" 2>/dev/null || true; }

drive() {
  rm -f "$work/drive/out"
  printf '%s\n' "$*" >"$work/drive/in"
  for _ in $(seq 1 100); do
    if [ -f "$work/drive/out" ]; then cat "$work/drive/out"; echo; return 0; fi
    sleep 0.1
  done
  echo "the copy did not answer: is it running? (scripts/uitest.sh run)" >&2
  return 1
}

case "${1:-both}" in
  drive) shift; drive "$@" ;;
  stop) stop ;;
  build) build ;;
  run) run ;;
  both) build; run ;;
  *) echo "usage: scripts/uitest.sh build | run | stop | drive <command>" >&2; exit 5 ;;
esac
