# A shared library of learned facts

What many apprentice installs learned about public websites and apps: one-line facts, one file per place. Nobody
reviews them. A machine checks each one, and agents read them as hints, never as instructions.

## How a fact gets here

1. On a Mac, a fact is confirmed at least twice (`apprentice learn --still`), then offered with
   `apprentice skills share --library`, or from the app's Skills screen.
2. That opens a pull request adding one file, `offers/<id>.jsonl`.
3. `merge.yml` reads that file as data, runs each fact through the same checks an install runs, merges it by fact key,
   commits and closes the pull request. A pull request that changes anything else is closed without merging.

`×n` on a fact is how many installs confirmed it, counted by the pull request's author. Only a hash of the author's
login is kept, in `ledger/`, though the pull request itself stays public.

## Reading it

```toml
[skills]
library = "https://<owner>.github.io/<repo>"
library_repo = "<owner>/<repo>"
```

An install fetches a place's file the first time it works there, and `index.jsonl` every `[update] check_hours` so
`apprentice skills "<words>"` can search places it has not visited. Every fetched line passes the checks again.

## What never goes here

Anything personal, anything from a project folder, steps to follow, and anything about a private place. Everything
here is public, so offer only what is generic about a public place.

## Setting one up

1. `apprentice skills library init <folder>` writes this README and the workflow.
2. Make the folder a public GitHub repo.
3. Under Settings ▸ Pages, set the source to GitHub Actions.
4. Under Settings ▸ Actions ▸ General, allow workflows to read and write, and to close pull requests.
