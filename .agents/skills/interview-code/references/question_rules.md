# Question rules for the code interview

## Contents

1. Exclusions
2. Worth interviewing, or not
3. The three question categories
4. Obviousness filter
5. Question and batch format
6. Question examples

## Exclusions

Never walk these, whatever the language:

- Generated files (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, `*.pb.go`, `*_pb2.py`, `*.gen.ts`, `*.generated.*`, anything under a `generated/` directory).
- Barrel or index files that only re-export siblings.
- Build, cache, vendor and VCS directories (`.dart_tool/`, `build/`, `dist/`, `out/`, `target/`, `coverage/`, `.next/`, `__pycache__/`, `.venv/`, `node_modules/`, `vendor/`, `.git/`).
- Third-party code this repo does not own, even when checked in.
- Lock files and manifests (`pubspec.yaml`, `pubspec.lock`, `package.json`, `package-lock.json`, `Cargo.toml`, `Cargo.lock`, `go.mod`, `go.sum`, `pyproject.toml`, `requirements*.txt`).
- Test files (`*_test.*`, `*.test.*`, `*.spec.*`, anything under `test/`, `tests/`, `__tests__/`), unless the user opts them in at the start.

Processing order, unless the user overrides it: server-side routes and handlers, then data access, then client state and services, then client screens and components, then shared code, then the rest grouped by directory, alphabetical inside each group.

## Worth interviewing, or not

Worth interviewing when you can name at least one real product question:

- The code makes a user-visible choice the docs do not pin down.
- The docs say X and the code does Y.
- The code encodes a rule (threshold, default, silent fallback, piece of copy) that neither the docs nor the brief justify.

Not worth interviewing when any of these holds:

- It mirrors an external spec 1:1 (a data model mirroring a schema, a DTO mirroring an API shape).
- It is pure composition or glue (route assembler, screen that only lists child components, barrel).
- It is a small utility whose behaviour is obvious from name and signature.
- Every method is a thin pass-through (CRUD, getter, `toJson`/`fromJson`).
- Every candidate question is a style or code-organisation point.
- The docs or the brief already answer every candidate. Then make the code match and do not ask.

If a candidate cannot be phrased as "a user does X, what should happen?" in plain product language, skip the file and keep the code-quality issue to yourself.

## The three question categories

Nothing else is in scope.

- **scenario-gap**: a real user does X, the code chooses, the docs are silent.
- **contradiction**: the docs describe behaviour A, the code does B. Tag it `[scenario-gap]` and name both behaviours in the options.
- **encoded-behaviour**: the code embeds a product rule the user should have chosen.

Out of scope: names, formatting, helpers, layer violations, abstractions, where error handling lives, convention checks, anything a linter or type-checker would catch. Missing error handling counts only when the user-visible behaviour of that branch is itself unclear; then the question is about the behaviour.

## Obviousness filter

Drop a question when any of these is true:

- You can infer the answer from the brief, the docs, similar choices elsewhere in the codebase, or common sense. Act on it instead, or say nothing if the answer is "fine as is".
- A product owner would give the same answer ten times out of ten.
- The user would not see, hear, tap or wait differently between the options.
- The interesting part is the implementation (which class owns a method, where errors are handled).

Imagine the user reading each question alone on a phone. If it has a clear right answer to anyone who knows the product, do not ask it.

## Question and batch format

Each question is self-contained: no class, method, file path or line number, no "in this file". It describes the user's experience ("When a user does X, ..."), is answerable in one line or one letter, and carries one tag: `[scenario-gap]` or `[encoded-behaviour]`.

```
Questions 1-3 of N

1. [scenario-gap] A new user signs up and types in a referral code that doesn't exist.
   Should they: (A) see no feedback and continue, (B) get a non-blocking "we didn't recognise that code" toast, or (C) get a blocking message and have to remove it?

2. [encoded-behaviour] Right now, users can change their signup source ("how did you hear about us") later on. Is that intended, or should it be set once at signup and frozen after?
```

Fewer than three real questions: ask only those in one batch. Zero: print "No real product questions after closer reading" and move on without writing anything. Never pad.

## Question examples

Acceptable:

- "When a user enters a referral code that doesn't exist, what should they see: silent accept, a non-blocking toast, or a blocking error?"
- "When a user ticks an item offline and their partner ticks the same item online, whose tick wins after reconnect?"

Never ask:

- "Should we add `AccountRepo.patchAccountFields()` or keep the raw SQL?"
- "Should we wrap `redeem` in try/catch?"
- "Should this screen read the shared state directly, or go through the service that owns it?"
