# apprentice — bug audit

## Field reports

Filed by `apprentice bug` while working. Each has a suggested fix to review; none is applied.

### F1 · Elements moved by a CSS transform keep a stale frame — 2026-11-02
Confirmed on the canary map in Chrome: after panning and zooming, the Treasure pin was listed with a 1×1 frame at the map's edge while it showed elsewhere, so `click <id>` and `click --on` hit the edge and changed nothing (`click --at` worked).
Cause: Chrome's AX bounds for children of a transformed, `overflow: hidden` parent lag or clip to the parent's edge; the walker keeps an element whose frame is a single pixel.
Suggested fix: drop elements whose visible frame is under 2×2 px from the list (or mark them `offscreen`), and when a click on a listed element changes nothing, re-read its frame once before reporting.

### F2 · VM reader: a `<select>` shows an empty value, and a canvas is not listed — 2026-11-02
Confirmed in the VM's Chromium on the canary: `combobox "Fruit" value=""` after choosing Banana, and the sketch pad canvas never appears in `read`, so a flow cannot name it.
Cause: `helper.py` reads the combo box's text, which Chromium leaves empty (the choice is its selected child's name), and classifies no role for a canvas.
Suggested fix: for a combo box, report the selected child's name as the value; map Chromium's "canvas" role to `image` when it has a name.

### F3 · Gate words match text inside a flow step's target — 2026-11-02
Confirmed: `do canary-full-test` flagged `scroll down 40 --in #text "Post 1 · a short update about …"` as "may be irreversible", because the post text contains "update".
Cause: the plan's ⚠ check runs `Gate.matches` over the whole step, quoted target text included, even for commands that only look or scroll.
Suggested fix: skip the gate-word check for scroll, browse, hover and wait-for steps, and match only the element's name for the rest.

### F4 · A flow placeholder named like a boolean flag can never be filled — 2026-11-02
Confirmed: a flow step with `{text}` made `do <flow> --text "…"` fail with "needs --text", because `text` is in `Args`' boolean flags, so its value is dropped.
Cause: `Args.parse` treats `--text` (and `--force`, `--all`, …) as booleans for every command, `do` included.
Suggested fix: have `do` read `--<name> value` pairs from the raw arguments for the flow's own placeholders, or have `learn` and `playbooks --check` refuse a placeholder that is a boolean flag name.

### F5 · First `open` in a new Chrome window can report the page as stale — 2026-11-02
Suspected: once, right after `session --new-window`, `open` failed with "stale: the page changed to chrome://new-tab-page/"; a `read` cleared it.
Cause: the session records `chrome://newtab/` from the window, and Chrome then reports the new-tab page as `chrome://new-tab-page/`.
Suggested fix: treat Chrome's internal new-tab addresses as one page in `prepare`, or record the address only after the window has settled.
