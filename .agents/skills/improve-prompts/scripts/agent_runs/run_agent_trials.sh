#!/usr/bin/env bash
# Runs a weak (free) coding agent on a fixed, planted task in a throwaway
# copy of this repo, so a change to a command, skill, rule or subagent is
# measured instead of guessed. The playbook is README.md beside this file.
#
# Usage:
#   run_agent_trials.sh snapshot                      copy the working tree into the lab
#   run_agent_trials.sh tasks                         list the planted tasks
#   run_agent_trials.sh run <task> [options]          one trial
#   run_agent_trials.sh fill <batch> [--like <batch>] [--repeat N] [options] [task...]
#   run_agent_trials.sh show <run>                    one run, blind (no version, no batch)
#   run_agent_trials.sh review <run> good|ok|poor "<reason>" ["TAG, TAG"]
#   run_agent_trials.sh score <batch>                 pass rates, ratings, tags, cost
#   run_agent_trials.sh pair <old-batch> <new-batch>  each task and check against itself
#   run_agent_trials.sh version new [--from vN] "<why>"
#   run_agent_trials.sh version add <vN> <repo path>  copy a file into the version to edit
#   run_agent_trials.sh version diff <vN>             the version's change against its parent
#   run_agent_trials.sh version list
#   run_agent_trials.sh version adopt <vN>            copy the version's files into the repo
#
# Run options: --version vN (default v0: the snapshot as it is), --model M,
#   --cli opencode|kilo, --snapshot S (default: newest), --batch B,
#   --keep (keep the sandbox and session), --paid (allow a non-free model).
#
# The lab lives in $AGENT_RUNS_HOME (default ~/.agent_runs/<repo name>).
# Exit codes: 0 ok, 1 failed or refused, 2 usage error.

set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

REPO=$(pwd -P)
HARNESS_PATH=.agents/skills/improve-prompts/scripts/agent_runs
HERE=$REPO/$HARNESS_PATH
TASKS_DIR=$HERE/tasks
LAB=${AGENT_RUNS_HOME:-$HOME/.agent_runs/$(basename "$REPO")}

# Commands that touch a live environment. A trial never runs one, even if
# its frontmatter forgot `disable-model-invocation: true`.
LIVE_COMMANDS=" "

# Files the agent CLI itself rewrites at startup (its plugin manifest in the
# .opencode / .kilo folder, which is .agents/ here). Never counted as edits.
CLI_OWNED_PATHS=(':!.agents/package.json' ':!.agents/package-lock.json' ':!.agents/bun.lock' ':!.agents/.gitignore')

die() { printf 'agent_runs: %s\n' "$*" >&2; exit 1; }
usage() { printf 'agent_runs: %s (see the header of %s)\n' "$*" "$0" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || usage "$1 needs a value"; }

case $LAB in "$REPO"/*) die "the lab must live outside the repo, not $LAB" ;; esac

# Reads KEY=value from a task.env or run.env without running it as code.
env_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }

# git with the lab's own config: no hooks, no signing, no credential helper.
lab_git() { GIT_CONFIG_GLOBAL=$LAB/gitconfig GIT_CONFIG_NOSYSTEM=1 git "$@"; }

valid_name() { case $1 in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac; }

newest_snapshot() {
  local newest
  newest=$(ls "$LAB/snapshots" 2>/dev/null | sort | tail -n 1)
  [ -n "$newest" ] || die "no snapshot yet (make one: run_agent_trials.sh snapshot)"
  printf '%s\n' "$newest"
}

default_model() {
  case $1 in
    opencode) echo opencode/nemotron-3.5-lightning-free ;;
    kilo) echo kilo/nvidia/nemotron-3.5-lightning:free ;;
    *) usage "--cli is opencode or kilo, not $1" ;;
  esac
}

cli_path() {
  case $1 in
    opencode) command -v opencode || die "opencode is not installed" ;;
    kilo)
      local kilo=${AGENT_RUNS_KILO_BIN:-$HOME/.nvm/versions/node/v24.7.0/lib/node_modules/@kilocode/cli/node_modules/@kilocode/cli-darwin-arm64/bin/kilo}
      [ -x "$kilo" ] || die "no native kilo binary at $kilo (set AGENT_RUNS_KILO_BIN)"
      echo "$kilo"
      ;;
    *) usage "--cli is opencode or kilo, not $1" ;;
  esac
}

is_free_model() { case $1 in *-free | *:free) return 0 ;; *) return 1 ;; esac; }

# The file a version sees at a repo path: its own copy, else the snapshot's.
effective_file() {
  local version=$1 snapshot=$2 path=$3
  if [ "$version" != v0 ] && [ -f "$LAB/versions/$version/files/$path" ]; then
    echo "$LAB/versions/$version/files/$path"
  elif [ -e "$LAB/snapshots/$snapshot/tree/$path" ]; then
    echo "$LAB/snapshots/$snapshot/tree/$path"
  fi
}

# Creates the lab's fixed parts: folders, the git config, and the curated
# tool folder that is the agent's whole PATH apart from the SDK and system.
prepare_lab() {
  mkdir -p "$LAB"/snapshots "$LAB"/versions "$LAB"/runs "$LAB"/batches "$LAB"/sandboxes \
    "$LAB"/bin "$LAB"/home "$LAB"/cache "$LAB"/data "$LAB"/state
  if [ ! -f "$LAB/gitconfig" ]; then
    printf '%s\n' '[user]' '	name = Agent Runs' '	email = agent-runs@localhost' \
      '[commit]' '	gpgsign = false' '[tag]' '	gpgsign = false' '[credential]' '	helper =' \
      '[core]' '	hooksPath = /dev/null' '[init]' '	defaultBranch = main' '[gc]' '	auto = 0' >"$LAB/gitconfig"
  fi
  local tool real
  for tool in git rg python3 shellcheck; do
    real=$(command -v "$tool") || die "$tool is not installed; the agent needs it"
    ln -sfn "$real" "$LAB/bin/$tool"
  done
  # The Swift toolchain, so the agent can run `swift build` and `selftest`.
  TOOLCHAIN_BIN=$(dirname "$(xcrun -f swift 2>/dev/null)")
  [ -x "$TOOLCHAIN_BIN/swift" ] || die "no Swift toolchain (install the Xcode command line tools)"
}

# Fills AGENT_ENV, the whole environment the agent, setup_task.sh and check_task.sh
# run with: a lab home instead of the real one, so none of the owner's
# sign-ins, credentials or global agent config are in reach.
build_agent_env() {
  local config
  config=$(jq -c . "$HERE/agent_config.json")
  AGENT_ENV=(
    "HOME=$LAB/home" "USER=$USER" "LOGNAME=$USER"
    "PATH=$LAB/bin:$TOOLCHAIN_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=$RUN_DIR/tmp" "TERM=dumb" "LANG=en_US.UTF-8" "SHELL=/bin/bash"
    "XDG_CONFIG_HOME=$RUN_DIR/config" "XDG_CACHE_HOME=$LAB/cache"
    "XDG_DATA_HOME=$LAB/data" "XDG_STATE_HOME=$LAB/state"
    "CLOUDSDK_CONFIG=$RUN_DIR/config/gcloud" "GH_CONFIG_DIR=$RUN_DIR/config/gh"
    "GOOGLE_APPLICATION_CREDENTIALS=$RUN_DIR/config/none.json" "PGPASSFILE=$RUN_DIR/config/none.pgpass"
    "GIT_CONFIG_GLOBAL=$RUN_DIR/gitconfig" "GIT_CONFIG_NOSYSTEM=1"
    "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=false"
    "OPENCODE_CONFIG_CONTENT=$config" "KILO_CONFIG_CONTENT=$config"
    "OPENCODE_DISABLE_AUTOUPDATE=1" "KILO_DISABLE_AUTOUPDATE=1"
    "OPENCODE_DISABLE_CLAUDE_CODE=1" "KILO_DISABLE_CLAUDE_CODE=1"
    "OPENCODE_DISABLE_EXTERNAL_SKILLS=1" "KILO_DISABLE_EXTERNAL_SKILLS=1"
    "OPENCODE_DISABLE_LSP_DOWNLOAD=1" "KILO_DISABLE_LSP_DOWNLOAD=1"
    "AGENT_RUNS_ID=$RUN_ID"
  )
}

# ---------------------------------------------------------------- processes

CHILD_PID=

tree_pids() {
  local child
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null || true); do tree_pids "$child"; done
}

# TERM a set of processes and all their descendants, KILL what is left 3s later.
stop_trees() {
  local root pid pids=
  for root in "$@"; do pids="$pids $(tree_pids "$root")"; done
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 3
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# Runs a command in the background; stops it and its children once
# <seconds> pass. Returns its exit code, or 124 on timeout.
run_with_deadline() {
  local seconds=$1 waited=0 code=0
  shift
  "$@" &
  CHILD_PID=$!
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      stop_trees "$CHILD_PID"
      wait "$CHILD_PID" 2>/dev/null || true
      CHILD_PID=
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$CHILD_PID" || code=$?
  CHILD_PID=
  return "$code"
}

# Stops anything still running with this run's marker in its environment
# (a language server or analyzer the agent left behind), loudly.
sweep_leftovers() {
  local pids
  pids=$(ps -axE -ww -o pid=,command= 2>/dev/null | grep -E "AGENT_RUNS_ID=$RUN_ID( |\$)" | awk '{print $1}' || true)
  [ -n "$pids" ] || return 0
  echo "agent_runs: stopping leftover processes of $RUN_ID:" "$(echo $pids)" >&2
  # shellcheck disable=SC2086 # one pid per word
  stop_trees $pids
}

on_exit() {
  if [ -n "$CHILD_PID" ]; then stop_trees "$CHILD_PID"; fi
  if [ -n "${RUN_ID:-}" ]; then sweep_leftovers; fi
}

# ---------------------------------------------------------------- snapshot

# Prints, NUL-separated, every file of the working tree a snapshot copies:
# tracked files as they are now plus untracked files that are not ignored.
list_snapshot_files() {
  local rec path
  {
    git ls-files -z --stage | while IFS= read -r -d '' rec; do
      case $rec in 160000\ *) continue ;; esac # a submodule: another repo
      printf '%s\0' "${rec#*$'\t'}"
    done
    git ls-files -z -o --exclude-standard
  } | while IFS= read -r -d '' path; do
    case $path in
      */) continue ;;                   # an untracked nested repo
      "$HARNESS_PATH"/*) continue ;;    # the harness: it holds the answers
      .mcp.json) continue ;;            # MCP servers the agent must not reach
    esac
    if [ -f "$path" ] || [ -L "$path" ]; then printf '%s\0' "$path"; fi
  done
  # Ignored files the agent needs: the CLI plugin, if one is installed.
  if [ -e .agents/node_modules ]; then printf '%s\0' .agents/node_modules; fi
}

cmd_snapshot() {
  [ $# -eq 0 ] || usage "snapshot takes no arguments"
  prepare_lab
  local name tree dirty
  name=snap-$(date +%Y%m%d-%H%M%S)
  tree=$LAB/snapshots/$name/tree
  [ ! -e "$LAB/snapshots/$name" ] || die "$name already exists; retry in a second"
  mkdir -p "$tree"
  list_snapshot_files | bsdtar -cf - --null -T - | bsdtar -xf - -C "$tree"
  (cd "$tree" && lab_git init -q && lab_git add -A && lab_git commit -q -m "Working tree")
  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  printf 'HEAD %s\ndirty %s\ntaken %s\n' "$(git rev-parse HEAD)" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LAB/snapshots/$name/head.txt"
  echo "$name ($(du -sh "$tree" | cut -f1), HEAD $(git rev-parse --short HEAD) + $dirty uncommitted changes)"
}

cmd_tasks() {
  local dir
  for dir in "$TASKS_DIR"/*/; do
    dir=${dir%/}
    [ -f "$dir/task.env" ] || continue
    printf '%-45s /%s %s\n' "${dir##*/}" "$(env_get "$dir/task.env" COMMAND)" "$(env_get "$dir/task.env" ARGS)"
  done
}

# ---------------------------------------------------------------- run

# Refuses a command the agent must not run, or one the run would not find.
refuse_unsafe_command() {
  local command=$1 file=$2
  case $LIVE_COMMANDS in *" $command "*) die "/$command touches a live environment; never trialled" ;; esac
  [ -n "$file" ] || die "/$command is not in the snapshot or version"
  if awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { exit } fm' "$file" |
    grep -q '^disable-model-invocation: *true'; then
    die "/$command disables model invocation (it can destroy something); never trialled"
  fi
}

# Records the sandbox's files as a git tree through the run's own index,
# leaving the agent's staging area alone. Prints the tree id.
sandbox_tree() {
  GIT_INDEX_FILE=$RUN_DIR/index lab_git -C "$SANDBOX" add -A -- . "${CLI_OWNED_PATHS[@]}"
  GIT_INDEX_FILE=$RUN_DIR/index lab_git -C "$SANDBOX" write-tree
}

agent_cli() {
  cd "$SANDBOX" && exec env -i "${AGENT_ENV[@]}" "$CLI_PATH" run --dir "$SANDBOX" --auto \
    --format json -m "$MODEL" --title "agent-runs $RUN_ID" "$@"
}

# Runs one agent turn. Sets TURN_STATUS (done, timeout or cli_error) and,
# from the first turn, SESSION_ID.
run_turn() {
  local n=$1 before after code=0 started steps errors sid
  shift
  before=$(sandbox_tree)
  started=$SECONDS
  run_with_deadline "$TURN_TIMEOUT" agent_cli "$@" </dev/null 3<&- \
    >"$RUN_DIR/turn$n.jsonl" 2>"$RUN_DIR/turn$n.stderr" || code=$?
  TURN_SECONDS=$((TURN_SECONDS + SECONDS - started))
  sweep_leftovers
  after=$(sandbox_tree)
  lab_git -C "$SANDBOX" diff-tree -r --name-status "$before" "$after" >"$RUN_DIR/turn$n.changed"
  jq -Rrn 'inputs | fromjson? | select(.type? == "text") | .part.text // empty' \
    "$RUN_DIR/turn$n.jsonl" >"$RUN_DIR/turn$n.text"
  IFS=$'\t' read -r steps errors sid < <(jq -Rrn '
    [inputs | fromjson? | select(type == "object")] as $e
    | [($e | map(select(.type == "step_finish")) | length),
       ($e | map(select(.type == "error")) | length),
       ($e | map(.sessionID // empty) | first // "-")] | @tsv' "$RUN_DIR/turn$n.jsonl")
  [ -n "$SESSION_ID" ] || { [ "$sid" = - ] || SESSION_ID=$sid; }
  if [ "$code" -eq 124 ]; then
    TURN_STATUS=timeout
  elif [ "$code" -ne 0 ] || [ "$errors" -gt 0 ] || [ "$steps" -eq 0 ] || [ -z "$SESSION_ID" ]; then
    TURN_STATUS=cli_error
  else
    TURN_STATUS="done"
  fi
  echo "turn $n: $TURN_STATUS (exit $code, $steps steps, $((SECONDS - started))s)" >>"$RUN_DIR/harness.log"
}

# Cost and behaviour tallies over the turn files given, as key=value words.
COST_JQ='
  [inputs | (try fromjson catch null) | if type == "object" then . else {junk: true} end] as $all
  | ($all | map(select(.type == "step_finish"))) as $steps
  | ($all | map(select(.type == "tool_use"))) as $tools
  | ($tools | map(select(.part.state.status == "error"))) as $errs
  | ($errs | map(select((.part.state.error // "") | startswith("The user has specified a rule")))) as $denied
  | ($steps | map(.part.tokens) | map(select(. != null))) as $tok
  | ($tok | map((.input // 0) + (.cache.read // 0) + (.cache.write // 0))) as $ctx
  | "steps=\($steps | length) tool_calls=\($tools | length) denied=\($denied | length)"
    + " tool_errors=\(($errs | length) - ($denied | length))"
    + " input_tokens=\($ctx | add // 0) output_tokens=\($tok | map(.output // 0) | add // 0)"
    + " reasoning_tokens=\($tok | map(.reasoning // 0) | add // 0) peak_context=\($ctx | max // 0)"
    + " cost_usd=\($steps | map(.part.cost // 0) | add // 0)"
    + " junk_lines=\($all | map(select(.junk)) | length)"
    + " steps_without_tokens=\(($steps | length) - ($tok | length))"'

cmd_run() {
  local task='' version=v0 model='' cli=opencode snapshot='' batch='' keep=0 paid=0
  while [ $# -gt 0 ]; do
    case $1 in
      --version) need_value "$1" $#; version=$2; shift 2 ;;
      --model) need_value "$1" $#; model=$2; shift 2 ;;
      --cli) need_value "$1" $#; cli=$2; shift 2 ;;
      --snapshot) need_value "$1" $#; snapshot=$2; shift 2 ;;
      --batch) need_value "$1" $#; batch=$2; shift 2 ;;
      --keep) keep=1; shift ;;
      --paid) paid=1; shift ;;
      -*) usage "unknown run option $1" ;;
      *) [ -z "$task" ] || usage "run takes one task"; task=$1; shift ;;
    esac
  done
  [ -n "$task" ] || usage "run needs a task (see: run_agent_trials.sh tasks)"
  TASK_DIR=$TASKS_DIR/$task
  [ -f "$TASK_DIR/task.env" ] && [ -f "$TASK_DIR/check_task.sh" ] || die "no task $task (see: run_agent_trials.sh tasks)"
  [ -z "$batch" ] || valid_name "$batch" || usage "a batch name is letters, digits, . _ -"
  [ -n "$model" ] || model=$(default_model "$cli")
  CLI_PATH=$(cli_path "$cli")
  MODEL=$model
  if ! is_free_model "$model" && [ "$paid" -eq 0 ]; then
    die "$model is not a free model; --paid needs the owner's go-ahead"
  fi

  if [ "$version" = v0 ]; then
    [ -n "$snapshot" ] || snapshot=$(newest_snapshot)
  else
    [ -d "$LAB/versions/$version" ] || die "no version $version"
    local bound
    bound=$(cat "$LAB/versions/$version/snapshot.txt")
    [ -z "$snapshot" ] || [ "$snapshot" = "$bound" ] || die "$version was made on $bound, not $snapshot"
    snapshot=$bound
  fi
  [ -d "$LAB/snapshots/$snapshot/tree" ] || die "no snapshot $snapshot"

  local command args
  command=$(env_get "$TASK_DIR/task.env" COMMAND)
  args=$(env_get "$TASK_DIR/task.env" ARGS)
  TURN_TIMEOUT=$(env_get "$TASK_DIR/task.env" TURN_TIMEOUT)
  [ -n "$TURN_TIMEOUT" ] || TURN_TIMEOUT=900
  refuse_unsafe_command "$command" "$(effective_file "$version" "$snapshot" ".agents/commands/$command.md")"

  prepare_lab
  RUN_DIR=$(mktemp -d "$LAB/runs/$(date +%Y%m%d-%H%M%S)-XXXXXX")
  RUN_ID=${RUN_DIR##*/}
  SANDBOX=$LAB/sandboxes/$RUN_ID
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  mkdir -p "$RUN_DIR/tmp" "$RUN_DIR/config"
  cp "$LAB/gitconfig" "$RUN_DIR/gitconfig"
  build_agent_env
  {
    echo "TASK=$task"; echo "COMMAND=$command"; echo "ARGS=$args"
    echo "VERSION=$version"; echo "SNAPSHOT=$snapshot"; echo "MODEL=$model"; echo "CLI=$cli"
    echo "CLI_VERSION=$("$CLI_PATH" --version 2>/dev/null | tail -n 1)"
    echo "BATCH=$batch"; echo "STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$RUN_DIR/run.env"

  # The sandbox: snapshot, version overlay, the planted problem, one commit.
  cp -Rc "$LAB/snapshots/$snapshot/tree" "$SANDBOX" 2>/dev/null ||
    { rm -rf "$SANDBOX"; cp -R "$LAB/snapshots/$snapshot/tree" "$SANDBOX"; }
  if [ "$version" != v0 ]; then cp -R "$LAB/versions/$version/files/." "$SANDBOX/"; fi
  if [ -f "$TASK_DIR/setup_task.sh" ]; then
    (cd "$SANDBOX" && env -i "${AGENT_ENV[@]}" bash "$TASK_DIR/setup_task.sh") >>"$RUN_DIR/harness.log" 2>&1 ||
      die "setup_task.sh failed (see $RUN_DIR/harness.log)"
  fi
  lab_git -C "$SANDBOX" add -A
  lab_git -C "$SANDBOX" commit -q --amend -m "Working tree ($RUN_ID)"
  local base
  base=$(lab_git -C "$SANDBOX" rev-parse HEAD)
  cp "$SANDBOX/.git/index" "$RUN_DIR/index"

  # A file a previous agent wrote into the shared lab home would leak in.
  local leftover
  for leftover in .config .opencode .kilo .kilocode .claude .agents .gitconfig; do
    if [ -e "$LAB/home/$leftover" ]; then
      echo "agent_runs: removing $LAB/home/$leftover left by an earlier run" >&2
      rm -rf "${LAB:?}/home/$leftover"
    fi
  done

  SESSION_ID='' TURN_STATUS='' TURN_SECONDS=0
  local n=1 reply
  printf '/%s %s\n' "$command" "$args" >"$RUN_DIR/turn1.prompt"
  echo "run $RUN_ID: $task on $model" >&2
  if [ -n "$args" ]; then run_turn 1 --command "$command" "$args"; else run_turn 1 --command "$command"; fi
  if [ "$TURN_STATUS" = "done" ] && [ -f "$TASK_DIR/replies.txt" ]; then
    while IFS= read -r reply <&3; do
      case $reply in '' | '#'*) continue ;; esac
      n=$((n + 1))
      printf '%s\n' "$reply" >"$RUN_DIR/turn$n.prompt"
      run_turn "$n" --session "$SESSION_ID" "$reply"
      [ "$TURN_STATUS" = "done" ] || break
    done 3<"$TASK_DIR/replies.txt"
  fi

  local final check_code=0
  final=$(sandbox_tree)
  lab_git -C "$SANDBOX" diff "$base" "$final" >"$RUN_DIR/diff.patch"
  lab_git -C "$SANDBOX" diff --name-status "$base" "$final" >"$RUN_DIR/changed.txt"
  run_with_deadline 600 env -i "${AGENT_ENV[@]}" RUN_DIR="$RUN_DIR" SANDBOX="$SANDBOX" \
    TASK_DIR="$TASK_DIR" CHECK_LIB="$HERE/check_lib.sh" bash -c 'cd "$SANDBOX" && bash "$TASK_DIR/check_task.sh"' \
    </dev/null >"$RUN_DIR/checks.txt" 2>"$RUN_DIR/checks.stderr" || check_code=$?
  if [ "$check_code" -eq 124 ]; then
    echo "FAIL check_script: timed out after 600s" >>"$RUN_DIR/checks.txt"
  elif [ "$check_code" -ne 0 ]; then
    echo "FAIL check_script: exited $check_code (see checks.stderr)" >>"$RUN_DIR/checks.txt"
  elif ! grep -qE '^(PASS|FAIL) ' "$RUN_DIR/checks.txt"; then
    echo "FAIL check_script: printed no result" >>"$RUN_DIR/checks.txt"
  fi
  cat "$RUN_DIR"/turn*.jsonl | jq -Rrn "$COST_JQ" | sed "s/\$/ seconds=$TURN_SECONDS/" >"$RUN_DIR/cost.txt"

  {
    echo "STATUS=$TURN_STATUS"; echo "TURNS=$n"; echo "SESSION=$SESSION_ID"; echo "BASE=$base"
  } >>"$RUN_DIR/run.env"
  if [ "$keep" -eq 0 ]; then
    if [ -n "$SESSION_ID" ] && ! (cd "$LAB" && env -i "${AGENT_ENV[@]}" "$CLI_PATH" session delete "$SESSION_ID") \
      >>"$RUN_DIR/harness.log" 2>&1; then
      echo "agent_runs: could not delete session $SESSION_ID (see harness.log)" >&2
    fi
    rm -rf "${LAB:?}/sandboxes/$RUN_ID"
  fi
  if [ -n "$batch" ]; then
    mkdir -p "$LAB/batches/$batch"
    echo "$RUN_ID" >>"$LAB/batches/$batch/run_ids.txt"
  fi
  echo "run $RUN_ID: $TURN_STATUS, $n turn(s), checks $(grep -c '^PASS ' "$RUN_DIR/checks.txt" || true)/$(grep -cE '^(PASS|FAIL) ' "$RUN_DIR/checks.txt") pass"
  grep '^FAIL ' "$RUN_DIR/checks.txt" | sed 's/^/  /' || true
}

# ---------------------------------------------------------------- batches

batch_runs() {
  [ -f "$LAB/batches/$1/run_ids.txt" ] || die "no batch $1"
  cat "$LAB/batches/$1/run_ids.txt"
}

cmd_fill() {
  local batch='' like='' repeat=3 i task code
  local run_opts=() tasks=() model='' cli='' snapshot=''
  [ $# -gt 0 ] || usage "fill needs a batch name"
  batch=$1
  shift
  valid_name "$batch" || usage "a batch name is letters, digits, . _ -"
  while [ $# -gt 0 ]; do
    case $1 in
      --like) need_value "$1" $#; like=$2; shift 2 ;;
      --repeat) need_value "$1" $#; repeat=$2; shift 2 ;;
      --model) need_value "$1" $#; model=$2; shift 2 ;;
      --cli) need_value "$1" $#; cli=$2; shift 2 ;;
      --snapshot) need_value "$1" $#; snapshot=$2; shift 2 ;;
      --version) need_value "$1" $#; run_opts+=("$1" "$2"); shift 2 ;;
      --keep | --paid) run_opts+=("$1"); shift ;;
      -*) usage "unknown fill option $1" ;;
      *) tasks+=("$1"); shift ;;
    esac
  done
  if [ -n "$like" ]; then
    # The old batch's tasks, model, CLI and snapshot; never its version.
    local first
    first=$LAB/runs/$(batch_runs "$like" | head -n 1)/run.env
    [ -n "$model" ] || model=$(env_get "$first" MODEL)
    [ -n "$cli" ] || cli=$(env_get "$first" CLI)
    [ -n "$snapshot" ] || snapshot=$(env_get "$first" SNAPSHOT)
    if [ ${#tasks[@]} -eq 0 ]; then
      while IFS= read -r task; do tasks+=("$task"); done < <(
        batch_runs "$like" | while IFS= read -r i; do env_get "$LAB/runs/$i/run.env" TASK; done | sort -u)
    fi
  fi
  if [ ${#tasks[@]} -eq 0 ]; then
    while IFS= read -r task; do tasks+=("$task"); done < <(ls "$TASKS_DIR")
  fi
  [ -z "$model" ] || run_opts+=(--model "$model")
  [ -z "$cli" ] || run_opts+=(--cli "$cli")
  [ -z "$snapshot" ] || run_opts+=(--snapshot "$snapshot")

  # One run at a time: free tiers rate-limit, and parallel agents would race
  # for the shared lab home. A cli_error is retried once.
  for task in "${tasks[@]}"; do
    for i in $(seq 1 "$repeat"); do
      code=0
      "$0" run "$task" --batch "$batch" ${run_opts[@]+"${run_opts[@]}"} || code=$?
      if [ "$code" -ne 0 ]; then die "run of $task refused or crashed (exit $code)"; fi
      if [ "$(env_get "$LAB/runs/$(tail -n 1 "$LAB/batches/$batch/run_ids.txt")/run.env" STATUS)" = cli_error ]; then
        echo "agent_runs: $task hit a CLI error; retrying once" >&2
        "$0" run "$task" --batch "$batch" ${run_opts[@]+"${run_opts[@]}"}
      fi
    done
  done
  echo "batch $batch filled; next: score it, or review its runs blind"
}

cmd_show() {
  [ $# -eq 1 ] || usage "show takes one run id"
  local dir=$LAB/runs/$1 n f
  [ -f "$dir/run.env" ] || die "no run $1"
  echo "run $1: task $(env_get "$dir/run.env" TASK), status $(env_get "$dir/run.env" STATUS)"
  echo "command: /$(env_get "$dir/run.env" COMMAND) $(env_get "$dir/run.env" ARGS)"
  echo "model: $(env_get "$dir/run.env" MODEL) via $(env_get "$dir/run.env" CLI) $(env_get "$dir/run.env" CLI_VERSION)"
  echo; echo "== checks"; cat "$dir/checks.txt" 2>/dev/null || echo "(none)"
  echo; echo "== cost"; cat "$dir/cost.txt" 2>/dev/null || echo "(none)"
  n=1
  while [ -f "$dir/turn$n.jsonl" ]; do
    echo; echo "== turn $n prompt: $(cat "$dir/turn$n.prompt")"
    echo "changed: $(tr '\t\n' ' ,' <"$dir/turn$n.changed" | sed 's/,$//')"
    echo "tools: $(jq -Rrn 'inputs | fromjson? | select(.type? == "tool_use") | .part.tool' "$dir/turn$n.jsonl" |
      sort | uniq -c | awk '{printf "%s %s, ", $2, $1}' | sed 's/, $//')"
    echo "-- tool log (first 60)"
    jq -Rrn 'inputs | fromjson? | select(.type? == "tool_use") | .part as $p
      | "\($p.tool): \(($p.state.input.command // $p.state.input.filePath // $p.state.input.pattern // $p.state.input.path // "") | tostring | gsub("\n"; " "))"
        + (if $p.state.status == "error" then
             (if (($p.state.error // "") | startswith("The user has specified a rule")) then " [denied]" else " [error]" end)
           else "" end)' "$dir/turn$n.jsonl" | cut -c1-100 | head -n 60
    f=$dir/turn$n.text
    echo "-- reply (last 80 lines of $f)"
    tail -n 80 "$f"
    n=$((n + 1))
  done
  echo; echo "== diff"; lab_git apply --stat "$dir/diff.patch" 2>/dev/null || echo "(no changes)"
  echo; echo "== review"; cat "$dir/review.md" 2>/dev/null || echo "(not reviewed)"
}

cmd_review() {
  [ $# -ge 3 ] && [ $# -le 4 ] || usage 'review <run> good|ok|poor "<reason>" ["TAG, TAG"]'
  local dir=$LAB/runs/$1 tags=${4:-none} tag
  [ -f "$dir/run.env" ] || die "no run $1"
  case $2 in good | ok | poor) ;; *) usage "a rating is good, ok or poor" ;; esac
  if [ "$tags" != none ]; then
    for tag in $(echo "$tags" | tr ',' ' '); do
      echo "$tag" | grep -qE '^[A-Z][A-Z0-9_]*$' || usage "a tag is UPPER_SNAKE, not $tag"
    done
  fi
  printf '**%s.** %s\nproblems: %s\n' "$2" "$3" "$tags" >"$dir/review.md"
}

# One line per finished run of a batch: run task status checks... rating tags cost.
# Unfinished and cli_error runs are named on stderr and left out.
batch_table() {
  local id dir status
  batch_runs "$1" | while IFS= read -r id; do
    dir=$LAB/runs/$id
    status=$(env_get "$dir/run.env" STATUS)
    if [ "$status" != "done" ] && [ "$status" != timeout ]; then
      echo "agent_runs: left out $id (status ${status:-unfinished})" >&2
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(env_get "$dir/run.env" TASK)" \
      "$(grep -E '^(PASS|FAIL) ' "$dir/checks.txt" | sed 's/:.*//; s/ /=/' | tr '\n' ' ')" \
      "$(sed -n 's/^\*\*\([a-z]*\)\.\*\*.*/\1/p' "$dir/review.md" 2>/dev/null || true)" \
      "$(sed -n 's/^problems: //p' "$dir/review.md" 2>/dev/null || true)" \
      "$(cat "$dir/cost.txt")"
  done
}

warn_if_mixed() {
  local key values
  for key in VERSION MODEL CLI SNAPSHOT; do
    values=$(batch_runs "$1" | while IFS= read -r id; do env_get "$LAB/runs/$id/run.env" "$key"; done | sort -u)
    if [ "$(echo "$values" | wc -l)" -gt 1 ]; then
      echo "agent_runs: WARNING batch $1 mixes ${key}s: $(echo "$values" | tr '\n' ' ')" >&2
    fi
  done
}

cmd_score() {
  [ $# -eq 1 ] || usage "score takes one batch"
  warn_if_mixed "$1"
  batch_table "$1" | awk -F'\t' '
    function cost(s, key,   m) { return match(s, key "=[0-9.]+") ? substr(s, RSTART + length(key) + 1, RLENGTH - length(key) - 1) : 0 }
    {
      t = $2; runs[t]++; full = 1
      n = split($3, cs, " ")
      for (i = 1; i <= n; i++) { split(cs[i], kv, "="); key = t SUBSEP kv[2]; seen[key] = 1; total[key]++
        if (kv[1] == "PASS") pass[key]++; else full = 0 }
      if (full && n > 0) fullpass[t]++
      rating[t, ($4 == "" ? "unrated" : $4)]++
      if ($5 != "" && $5 != "none") { m = split($5, tg, /, */); for (i = 1; i <= m; i++) { tags[t, tg[i]]++; alltags[tg[i]] = 1 } }
      calls[t] += cost($6, "tool_calls"); input[t] += cost($6, "input_tokens")
      peak[t] += cost($6, "peak_context"); secs[t] += cost($6, "seconds")
    }
    END {
      for (t in runs) {
        printf "%s: full pass %d/%d; good/ok/poor/unrated %d/%d/%d/%d\n", t, fullpass[t], runs[t],
          rating[t, "good"], rating[t, "ok"], rating[t, "poor"], rating[t, "unrated"]
        for (key in seen) { split(key, p, SUBSEP); if (p[1] == t) printf "  %-34s %d/%d\n", p[2], pass[key], total[key] }
        line = ""; for (g in alltags) if ((t, g) in tags) line = line " " g "=" tags[t, g]
        printf "  tags:%s\n", (line == "" ? " none" : line)
        printf "  mean: %d tool calls, %d input tokens, %d peak context, %ds\n",
          calls[t] / runs[t], input[t] / runs[t], peak[t] / runs[t], secs[t] / runs[t]
      }
    }'
}

cmd_pair() {
  [ $# -eq 2 ] || usage "pair takes an old and a new batch"
  local key a b
  for key in MODEL CLI SNAPSHOT; do
    a=$(env_get "$LAB/runs/$(batch_runs "$1" | head -n 1)/run.env" "$key")
    b=$(env_get "$LAB/runs/$(batch_runs "$2" | head -n 1)/run.env" "$key")
    [ "$a" = "$b" ] || die "the batches differ in $key ($a vs $b); a pair changes one thing only"
  done
  warn_if_mixed "$1"
  warn_if_mixed "$2"
  { batch_table "$1" | sed 's/^/old\t/'; batch_table "$2" | sed 's/^/new\t/'; } | awk -F'\t' '
    function verdict(po, no, pn, nn) { return po * nn < pn * no ? "better" : (po * nn > pn * no ? "worse" : "same") }
    {
      s = $1; t = $3; runs[s, t]++; tasks[t] = 1; full = 1
      n = split($4, cs, " ")
      for (i = 1; i <= n; i++) { split(cs[i], kv, "="); checks[t, kv[2]] = 1; total[s, t, kv[2]]++
        if (kv[1] == "PASS") pass[s, t, kv[2]]++; else full = 0 }
      if (full && n > 0) fullpass[s, t]++
      if ($6 != "" && $6 != "none") tagline[s, t] = tagline[s, t] " " $6
    }
    END {
      for (t in tasks) {
        if (!(("old", t) in runs) || !(("new", t) in runs)) { printf "%s: only in one batch, skipped\n", t; continue }
        printf "%s: full pass %d/%d -> %d/%d (%s)\n", t, fullpass["old", t], runs["old", t], fullpass["new", t],
          runs["new", t], verdict(fullpass["old", t], runs["old", t], fullpass["new", t], runs["new", t])
        for (key in checks) { split(key, p, SUBSEP); if (p[1] != t) continue
          v = verdict(pass["old", t, p[2]], total["old", t, p[2]], pass["new", t, p[2]], total["new", t, p[2]]); count[v]++
          printf "  %-34s %d/%d -> %d/%d %s\n", p[2], pass["old", t, p[2]], total["old", t, p[2]],
            pass["new", t, p[2]], total["new", t, p[2]], v }
        printf "  tags old:%s\n  tags new:%s\n", tagline["old", t], tagline["new", t]
      }
      printf "paired checks: better %d / same %d / worse %d\n", count["better"], count["same"], count["worse"]
    }'
}

# ---------------------------------------------------------------- versions

next_version() {
  local n=1
  while [ -d "$LAB/versions/v$n" ]; do n=$((n + 1)); done
  echo "v$n"
}

# Refuses a repo path that is absolute, climbs out, or runs through a
# symlink (an edit there would land in another file); names the real path.
check_version_path() {
  local tree=$1 path=$2 prefix='' part real
  case $path in /* | ../* | */../* | *[/]..) usage "give a repo-relative path without .., not $path" ;; esac
  (
    set -f
    IFS=/
    for part in $path; do
      prefix=${prefix:+$prefix/}$part
      if [ -L "$tree/$prefix" ]; then
        real=$(cd "$tree/$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")
        [ -L "$tree/$path" ] && real=$(cd "$tree/$(dirname "$path")" && pwd -P)/$(readlink "$tree/$path")
        die "$prefix is a symlink; add the real file instead: ${real#"$(cd "$tree" && pwd -P)"/}"
      fi
    done
  )
}

cmd_version() {
  local sub=${1:-}
  [ -n "$sub" ] || usage "version needs new, add, diff, list or adopt"
  shift
  local v from='' snapshot path src f parent
  case $sub in
    new)
      if [ "${1:-}" = --from ]; then need_value --from $#; from=$2; shift 2; fi
      [ $# -eq 1 ] || usage 'version new [--from vN] "<why>"'
      prepare_lab
      v=$(next_version)
      mkdir -p "$LAB/versions/$v/files"
      if [ -n "$from" ]; then
        [ -d "$LAB/versions/$from" ] || die "no version $from"
        cp -R "$LAB/versions/$from/files/." "$LAB/versions/$v/files/"
        snapshot=$(cat "$LAB/versions/$from/snapshot.txt")
      else
        from=v0
        snapshot=$(newest_snapshot)
      fi
      echo "$1" >"$LAB/versions/$v/reason.txt"
      echo "$from" >"$LAB/versions/$v/from.txt"
      echo "$snapshot" >"$LAB/versions/$v/snapshot.txt"
      echo "$v (from $from, snapshot $snapshot)"
      ;;
    add)
      [ $# -eq 2 ] || usage "version add <vN> <repo path>"
      v=$1 path=$2
      [ -d "$LAB/versions/$v" ] || die "no version $v"
      snapshot=$(cat "$LAB/versions/$v/snapshot.txt")
      check_version_path "$LAB/snapshots/$snapshot/tree" "$path"
      f=$LAB/versions/$v/files/$path
      if [ -f "$f" ]; then
        echo "already in $v: $f"
        return 0
      fi
      mkdir -p "$(dirname "$f")"
      src=$(effective_file v0 "$snapshot" "$path")
      if [ -n "$src" ]; then cp "$src" "$f"; else : >"$f"; echo "$path is new: created it empty"; fi
      echo "edit this copy: $f"
      ;;
    diff)
      [ $# -eq 1 ] || usage "version diff <vN>"
      v=$1
      [ -d "$LAB/versions/$v" ] || die "no version $v"
      parent=$(cat "$LAB/versions/$v/from.txt")
      snapshot=$(cat "$LAB/versions/$v/snapshot.txt")
      echo "$v: $(cat "$LAB/versions/$v/reason.txt") (from $parent)"
      (cd "$LAB/versions/$v/files" && find . -type f | sed 's|^\./||' | sort) | while IFS= read -r path; do
        src=$(effective_file "$parent" "$snapshot" "$path")
        diff -u --label "a/$path" --label "b/$path" "${src:-/dev/null}" "$LAB/versions/$v/files/$path" || true
      done | head -n 400
      ;;
    list)
      for v in $(ls "$LAB/versions" 2>/dev/null | sort -V); do
        printf '%s from %s on %s, %s file(s): %s\n' "$v" "$(cat "$LAB/versions/$v/from.txt")" \
          "$(cat "$LAB/versions/$v/snapshot.txt")" "$(find "$LAB/versions/$v/files" -type f | wc -l | tr -d ' ')" \
          "$(cat "$LAB/versions/$v/reason.txt")"
      done
      ;;
    adopt)
      [ $# -eq 1 ] || usage "version adopt <vN>"
      v=$1
      [ -d "$LAB/versions/$v" ] || die "no version $v"
      snapshot=$(cat "$LAB/versions/$v/snapshot.txt")
      local changed=0
      while IFS= read -r path; do
        src=$(effective_file v0 "$snapshot" "$path")
        if [ -n "$src" ] && ! cmp -s "$src" "$REPO/$path"; then
          echo "changed in the repo since $snapshot: $path" >&2
          changed=1
        elif [ -z "$src" ] && [ -e "$REPO/$path" ]; then
          echo "created in the repo since $snapshot: $path" >&2
          changed=1
        fi
      done < <(cd "$LAB/versions/$v/files" && find . -type f | sed 's|^\./||')
      [ "$changed" -eq 0 ] || die "nothing adopted: merge those edits into $v first (another session changed them)"
      (cd "$LAB/versions/$v/files" && find . -type f | sed 's|^\./||') | while IFS= read -r path; do
        mkdir -p "$REPO/$(dirname "$path")"
        cat "$LAB/versions/$v/files/$path" >"$REPO/$path" # writes through, never replaces a file
        echo "adopted $path"
      done
      echo "next: regenerate the wrapper of any command whose description changed, then run the authoring checks"
      ;;
    *) usage "version needs new, add, diff, list or adopt" ;;
  esac
}

# ---------------------------------------------------------------- main

[ $# -gt 0 ] || usage "no subcommand"
sub=$1
shift
case $sub in
  snapshot) cmd_snapshot "$@" ;;
  tasks) cmd_tasks "$@" ;;
  run) cmd_run "$@" ;;
  fill) cmd_fill "$@" ;;
  show) cmd_show "$@" ;;
  review) cmd_review "$@" ;;
  score) cmd_score "$@" ;;
  pair) cmd_pair "$@" ;;
  version) cmd_version "$@" ;;
  help | -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) usage "unknown subcommand $sub" ;;
esac
