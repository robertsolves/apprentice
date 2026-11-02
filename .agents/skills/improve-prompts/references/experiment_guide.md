# /improve-prompts: reference tables

Loaded by the step of `/improve-prompts` that names a section here. Read only that section.

## Facts to write down

Step 2. Fill each note from the guide and the project-facts bullets, as an exact command or path. Later steps use these names.

| Note | App prompts | Agent prompts |
|---|---|---|
| `<tool>` | how to run the tool, and from which folder | the harness script |
| `<log>` | the experiment log | the experiment log in the lab |
| `<review-set>` | the fixed inputs per kind (`<target>` must be one of the kinds) | the rows `<tool> tasks` prints for `<target>` |
| `<run-one>`, `<fill>` | run one input; run a batch, several at a time | `<tool> snapshot`, `<tool> run`, `<tool> fill` |
| `<show>`, `<review>` | read one run; save a review; comment on a run | `<tool> show` (blind), `<tool> review` |
| `<scorecard>`, `<tag-tally>`, `<pair>` | ratings per version and kind; tags per batch; paired comparison; the signal that the pipeline repaired a reply | `<tool> score`, `<tool> pair` |
| `<new-version>`, `<diff>`, `<make-current>`, `<discard>`, `<rerun>` | make, list, diff, accept, discard a version; rerun an earlier run | `<tool> version new`, `version add`, `version diff`; `fill --like --version` |
| `<adopt>` and after | adopt; the clean-up after it; analyze and test commands; any pre-deploy gate; where the change is recorded; where lessons go | `<tool> version adopt`; the wrapper, check and changelog commands from **Agent prompts** |
| model | the production model, its sign-in check, any fallback | the default free model and CLI; which models count as paid |
| rules and shapes | which prompt file decides what; the review shape (rating and problem tags) | the review shape; the commands never trialled and what the sandbox cannot reach |
| lessons | lessons from earlier rounds; how the project handles other sessions editing the same files | the same |

## Writing a planted task

For an agent prompt whose command has no planted task yet (Step 4). Write the task with the harness guide's task layout, then:

1. Plant one realistic problem the command exists to catch.
2. Script the owner's replies at the command's stop points.
3. Make every check a fact a script can test: a name the reply must mention, the files a turn may change, what a file must hold after.
4. Run the new task once on a strong model, and read its checks by hand: a check a correct run fails is a broken check, not a finding. Fix the check before any experiment uses it.

Never write a task for a command that touches a live environment.

## Review tags for agent prompts

Reuse one of these before inventing a tag (Step 5):

| Tag | The agent… |
|---|---|
| `SKIPPED_STEP` | left out a step |
| `IGNORED_STOP` | edited before the owner answered |
| `FALSE_SUCCESS` | said done or green without checking |
| `WRONG_PATH` | read or cited a file that does not exist |
| `INVENTED_COMMAND` | ran a script or flag that does not exist |
| `TOOL_MISMATCH` | called a tool another agent has, by its name |
| `PLACEHOLDER_LITERAL` | typed `<name>` or `$ARGUMENTS` as written |
| `LOST_IN_INDIRECTION` | never reached the doc the prompt points at |
| `CONTEXT_FLOOD` | read whole large files until it lost the thread |
| `LOOPED` | repeated the same call |
| `GAVE_UP` | stopped without finishing |
| `SCOPE_CREEP` | changed files it was not asked to |
| `FORMAT_DRIFT` | wrote a report or record not in the asked shape |
| `WRONG_ANSWER` | reached a finding that is itself wrong |

## Where the fix goes

Step 6. Go down the table for your target's type and stop at the first row that fits.

App prompts:

| Cause | Fix |
|---|---|
| a code bug: something dropped, merged or misread | fix the code and add a test. Not a prompt experiment |
| a missing or wrong prompt rule, and the tag has survived fewer than two prompt experiments | one small, general rule, never a special case for one input, in the prompt the model reads at the moment it makes that decision (the guide's rule map) |
| the same tag survived two prompt experiments (`<log>`) | a check in code that re-asks the model with a reason; if the model gets few attempts, the reason says exactly what to change |
| the right answer can be computed | a fixed repair in code |

Agent prompts:

| Cause | Fix |
|---|---|
| a broken reference: a path, script, flag or step number that is wrong | fix it. Not an experiment, but rerun the batch (Step 4) to get a clean baseline |
| the agent computes something a script could: find files, compare lists, count, check a format | script the step: a ready-made command to run and a short output to read |
| the tag has survived fewer than two wording experiments | reword at the point of use: the instruction the agent needed, in the step where it needs it |
| the tag survived two wording experiments (`<log>`) | a gate: a check script the command runs and must see pass |

## What weak agents trip on

Check the prompt for these before choosing the change (Step 6), in rough order of cost:

- **Context budget.** Everything always loaded (the agent guide, rules, skill descriptions) is read before the prompt; a long prompt on top pushes the task out. Shorter is a valid change.
- **Indirection.** "See the doc that owns X" costs a weak agent a search it may never finish. Name the file, or the command that finds it.
- **No ready-made command.** A step that says what to find but not the exact command to run gets an invented one.
- **No "done when".** A step without its finish line gets skipped or never ends.
- **Stop points.** "Ask the owner" mid-command must say what to show and that nothing changes until the answer.
- **Far-away negations.** A "never" stated once at the top is forgotten by the step it applies to.
- **Also:** judgment a script could make, success claims nobody checks, literal placeholders, tool names from another agent, output with no cap, steps nested three deep, an output shape described but not shown, more than three choices at once.
