# Planted tasks

None yet. Each task is a folder here, named `<command>-<what is planted>`:

- `task.env`: `COMMAND=<command name>`, `ARGS=<its arguments>`, optionally `TURN_TIMEOUT=<seconds>`.
- `setup_task.sh`: plants one problem in the sandbox copy (`set -euo pipefail`, asserts the planted text is there afterwards).
- `check_task.sh`: sources `$CHECK_LIB` and prints one `PASS`/`FAIL` line per check (`expect_mention`, `expect_file_contains`, `expect_file_lacks`, `expect_changed_only`, `expect_turn_changed_only`; see `../check_lib.sh`).
- `replies.txt` (optional): the owner's scripted replies, one turn per line, such as `fix all`.

Both scripts start with `# @admin.hidden` and run only inside a trial sandbox, never in the real repo.
