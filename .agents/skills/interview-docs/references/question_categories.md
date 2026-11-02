# Question categories

## Scenario gaps

A concrete user journey the doc does not resolve. "A user X — what should happen?" is the strongest question shape. Whenever the doc describes a feature or flow, ask "what does a user see, tap or get when…?" and turn every unanswered branch into a forced-choice question. Examples:

- A user adds an item to a shared list while offline. Their partner ticks the same item from another device a minute later. When the offline user reconnects, do they see (A) their item plus the tick, (B) a conflict prompt, or (C) the tick wins and their item vanishes?
- A user tries to invite someone who already has an account in another group. Does the invite (A) join them to both, (B) ask them to choose, or (C) get blocked?
- A user dismisses a routine occurrence for today. Tomorrow, should it (A) reappear, (B) stay dismissed for the week, or (C) require explicit re-enabling?

## Other categories

| Tag | What to look for |
|---|---|
| unverified-claim | A statement of behaviour, ownership, scope or intent with no evidence that only the user can confirm ("the frontend never enforces permissions" — still true? ever true?) |
| contradiction | Two passages in the file, or the file and a doc already read this session, that disagree |
| vague | "We may want to…", "this might…", "TBD", "should probably", "in the future", "for now" |
| gap | A list of five where a sixth obviously belongs; a flow that ends mid-step; a constraint with no rationale; a trade-off with no resolution |
| stale | A file, endpoint, command or table name that does not match the repo (run `ls` or a capped `rg` before asking) |
| missing-rationale | "We use X" where the why matters and is not given |
| terminology | Two words for one concept, or a word that conflicts with the agent rules or glossary |

## Which categories lead

| The file is | Lead with |
|---|---|
| a product or UX doc (brief, scope, user expectations, a user-facing feature or flow, screen guides) | scenario-gap |
| a pure technical reference (agent rules, stack overview) | the other tags, but frame at least one as a developer scenario ("a contributor adds a new mutation — does the doc say which queue to use?") |

## Batch format

````text
<file path> — questions 1–3 of N

1. [scenario-gap] (L42–48) "<short quote or paraphrase of the passage>"
   Scenario: A user <does something concrete in the product>.
   Why it matters: <one line — what is unclear, what the doc does not say>
   → Should (A) <option>, (B) <option>, or (C) <option>?

2. [vague] (L91) "we may want to support multiple owners"
   Why it matters: doc is silent on whether MVP supports it.
   → In MVP: yes, no, or "decide later"?
````
