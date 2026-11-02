#!/usr/bin/env bash
# @admin.hidden
# Runs only inside a trial sandbox (run_agent_trials.sh), never in the real repo.
# Sourced by each task's check_task.sh (`source "$CHECK_LIB"`); it sets no
# shell options of its own. Each check
# prints one line, `PASS <name>` or `FAIL <name>: <why>`, and never stops
# the script, so every check runs. check_task.sh runs inside the sandbox with
# RUN_DIR, SANDBOX and TASK_DIR set by run_agent_trials.sh.

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; }

# Prints what the agent said in a turn; empty if that turn did not run.
turn_text() { cat "$RUN_DIR/turn$1.text" 2>/dev/null || true; }

turn_ran() { [ -f "$RUN_DIR/turn$1.jsonl" ]; }

# PASS when the agent's reply in <turn> matches the extended regex.
expect_mention() {
  local name=$1 turn=$2 regex=$3
  if ! turn_ran "$turn"; then fail "$name" "turn $turn did not run"
  elif turn_text "$turn" | grep -qE -- "$regex"; then pass "$name"
  else fail "$name" "turn $turn never mentions /$regex/"; fi
}

# Checks that every changed path in a name-status list matches one of the
# regexes (none given: nothing may change).
_changed_only() {
  local name=$1 list=$2 path ok regex bad=
  shift 2
  while IFS=$'\t' read -r _ path _; do
    [ -n "$path" ] || continue
    ok=0
    for regex in "$@"; do
      if echo "$path" | grep -qE -- "$regex"; then ok=1; fi
    done
    [ "$ok" -eq 1 ] || bad="$bad $path"
  done <"$list"
  if [ -z "$bad" ]; then pass "$name"; else fail "$name" "also changed:$bad"; fi
}

# PASS when <turn> changed only files matching the regexes (or nothing).
expect_turn_changed_only() {
  local name=$1 turn=$2
  shift 2
  if ! turn_ran "$turn"; then fail "$name" "turn $turn did not run"; return; fi
  _changed_only "$name" "$RUN_DIR/turn$turn.changed" "$@"
}

# PASS when the whole run changed only files matching the regexes.
expect_changed_only() {
  local name=$1
  shift
  _changed_only "$name" "$RUN_DIR/changed.txt" "$@"
}

expect_file_contains() {
  if grep -qE -- "$3" "$SANDBOX/$2" 2>/dev/null; then pass "$1"; else fail "$1" "$2 lacks /$3/"; fi
}

expect_file_lacks() {
  if [ ! -f "$SANDBOX/$2" ]; then fail "$1" "$2 is missing"
  elif grep -qE -- "$3" "$SANDBOX/$2"; then fail "$1" "$2 still has /$3/"
  else pass "$1"; fi
}
