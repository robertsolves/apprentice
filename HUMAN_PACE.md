# deskkontrol: Human-Paced Input and False-Positive Reduction

Automation is most reliable when its input follows the same patterns as ordinary use of the machine. deskkontrol already bends the pointer along a Bézier curve, spaces keystrokes log-normally and picks a random point inside a control. What remains are compatibility and pacing gaps: most web clicks never move the pointer at all (tier 1 AX press), typing injects Unicode with `keyCode 0`, and actions land on a metronome. On a site that rate-limits sessions or challenges unusual input, those differences can produce a false positive on Robert's own account. This doc lists the differences and the changes that close them. Volume caps, soft blocks, challenges and site policies stay in `SITE_RULES.md`.

**What this is for.** Keeping permitted work — reading, drafting, routine changes, and QA in Robert's own logged-in profile — inside the pacing a person would produce, so the account isn't restricted by mistake. A session that outruns any plausible person is hard on the site, hard to debug and more likely to be stopped.

**What this is not.** It does not solve CAPTCHAs, 2FA or identity checkpoints, spoof fingerprints or browser state, get around a site's terms or access controls, or continue after a site has said stop. The pacer cannot make prohibited automation permitted. `SPEC.md` keeps challenge bypass out of scope, and exit 8 still means stop and hand the session to Robert. Anything here that would conflict with a site's terms stays decided by the `[policy]` entries in `SITE_RULES.md`.

## What a site measures

| Signal | Today | Difference from ordinary use |
| --- | --- | --- |
| Pointer path | Cubic Bézier, ease-in-out, 120 Hz, ±0.6 px wobble | Very clean; no overshoot, correction or pause |
| Click point | Uniform random in the middle 60% of the element | Uniform, not clustered near the visual centre |
| Pointer before activation | Tier 1 AX press fires no pointer event | Page receives `click` with no `pointerover`, `pointermove` or `mousedown` |
| Hover | Only the explicit `hover` command | No hover before a click |
| Click timing | 50–100 ms down, 20 ms up, 80 ms double gap | Fixed double gap; no slow presses |
| Key timing | Log-normal, median 100 ms, 1.6× after space or punctuation | No word rhythm, no thinking pauses |
| Key identity | Unicode injection with `virtualKey: 0` | Every key is `keyCode 0`; no real Shift |
| Corrections | None | No wrong key, no backspace, no retype |
| Field entry | Focus, `cmd+a`, replace whole value | Never appends; always selects all |
| Scroll | One wheel event of `count * 3` lines | No momentum, no read pause, pointer often not moved |
| Cadence | 0.5–2 s random, 30 actions/min | Even spacing and a high ceiling; no burst then rest |
| Session | `run` stops at 40 steps or 15 minutes | No daily shape, no breaks, no quiet hours |
| Focus | `postToPid` works on an unfocused window | Some pages ignore input when `hasFocus()` is false |
| Navigation | `open` can jump straight to a deep URL | No referrer chain or history for in-site flows |

## Pointer

**Current.** `Mouse.move` runs a cubic Bézier with control points offset to one random side, an ease-in-out profile, about 120 events per second, a Fitts' law duration clamped to 200–900 ms, and ±0.6 px jitter. `Mouse.landing` picks uniformly inside the middle 60% of the target. `Mouse.click` holds the button 50–100 ms, releases after 20 ms, and uses a fixed 80 ms gap for a double click.

**Changes.**

1. **Landing point.** Draw from a Gaussian centred at 45–55% of the width and height, with a sigma of 12–18%. Reject points within 8% of an edge. If the element is larger than 40 px and the previous click was within 6 px, pick again. Pointer users cluster near the middle and near the label; uniform placement does not match that.
2. **Two-phase path.** Aim at 92–97% of the distance ballistically, then finish with a 40–140 ms correction. On about one move in three, overshoot by 2–8 px and correct back. Keep the Bézier and Fitts duration, but let short moves be nearly straight and long moves bend more.
3. **Settle before pressing.** After arrival, wait 40–120 ms with one to three micro-moves of at most 1.5 px, then press. This produces a real hover dwell and avoids `mousedown` on the same frame as the last move.
4. **Click timing.** Sample button hold from 60–140 ms, the up-to-next-down gap from 70–130 ms, and the double-click interval from 70–130 ms. Add an occasional 1–3 px miss and retry on low-risk controls, under 2% of clicks. Never do this on a gated or irreversible control.
5. **Idle drift.** While waiting, in `wait-for`, or between steps, drift 5–20 px every 2–5 s. A pointer that never moves between actions does not match how a person uses the machine.
6. **Pointer-first web clicks.** For a browser target, move the pointer and send a real `CGEvent` click before falling back to `pressElement`. Keep AX as the fallback, and keep `--tier 1` as the fast escape. Pages that rely on pointer events then receive the same sequence a mouse produces, in order, which is also the more compatible path for menus, drag targets and canvas widgets.
7. **Scroll first.** Move the pointer to the scroll point even without `--in`, then scroll in 2–7 wheel events with 10–30 ms gaps and decaying deltas. Add a 1-line reverse correction sometimes, and pause 150–500 ms before and after. Optionally set the momentum phase so the page receives an inertial tail. Read for 1–3 s before the next action.
8. **Borrow order.** In `Borrow.run`, bring the previous app forward before warping the cursor back, so the teleport isn't in front of the session window. Prefer a short move over `CGWarpMouseCursorPosition` when the distance is small.

## Keyboard

**Current.** `Pace.keyGap` gives a log-normal gap with a 100 ms median, sigma 0.4, a 1.6× multiplier after space or punctuation, clamped to 40–900 ms. `Keys.typeChar` sends one Unicode string with `virtualKey: 0`. `Keys.type` waits 150–350 ms before the first key and never mistypes. `type` focuses the field, sends `cmd+a` and replaces the value. Holds are 20–50 ms for letters and 30–70 ms for modifiers.

**Changes.**

1. **Real keycodes.** Map printable ASCII to its `CGKeyCode` and set `.maskShift` for capitals and shifted symbols. Keep Unicode injection only for non-ASCII, emoji and IME text. Beyond matching ordinary input, this is the correct fix: pages and native fields see the same `keyCode`, `code`, `shiftKey` and `key` a keyboard produces, and layout-dependent shortcuts keep working.
2. **Word rhythm.** Keep log-normal gaps inside a word, then add structure: 80–400 ms at a word boundary, 200–600 ms after punctuation, and 0.8–3 s every 20–40 characters as a thinking pause. Let the median drift ±15% over a long field. Raise the clamp to about 2.5 s.
3. **Corrections.** On 1–2% of letters, type a neighbouring key, wait 100–350 ms, press backspace once or twice and retype. Cap it at three per field. Disable it entirely for password, one-time-code, payment and secret fields, and log the count, never the text. The rate is configurable and defaults low; set `key_error_rate = 0` to turn it off.
4. **Field entry.** Click or focus the field, wait 100–300 ms, and append at the caret when the field is empty. Use `cmd+a` only when replacing a non-empty value. A value that appears with no `keydown` is exactly what `--pace fast` looks like, so keep that flag as the deliberate exception.
5. **Hold and overlap.** Sample 55–110 ms for a letter and 90–160 ms for a modifier. Press the modifier 20–60 ms before the key and release it after. The current 20–50 ms holds are shorter than most people type.
6. **Layout awareness.** Shift for capitals instead of a Unicode string. Skip correction around accented characters and non-US layouts, where a neighbour key often produces a different character entirely.

## Reading and dwell

`finish` already re-reads and diffs after every action, but an agent can act again immediately. Add a minimum dwell based on what changed:

| Moment | Dwell |
| --- | --- |
| Same screen, small diff | 0.3–0.8 s |
| New page or large diff | 0.8–2.5 s |
| Opened a post, profile or thread | 3–8 s before acting |
| After a scroll | 1–3 s before the next action |
| Before like, follow or comment | Hover the control 200–600 ms first |

`wait-for` should use the same floor. Do not act while the diff is still arriving: a click during a re-render is unreliable on its own terms, and it also compresses the session faster than a person could work.

## Cadence and session shape

**Current.** `Limits.paceAction` waits a uniform 0.5–2 s between web actions, `checkActions` allows 30 actions per minute, `checkNavigation` enforces a 5 s gap and three loads of the same URL per 120 s. The `run` loop stops at 40 steps, 15 minutes, or three identical actions.

**Changes.**

1. **Gaps by kind.** Replace the single window with a distribution per action kind: read 1–4 s, scroll 1–3 s, like 8–25 s, comment 30–120 s, follow or connect 45–180 s, post minutes apart. `between_actions_ms` becomes the floor, and these distributions sit on top of the budgets in `SITE_RULES.md`.
2. **Bursts and rest.** After 4–6 actions, take 20–90 s. After 30–60 s of steady work, take 3–10 minutes. Today only the per-minute cap does this, and it does it abruptly.
3. **Session shape.** Aim for 20–45 minutes active, 10–30 minutes away, and 2–5 sessions per domain per day. Vary start times by ±40 minutes instead of starting at the same minute daily. Do not run at 3 a.m. unless the account normally does.
4. **Agent loop.** Add the dwell and the burst pause to `AgentLoop`, and stop with a clear message when the same action keeps succeeding but nothing changes on screen, not only when three actions are identical.

## Page and environment

- **Focus and visibility.** `CGEventPostToPid` reaches a background window, but `document.hasFocus()` and `document.visibilityState` are false, and some pages ignore or mis-handle that input. For pages that require focus, raise the window, act, and restore the previous app. Treat a diff that never arrives after two tries as a focus problem, not a stale id.
- **Navigation.** Prefer clicking in-site links for flows, so the referrer and history look normal. Use `open` for the first entry, a bookmark, or a deliberate redirect, not for every step.
- **One tab, one window.** The existing rule stays: no extra tabs or windows, and no parallel sessions on the same account.
- **No fingerprint spoofing.** A real logged-in Safari or Chrome profile is the advantage here. Don't inject JavaScript, touch canvas or audio, or fake WebDriver state. deskkontrol has no CDP or WebDriver surface to leak.
- **Consistency.** Keep locale, time zone, VPN exit and device the same as the account's normal use. Switching all four for one session is a larger change than any pointer path, and it makes the session harder to support.

## Platform notes

Each platform weighs volume and timing differently. These notes set the slower end of the range for the caps in `SITE_RULES.md`; they do not change what is permitted.

| Platform | What to slow down | Notes |
| --- | --- | --- |
| Instagram / Facebook | Per-session action velocity, pointer and typing, link shims, app deep links | Terms forbid automated actions; keep out of the allowlist and stay read-only |
| TikTok | Watch time, scroll pattern, comment velocity | Mechanical scrolling through the feed compresses watch time; read-only unless the policy changes |
| LinkedIn | Connection and follow velocity, profile and feed dwell | Slowest profile; 3–8 s on a profile before any action |
| Reddit | Account age, karma, subreddit rules, upvote velocity | Read the community rules first; API first, as with GitHub |
| X | Post, repost and follow velocity, read-before-action | API first; slow the timeline scroll |

A challenge or checkpoint is still exit 8: stop and let Robert handle it. No pacing change makes continuing through one appropriate.

## Config

Add these to `[pace.default]`, and override per domain or app as today:

```toml
[pace.default]
click_settle_ms = [40, 120]
click_hold_ms = [60, 140]
overshoot_px = [1, 8]
key_error_rate = 0.015
word_pause_ms = [80, 400]
thinking_every = [20, 40]
thinking_ms = [800, 3000]
scroll_events = [2, 7]
scroll_gap_ms = [10, 30]
dwell_s = [0.8, 2.5]
idle_drift = true
web_pointer = true

[pace."linkedin.com"]
inherit = "default"
dwell_s = [3, 8]
```

`linkedin.com` is the example of a slow profile; use the same pattern for any domain where the defaults feel fast. `--pace fast` and `[pace.native] mode = "fast"` stay the deliberate escapes.

## Telemetry

Without knowing whether a site actually restricted the account, tuning is guesswork. Measure the pacing and compare it with a flag from `SITE_RULES.md` if one occurs.

- `deskkontrol pace` prints the active profile and the timing summary for the last 20 steps.
- Add to `steps.jsonl` per action: tier, path length, peak speed, landing offset as a fraction, hold and gap, whether the pointer moved first, and correction count. Never log content.
- `deskkontrol activity <domain> --pace` shows the gap histogram, tier mix and click-offset spread. Line it up with `deskkontrol flag` timestamps: the 48 hours before a flag against a normal week.
- Test fixtures: 1,000 generated paths should show a spread of curvature and overshoot, typing 500 characters should land around 35–65 WPM with a gap CV near 0.5–0.9, and every web click should be tier 2 unless explicitly forced.

## Order of work

The first two remove the clearest compatibility gaps.

- [ ] Pointer-first web clicks (`clickApproved` in `Commands.swift`)
- [ ] Real keycodes and Shift in `Keys` (`Input.swift`)
- [ ] Settle, overshoot and Gaussian landing (`Mouse.landing`, `Mouse.move`)
- [ ] Split scrolling, momentum and read pauses
- [ ] Word rhythm, thinking pauses and corrections
- [ ] Dwell and per-kind cadence, wired to the budgets
- [ ] Session shape, idle drift and focus handling
- [ ] `deskkontrol pace`, telemetry and the test fixtures

Measure before tuning, and don't raise a cap to make up for slower pacing. The point is fewer accidental restrictions on work the account is allowed to do, not more actions in the same minute.
