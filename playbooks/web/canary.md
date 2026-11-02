---
scope: site
match: apprentice-canary
tags: canary, test page, full test, self-test, bot detection, input fidelity
lang: en
verified: 2026-11-02, macOS 26.2, Chrome; Linux VM, Chromium
status: partial
---
# The canary test page (agent/canary.html)

A local page that exercises every feature apprentice claims and measures what a page sees about its input. Serve it on the machine the browser runs on (`python3 -m http.server --bind 127.0.0.1` in its folder; in the VM over ssh), then `open {url}` (the page on that server).

## Key facts
- The right-hand panel lists 32 checks; "N of 32 passed" is its first row. Checks survive a reload (session storage).
- Sections are links at the top (Typing, Map, Widgets, …); each is a route of one page, so `key cmd+[` goes back between them.
- The password check only passes with the user's own approval (`confirm`): that is the gate working, not a failure.
- The Metrics section holds the measurements BOT_DETECTION.md asks for: deltas, key holds and overlap, Shift keydowns, wheel deltaMode, click holds, blur.
- `apprentice do canary-full-test --url "{url}" --message "{message}" --email "{email}"` runs the whole test with one approval.

## Works
- Map: three `drag --by -450,-280 --in #text "Drag the map from here"` (a fixed spot in the map's corner) bring the Treasure pin into view at zoom 1; zoom with `scroll up 3 --at` a point off the map's centre.
- Volume slider: `drag --by 50,0 --at` the thumb (left end plus a fifth of the track at value 20).
- `download` saves the report link; `upload` attaches a file through the system dialog.

## Fails
- The Treasure pin moves with CSS transforms and its position can read stale after a zoom; `click --at` where it shows.
- In the VM the select's value reads empty, and the sketch pad canvas is not listed: drag `--at` on it.
