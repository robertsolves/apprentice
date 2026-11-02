# Bot-detection audit

**Scope:** apprentice's local macOS sessions and its Linux VM, on websites and in native apps.
**Commit audited:** `6f958ba` (2026-11-02); claims and line references re-checked against `cbd97ad`.
**Method:** static read of `Sources/apprentice`, `agent/vm`, and the shell entry points, plus one-off OS probes of the CGEvent fields apprentice posts. Nothing was changed to make this list.
**Severity:** Critical = a detector can flag it directly and reliably; High = strong signal, especially combined with others; Medium = useful in a risk score; Low = weak or only after long observation.
**Confidence:** “confirmed” = shown by code or the probe; “likely” = strongly implied but needs a runtime test; “speculative” = plausible but unmeasured.

The important split is **who can see a signal**:

- **Page (JavaScript):** only what the browser exposes to the page.
- **Server:** patterns in requests, timing, graph and account history.
- **Native app / OS:** events and process metadata the page never sees. This is where apprentice is most visible.
- **VM:** the Linux guest is a different device and a different browser build even when the Mac side is clean.

## Top findings

| ID | Signal | Seen by | Severity | Confidence |
| --- | --- | --- | --- | --- |
| A1 | Constant event tag `0x646B6374` on every posted event | native app / event tap | Critical | confirmed |
| A2 | Synthetic event provenance: posting PID, private source state, zero mouse deltas | native app / event tap | High | confirmed |
| A3 | `AXManualAccessibility` / `AXEnhancedUserInterface` forced on the app | native app / browser internals | High | confirmed |
| A4 | Keystrokes are strictly sequential, constant hold, no rollover | page (keystroke telemetry) | High | confirmed |
| A5 | Mouse paths are Bézier-shaped, Fitts-timed, capped and always land on target | page (mouse biometrics) | High | confirmed |
| A6 | Per-daemon “hand” changes speed and bend side; no persistent motor profile | page (long-term biometrics) | Medium–High | confirmed |
| A7 | Drag is linear, constant-speed and jitter-free | page (drag/canvas challenges) | High | confirmed |
| A8 | Default pace is `fast`, with no dwell, between-action gap, bursts or fidgets | server / page | High | confirmed |
| A9 | Budget and dwell classification is English-label-only | server / page | High on non-English sites | confirmed |
| A10 | `open` is the only navigation path; no in-site link trail, no referrer | server | Medium–High | confirmed |
| A11 | VM is Linux/Chromium with software WebGL, fixed 1280×800, DPR 1, few fonts | server / page | High for VM | confirmed |
| A12 | VM first session is a new device for every site | server | High | confirmed |
| A13 | VM input is replayed without timestamps; wheel notches can burst | page | Medium | likely |
| A14 | No active-hours, session-length or long-break model | server | Medium | confirmed |
| A15 | VMs from one image normally share an identical fingerprint | server | High for multi-account | confirmed |
| A16 | Soft-block detection is English-only and only checks new elements; challenge text markers are English | server response | Medium–High | confirmed |
| A17 | Programmatic window raise/focus without a click or key in the page | page / app | Medium | confirmed |
| A18 | Accessibility reader walks up to 40,000 nodes per snapshot | native app (AX provider) | Low–Medium | confirmed |
| A19 | Window/screen geometry fixed on the VM; VM process footprint visible in guest | page / app | Medium | confirmed |
| A20 | No reaction time before the first pointer movement | page | Low–Medium | confirmed |
| A21 | Characters with no key on the layout are posted on keycode 0, the “a” key (`code: "KeyA"`) | page | Medium | confirmed |
| A22 | One tab for everything: history only grows, never back, never reload | page / server | Medium | confirmed |
| A23 | Page never hidden, never blurred: window always in front for the whole run | page | Medium–High | confirmed |
| A24 | No consent/cookie step; a consent wall is left standing or hit blind | server | Low | likely |
| A25 | Power assertion named “apprentice: a task is running”; display never idle-locks | local process / user | Low–Medium | confirmed |
| A26 | Notifications posted by `osascript`, one short-lived process each | local process | Low | confirmed |
| A27 | Screen Recording entitlement and capture indicator during image snapshots | OS / user | Low | confirmed |
| A28 | Guest `/tmp/apprentice-session.env` and `/etc/environment` name the rig | guest app | Medium for guest apps | confirmed |
| A29 | Xvfb exposes only the XTEST fake input devices | guest app | Medium | likely |
| A30 | Accessibility forced on at the session bus; launched apps inherit the helper’s environment | guest app | Low–Medium | likely |

The rest of this document explains each item, what a detector can actually observe, and what can be done about it without adding fingerprint spoofing (a project non-goal).

---

## Checklist

Every known way a page, a server, a native app or the VM can tell apprentice from a person. Work top to bottom per surface; a box is ticked only when a canary run (priority fix 14) or a VM session shows the signal gone or reduced to noise, with the commit that did it. Severities and IDs match the detail sections; an item marked **accepted** is not to be “fixed” by spoofing.

**Added:** `43591b2` (2026-11-02).

The top-findings table numbers its own rows A1–A30; the section IDs below are per-section (P, S, A, V, D). Rows A10–A20 alias section items — A10 = P10, A11 = S6, A12 = S6, A13 = V4, A14 = S4, A15 = S8/V6, A16 = S3/D1, A17 = P9, A18 = A5, A19 = V3, A20 = P13 — and A21–A30 are new: A21 = P16, A22 = P17, A23 = P18, A24 = S10, A25 = §3 A10, A26 = §3 A11, A27 = §3 A12, A28 = V9, A29 = V10, A30 = V11. Ticking the section item covers the alias.

### Page JavaScript

- [ ] **P1 · Keystroke rhythm** — High. Typing telemetry sees a uniform 50–110 ms hold, a log-normal gap (100 ms median), and a keydown/keyup pair that never overlaps; `fast` cuts the gap to ~35 ms. Fix: per-key hold distributions, overlapping keys, digraph and word gaps, one profile per account; no `fast` on a web page.
- [ ] **P2 · Key/code mismatch for exotic characters** — Medium. `key`, `code`, `keyCode` and the inserted text can disagree for accents that need dead keys, emoji and unmappable symbols; on the VM `code` can be a spare keycode. Fix: refuse or route characters the layout cannot type, keep dead keys for accents, restore the X keymap after a temporary keycode.
- [ ] **P3 · Shift without a Shift key event** — Low–Medium. On macOS Shift is only a flag on the letter event; a listener tracking modifier keydown/keyup sees no modifier. Fix: post real Shift down/up around capitals.
- [ ] **P4 · Mouse paths** — High. Bézier curves from five fixed families, Fitts durations clamped at the 200 ms default (long moves all hit the cap), ~120 samples/s, one-sided bend, always lands on target. Fix: more shape families, jittered sample interval, no duration plateau at the cap, occasional genuine miss-and-correct.
- [ ] **P5 · Per-daemon hand** — Medium–High. Speed (0.85–1.2×) and bend side are redrawn on every daemon start, so the “person” changes after an update or restart. Fix: persist the hand and timing draws per account in `~/.apprentice`.
- [ ] **P6 · Click geometry and timing** — Low–Medium. Clicks cluster near the element centre with a 60–140 ms hold, always after a full stop, never during motion, never a miss. Fix: wider geometry and hold spread, some clicks during the settle.
- [ ] **P7 · Linear drag** — High for drag challenges. Button down, 120 ms pause, constant 12 ms steps on a straight line, no tremor, no easing, button up. Fix: reuse the stroke generator with easing, jitter and a variable hold.
- [ ] **P8 · Wheel units and bursts** — Medium. `deltaMode` is line, no momentum or trackpad phase; the VM replays notches with no delay so a flick arrives as one timestamp. Fix: pixel deltas with decaying momentum, occasional phase events, per-notch delays in the guest.
- [ ] **P9 · Focus raised without a click** — Medium. `focus`/`visibilitychange` with no preceding pointerdown or keydown inside the page, then synthetic input. Fix: prefer an in-window click when the cursor is already there; keep the raise as a fallback and vary it.
- [ ] **P10 · URL-bar-only navigation** — Medium–High server-side. Every page is a direct visit: no in-site link click, usually no referrer. Fix: make in-site links the default path and `open` the exception (first entry or a deliberate deep link).
- [ ] **P11 · Click-select-type form entry** — Low–Medium. Tab is never used and `cmd+a` immediately precedes typing on filled fields. Fix: Tab between fields, less uniform selection.
- [ ] **P12 · No IME composition** — Medium for CJK. Direct Unicode insertion with no `compositionstart`/`update`/`end` while `navigator.languages` says `ja-JP`/`zh-*`/`ko-KR`. Fix: a real composition path for IME locales.
- [ ] **P13 · No reaction time** — Low–Medium. The first pointer move starts immediately when a page or element appears. Fix: draw a reaction delay after a focus or page change.
- [ ] **P14 · Pointer perfectly still** — Low. `fidget` and `browse` default to 0 and `dwell_s` is 0, so the cursor can sit on one pixel for minutes. Fix: idle micro-motion by default on web sessions.
- [ ] **P15 · Forced accessibility** — Medium at browser level. No standard page API, but the browser knows the AX tree is forced on permanently. **Accepted** (the tree is how the tool reads the page); scope it to web areas only where possible (A3).
- [ ] **P16 · Unmappable characters on the “a” key** — Medium. `keyFor` falls back to keycode 0 for characters the layout has no key for, so an emoji or CJK arrives as `key: "€"`, `code: "KeyA"`, keycode 65. Fix: type only what the layout can produce, or take a dead-key/composition path.
- [ ] **P17 · One tab, history only grows** — Medium. `open` reuses the current tab (`cmd+l`), there is no new-tab, back or reload path, so `history.length` climbs all day, navigation type is always `navigate` and the referrer is always empty. Fix: new tab per site, back within a site, occasional reload.
- [ ] **P18 · Never hidden, never blurred** — Medium–High. Each action raises the window and nothing backgrounds the browser, so `visibilityState` stays `visible` and `hasFocus()` stays true for hours, with no `blur` or `visibilitychange`. Fix: leave the tab now and then; don’t raise a window that is already in front.

### Server

- [ ] **S1 · Fast default cadence** — High. `between_actions_ms = 0`, `dwell_s = 0`, `burst = 0`, `actions_per_min = 30`, `key_error_rate = 0`; only `careful`/`steady` and the per-site profile change it, and only LinkedIn/X/Reddit get those in the example config. Fix: make `steady` the web default and add a social profile covering Instagram, Facebook and TikTok.
- [ ] **S2 · English-only budget classification** — High on non-English sites. English label lists miss “Gefällt mir”, “いいね”, icon-only hearts and custom labels, so the click gets no per-kind cap and no dwell. Fix: classify by role, accessible name, icon alt and per-locale synonyms; treat any gated control as budgeted when unsure.
- [ ] **S3 · Narrow soft-block/challenge detection** — Medium–High. English phrases, new elements only, no localized banners; the tool keeps acting and the site escalates. Fix: scan all visible text, support localization and a user phrase list, stop on an in-place banner.
- [ ] **S4 · No active-hours or session-length model** — Medium. Nothing stops a dense block at 03:00 local time or a session with no long break. Fix: quiet hours, maximum session length, long break after N actions, daily cap under the budget caps.
- [ ] **S5 · No link trail** — Medium–High. A run of `open` calls is a run of top-level navigations with no click path or referrer before the like/follow. Fix: same as P10.
- [ ] **S6 · VM is a different device** — High for high-value accounts. Linux Chromium, Xvfb 1280×800, DPR 1, software WebGL, few fonts, no battery/camera/audio, new profile per site. **Accepted** as device identity; keep important accounts on the Mac (`[vm] local`) and warn in `doctor`.
- [ ] **S7 · Remote VM IP** — High. A server-hosted VM is a datacenter IP that does not match the account’s location while the timezone and language say otherwise. **Accepted**; document the VM as a separate device on another network.
- [ ] **S8 · Identical fingerprints across VMs** — High for multi-account. Same image means same browser build, screen, fonts, CPU/memory and timezone offset. **Accepted for out-of-scope multi-account**; do not add fingerprint spoofing.
- [ ] **S9 · `Sec-CH-UA` platform mismatch** — Medium. A real Chromium TLS/HTTP fingerprint that declares Linux while the account’s history is macOS. Part of S6; no spoofing.
- [ ] **S10 · No consent/cookie step** — Low. Nothing handles a consent wall, so it is left standing for the session or hit blind on the first snapshot; a site that keys on consent state sees a visitor who never accepts. Fix: a first-class consent step with dwell and a remembered choice.

### Native app / OS (macOS)

- [ ] **A1 · Constant event tag** — Critical. `eventSourceUserData == 0x646B6374` on every posted event, constant across installs and readable from `NSEvent.cgEvent` or a tap. Fix: stop setting a constant; if monitors must ignore our events, compare `eventSourceUnixProcessID` with the daemon PID or use a per-run random value.
- [ ] **A2 · Synthetic provenance** — High. **Accepted, cannot be removed.** Posting PID, private source state and zero mouse deltas identify CGEvent input in any app that looks; removing A1 removes an easy constant, not the provenance.
- [ ] **A3 · AX attributes forced on the app** — High. `AXManualAccessibility`/`AXEnhancedUserInterface` are set on attach and window search, including native apps that need no web area. Fix: restrict to browsers/`AXWebArea` targets.
- [ ] **A4 · Process and bundle footprint** — High for adversarial apps. `apprentice` in `NSWorkspace`/`ps`, the menu-bar item, `~/.apprentice/sock`, state files, `~/.local/bin`. **Accepted**, part of the tool’s footprint; do not hide it.
- [ ] **A5 · Accessibility query pattern** — Low–Medium. Up to 40,000 nodes at depth 90, re-read after every action — not what a screen reader does. Fix: bound and cache the walk, avoid a full re-read when the diff is small.
- [ ] **A6 · Window activation and event timing** — Medium. `applicationDidBecomeActive`/`windowDidBecomeKey` with no click, then a burst of synthetic events; the app can measure path and timing like a page. Fix: same as P9.
- [ ] **A7 · Screen capture** — Low. **Accepted limitation.** ScreenCaptureKit with `showsCursor = false`; protected/DRM windows refuse. Capture is user-visible, not stealthy.
- [ ] **A8 · VM/X11 artifacts** — Medium for guest apps. `Xvfb`, `openbox`, `x11vnc`, `--force-renderer-accessibility`, the helper process, XTEST. **Accepted**; a guest app can always see its own environment.
- [ ] **A9 · Clipboard writes outside pages** — Low. Pasteboard writes and restores in the address bar and file dialogs are visible to a pasteboard monitor. Keep paste out of pages.
- [ ] **A10 · Power assertion in the system state** — Low–Medium. `pmset -g assertions` shows “apprentice: a task is running” with its PID, and the display never idle-sleeps or locks for the task plus 120 s. Fix: name it plainly, shorten the grace; never call keep-awake invisible.
- [ ] **A11 · Notifications from `osascript`** — Low. Each notification is a `display notification` shell-out, attributed to the scripting host, with a short-lived process per call. Fix: `UNUserNotificationCenter` under apprentice’s own bundle.
- [ ] **A12 · Screen Recording and the capture indicator** — Low. Screen Recording is requested and shown in System Settings, and the capture indicator appears during image snapshots. **Accepted** (the user’s own screen); keep captures window-scoped and short.

### VM (page-visible, on top of S6/S8)

- [ ] **V1 · Software rendering, no hardware** — High. SwiftShader/llvmpipe WebGL, 2 vCPUs, DPR 1, no battery/camera/microphone/audio. **Accepted** as device identity.
- [ ] **V2 · Fonts and locale** — Medium. Only DejaVu and Noto emoji installed; `document.fonts.check` fails for macOS fonts and `APPRENTICE_LANG` silently defaults to `en-US`. Fix: install the account’s real locale fonts and require `APPRENTICE_LANG` (warn in `doctor`) rather than spoofing.
- [ ] **V3 · Fixed geometry** — Medium. Browser at 0,0 on a 1280×800 screen, DPR 1, window exactly the full screen. **Accepted**; do not fake a Retina display.
- [ ] **V4 · Replayed input timing** — Medium (likely). ssh/TCP buffering delivers several input lines in one read and the helper plays them back to back. Fix: send a target timestamp with each op and sleep until it in the guest; batch wheel notches with their own delays.
- [ ] **V5 · Keyboard mapping mutation** — Medium. `keycode_for` remaps a spare keycode and changes the X keymap for characters without a key. Fix: restore the mapping afterwards; prefer a real layout for the account’s language.
- [ ] **V6 · Identical fingerprint across VMs** — High for multi-account. See S8; the easiest way to link accounts meant to be separate.
- [ ] **V7 · WebRTC and network mismatch** — Medium. Candidates and latency show the server network while timezone and language show the Mac. **Accepted**; do not spoof.
- [ ] **V8 · Headful under Xvfb is still detectable** — Low. Not headless, so the `HeadlessChrome` tells do not fire, but it is still a Linux device. Keep the distinction in docs; “not headless” is not “not detectable”.
- [ ] **V9 · Guest env files name the rig** — Medium for guest apps. `/tmp/apprentice-session.env` is world-readable and `/etc/environment` carries `DISPLAY=:0` and `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`. Fix: `chmod 600`, keep tool names out of global environment files.
- [ ] **V10 · Only XTEST fake input devices** — Medium, **accepted**. Xvfb has no pointer or keyboard hardware, so every event is visibly XTEST. Fix: none; do not document VM input as indistinguishable.
- [ ] **V11 · Accessibility forced at the session bus, helper env inherited by launched apps** — Low–Medium. `IsEnabled=true` is set on the bus and `QT_LINUX_ACCESSIBILITY_ALWAYS_ON` reaches every app started from a session. Fix: launch apps with a clean environment; force a11y for Chromium only.

### Detection-response gaps (no signal, but they make the next one worse)

- [ ] **D1 · English-only soft-block and challenge lists** — Medium–High. Localized “try again later” banners and challenges are missed and the tool keeps acting. Fix: localize, accept user phrases, match on URL/title paths.
- [ ] **D2 · Only new elements inspected** — Medium. `Site.inspect` compares keys against the previous snapshot and only on the same URL; a banner that replaces text or appears after navigation is missed. Fix: scan the whole visible tree on the action path.
- [ ] **D3 · Dwell tied to URL changes and budgeted kinds** — Medium. SPA routes that do not update the AX URL, and unclassified actions, get no dwell. Fix: track in-page readiness, not only the URL.
- [ ] **D4 · `actions_per_min` is per host, not per account** — Low–Medium. Subdomains and country domains get separate counters while the site sees the total. Fix: count per registrable domain and per account.
- [ ] **D5 · No cap on uncategorized gated clicks** — Medium. A click matching no budget word (icon-only, “Appreciate”, “Boost”) can bypass the like cap and dwell; with no `budgets.json` there is no cap at all. Fix: fall back to the `default` cap for any gated state-changing control.
- [ ] **D6 · No time-of-day or session-length model** — Medium. Same as S4; a site sees the shape of the session.

### Do not regress

- [ ] No WebDriver, CDP, remote-debugging port, extension or injected page script (`navigator.webdriver` stays false).
- [ ] Every event goes through the system input stream (`.cghidEventTap`; XTest in the guest), so `isTrusted` stays true and the full pointer sequence is produced.
- [ ] No AX presses, AX value setting or `postToPid`; accessibility is read-only.
- [ ] Paste stays out of web pages and contenteditable areas.
- [ ] CAPTCHAs and payments stay manual; no solving, no third-party solvers.
- [ ] Keycodes come from the live layout, never a fixed US table.
- [ ] Randomness stays in one seeded generator; no fixed coordinates or delays across installs.
- [ ] One session, one account, one window; budgets, cooldowns and challenges shared across VMs.
- [ ] No fingerprint spoofing, and no claim in docs that synthetic input is invisible to native apps.

---

## 1. What a website can see (JavaScript)

These are signals a page’s own scripts can collect, whether from a bot-management sensor, a site’s anti-fraud code, or a login/sign-up form.

### P1. Keystroke rhythm is mechanical and non-overlapping — High

Every typed character is:

1. `keydown`
2. a uniform 50–110 ms hold
3. `keyup`
4. a log-normal gap with a 100 ms median, sigma 0.4, 1.6× after space or punctuation, clamped to 40–900 ms
5. then the next `keydown`

The next key is never pressed before the previous key is released. The hold time is drawn from a narrow uniform range and does not depend on the key, finger, hand, word or typing speed. `--pace fast` shortens the gap to 35% (about 35 ms median, 14 ms at the floor), still with no overlap and no corrections.

Real typists overlap keydown/keyup (rollover), hold some keys longer than others, and have per-key and per-digraph rhythms. Keystroke dynamics is exactly what Chu et al. and commercial form-protection products measure. A page with typing telemetry can separate this from a person after a sentence or two.

Evidence: `Sources/apprentice/Input.swift:9-14` (gap), `:118-137` (hold and unicode insertion), `:165-198` (typing loop, corrections, pauses), `:169-170` (fast mode disables corrections).

Mitigation direction: draw hold times per key from a learned distribution; allow overlapping keydowns; vary inter-key gaps by digraph and word; keep a per-account typing profile rather than one profile per style. Do not use `--pace fast` on a web page.

### P2. Key pairs can be impossible for characters that are not on the layout — Medium

`keyFor` returns `(0, false)` when a character has no key on the current layout. The code still inserts the character with `keyboardSetUnicodeString`, so the page can see `key`/`beforeinput` text that does not match the key code. Dead keys are deliberately excluded (`kUCKeyTranslateNoDeadKeysBit`), and emoji/surrogate pairs are sent as one Unicode string on key code 0 (no physical key).

A detector can compare `event.key`, `event.code`, `event.keyCode` and the inserted text. Normal letters are consistent; accented characters on layouts that need dead keys, emoji and some symbols can produce combinations no physical keyboard can produce.

On the VM the problem is different: `helper.py` temporarily maps a spare X keycode to characters that have no key, and changes the X keyboard mapping. The page can see a `code` that is an arbitrary spare key, and X clients can see the keymap changing.

Evidence: `Sources/apprentice/Input.swift:118-137` and `:151-158`; `agent/vm/helper.py:388-405` (`keycode_for` remaps spare keycodes) and `:449-465` (`char` press/release).

### P3. Shift is a flag on the letter event, not a real Shift key press — Low–Medium

On macOS, `typeChar` sets `.maskShift` on the letter event; it does not post a separate Shift keydown/keyup. JavaScript sees `shiftKey: true`, but a listener that tracks `Shift` keydown/keyup itself sees no modifier key. The VM helper does press and release `Shift_L`, so a Mac session and a VM session have different modifier-event streams.

This is a weak signal on its own, but it is another place where the event stream is not exactly what a keyboard produces.

Evidence: `Sources/apprentice/Input.swift:127-136`; `agent/vm/helper.py:449-461`.

### P4. Mouse paths are synthetic and statistically identifiable — High

`Mouse.move` is a cubic Bézier with control points at 0.3 and 0.7 of the line, one of five shape families, one of three speed profiles, a one-sided bend, 0.3–0.8 px jitter, and about 120 samples per second. Duration comes from a Fitts’ law formula, clamped to `move_ms`. Moves over 120 px are split into a reach that stops short or overshoots, then a correction. Every move ends on the target, then `settle` makes 1–3 micro-moves before the click.

Research already cited in `SPEC.md` reports that a single trajectory is often enough for mouse-biometric classifiers (BeCAPTCHA-Mouse, 93%), and that combining mouse and web logs catches bots that evade either signal alone. The variation in the code raises the cost but does not remove the class of signal: the kinematics are generated from a small, fixed family of curves, not recorded from a hand.

Two additional artifacts make this easier:

- The default `move_ms` cap is 200 ms, and the Fitts estimate exceeds it for long moves, so every long move in the default profile lasts exactly the cap. That truncation is visible in a duration histogram.
- Short moves (<120 px) are a single smooth stroke with no correction, while long moves have the same two-phase shape. A classifier can use the distance-dependent change in path structure.

Evidence: `Sources/apprentice/Input.swift:240-243` (landing), `:247` (hand), `:252-284` (move and overshoot), `:307-348` (stroke shapes and samples), `:359-368` (settle); `Sources/apprentice/Config.swift:68-69`, `:90`.

### P5. Per-daemon “hand” changes the motor signature — Medium–High over long observation

`Mouse.hand` is drawn once when the daemon starts: speed 0.85–1.2× and a favoured bend side. A daemon restart (update, `stop`, crash, a new VM) draws a different hand. A real person’s motor signature is stable for months; an account whose pointer suddenly changes speed and bend direction, then changes again after an update, looks like different operators or a synthetic source.

The same applies to the global `Rand` sequence: every daemon start changes all timing draws, so the whole “person” shifts at once.

Evidence: `Sources/apprentice/Input.swift:247`; `Sources/apprentice/Rand.swift:35`.

Mitigation direction: persist the hand (and preferably a small set of timing parameters) per account or per site in `~/.apprentice`, and reuse it across daemon restarts.

### P6. Click geometry and timing are narrow — Low–Medium

Clicks land at a Gaussian point around the centre of the element, with sigma about 0.12–0.18 of its width, clipped to 8% from the edge. The button is held 60–140 ms; a double-click has a 70–130 ms gap. The click always follows a settle and a stop; there is no click during motion and no miss-and-retry. Over many clicks, the distribution is more regular than a hand’s.

This is unlikely to flag a session by itself, but it adds to a behavioural score.

Evidence: `Sources/apprentice/Input.swift:240-243`, `:359-368`, `:418-430`.

### P7. Drag is linear, constant-speed and jitter-free — High for drag challenges

`Mouse.drag` is the weakest pointer primitive:

- button down, then a fixed 120 ms pause;
- `steps = distance / 6`, each step a fixed 12 ms sleep;
- straight linear interpolation from start to end;
- no curve, no tremor, no acceleration/deceleration, no intermediate pause;
- button up after another 120 ms.

Human drags accelerate, decelerate, wobble and sometimes pause. Any challenge that watches a drag (slider captchas, canvas drawing, drag-and-drop, signature pads) can separate this easily. It is also inconsistent with the effort put into `Mouse.move`.

Evidence: `Sources/apprentice/Input.swift:391-416`.

Mitigation direction: reuse the stroke generator for drags, with easing and jitter, and vary the hold/pause around the drag.

### P8. Wheel events use line units and can arrive in bursts — Medium

`Wheel.notch` posts scroll-wheel events in `.line` units, 1–3 lines per event, about 18–110 ms apart inside a flick and 120–450 ms between flicks. There is no momentum phase, no precise-delta flag and no trackpad phase. On a Mac whose account normally uses a trackpad, the page sees a mouse wheel’s `deltaMode`/`deltaY` pattern instead of trackpad scrolling.

In the VM, `helper.py` turns each notch into an X button 4/5 press+release with no delay; a flick of three notches arrives as a burst of several wheel events with essentially the same timestamp.

Evidence: `Sources/apprentice/Fidget.swift:9-37`; `agent/vm/helper.py:424-428`.

### P9. Focus is raised programmatically, not by a click — Medium

Before acting, `gate` and `Borrow.run` bring the app/window forward with AX attributes and `kAXRaiseAction`; `locate` (after a daemon restart) and `makeNewWindow` call `NSRunningApplication.activate()`. The page can observe `focus`/`visibilitychange` events with no preceding pointerdown or keydown inside the page, followed shortly by synthetic input.

Real users also switch apps with cmd-tab, so this is not conclusive. It becomes stronger when it happens repeatedly before each action, especially while the cursor is already inside the window.

Evidence: `Sources/apprentice/Commands.swift:233-239` (`gate`), `:510-535` (`attach`), `:96-98` (`makeNewWindow`); `Sources/apprentice/Input.swift:492-516`; `Sources/apprentice/Reader.swift:147-153` (`Target.raise`), `:176-185` (`locate`).

### P10. Navigation is URL-bar-only — Medium–High server-side

`open` always does: `cmd+l`, `cmd+a`, paste the URL, `forwarddelete`, `return`. The site sees a top-level navigation with no in-site link click and usually no referrer that proves the user came from the previous page. Every page reached this way is a “direct” visit.

The tool has `click` and can click links by id, and the agent docs recommend in-site links, but nothing enforces or prefers it. `SPEC.md` itself calls this “agent guidance only.” Deep linking is a known signal on LinkedIn and other social sites.

Evidence: `Sources/apprentice/Commands.swift:537-574`; `Sources/apprentice/Input.swift:202-221` (paste).

### P11. Form entry is click-select-type, never Tab — Low–Medium

`typeInto` clicks the field, waits 100 ms, verifies focus through AX, sends `cmd+a` only when the field already has text, types, and optionally presses Return 100 ms later. Every field is clicked; Tab is never used. `cmd+a` immediately before typing is a common automation tell, though the code avoids it on empty fields.

Evidence: `Sources/apprentice/Commands.swift:653-703`.

### P12. Typing bypasses IME composition — Medium for CJK locales

`keyboardSetUnicodeString` inserts text directly. For languages where users normally type through an IME (Japanese, Chinese, Korean), the page sees direct insertions with no `compositionstart`/`compositionupdate`/`compositionend` sequence. If `navigator.languages` says `ja-JP` but typing looks like a paste, that is a locale/behaviour mismatch.

Evidence: `Sources/apprentice/Input.swift:118-137`.

### P13. No reaction time before the first movement — Low–Medium

`Mouse.move` starts immediately from the current cursor position. The delay before it comes from the gate/window raise (0.25–0.6 s) or an explicit 150–400 ms pause in `scroll`/`browse`; there is no human reaction-time distribution after a page or element appears. A page can measure the time from an element becoming visible or focused to the first pointer movement, and a run that is consistently at the fast end is a signal.

Evidence: `Sources/apprentice/Input.swift:252-284`; `Sources/apprentice/Commands.swift:872-908`.

### P14. Pointer sits perfectly still by default — Low

`fidget` and `browse` are 0 by default; `Mouse.linger` only drifts during a `dwell_s`, and the default `dwell_s` is 0. Between commands the cursor can sit at exactly the same pixel for a long time. Real users leave the mouse still too, so this is weak; over long sessions, the absence of any idle micro-motion is a small tell.

Evidence: `Sources/apprentice/Config.swift:92-94`; `Sources/apprentice/Input.swift:372-380`.

### P15. Forced accessibility is browser-observable, but not a standard page API — Medium at browser level

On macOS, `enableWebAccessibility` sets `AXManualAccessibility` and `AXEnhancedUserInterface` on the app. In the VM, Chromium runs with `--force-renderer-accessibility` and `ACCESSIBILITY_ENABLED=1`. A page has no standard API to ask whether an assistive client is attached, so this is not a direct JavaScript flag. But the browser and native apps can know, and forced accessibility changes rendering/performance in ways a sophisticated detector may infer. It is also not how a normal user’s browser runs all the time.

Evidence: `Sources/apprentice/AX.swift:125-128`; `agent/vm/session.sh:30`.

### P16. Characters with no key are posted on the “a” key — Medium

`Keys.keyFor` falls back to keycode `0` for any character the current layout cannot type, and `0` is the `a` key on every layout. `typeChar` then posts that virtual key with the real character supplied as a Unicode string. A page therefore sees an impossible pair — `key: "€"` (or an emoji, or CJK on a Latin layout) arriving with `code: "KeyA"` and the keycode for `a` — while the text itself is correct, so nothing looks broken from the outside. Accented characters reached through `shifted` are fine; this is only the characters with no key at all.

Evidence: `Sources/apprentice/Input.swift:34` (keycode table), `:118-137` (`typeChar`), `:151-158` (`keyFor` fallback to `(0, false)`).

Severity Medium. Fix: type only what the layout can produce, use a dead-key/composition path for accents and IME scripts (P12), or fail the step instead of posting a key that does not exist for the character (priority fix 4).

### P17. One tab, a history that only grows, no back and no reload — Medium

`open` navigates in the current tab: `cmd+l`, `cmd+a`, paste, return in the address bar. There is no new-tab command anywhere in the code, no `cmd+[`/back and no reload; the only other window path is `--new-window`, which presses `cmd+n`. So across a day of work `history.length` climbs monotonically, `PerformanceNavigationTiming.type` is always `navigate` (never `back_forward` or `reload`), and `document.referrer` is always empty. People accumulate tabs, go back, reload after a failed load, and return through history; none of that ever happens here.

Evidence: `Sources/apprentice/Commands.swift:559-575` (`open`), `:96-108` (`makeNewWindow`, `cmd+n`), `:453` (`--new-window` only).

Severity Medium. Fix: a new tab for a new site (`cmd+t`), the back button for a return within a site, and the occasional reload (priority fix 15).

### P18. The page is never hidden and the window never loses the front — Medium–High

Every action raises the session window before acting, and nothing ever backgrounds the browser during a run: no `hide()`, no second tab, no other window. For the length of a run the page therefore sees `document.visibilityState === "visible"` and `document.hasFocus() === true` with no `visibilitychange` and no `blur` — for hours. Switching tabs, checking a message and coming back is one of the cheapest behavioural checks a site can run, and apprentice produces it never.

Evidence: `Sources/apprentice/Input.swift:504-505` (`t.raise()` before every body), `Sources/apprentice/Commands.swift:237-241` (`gate` raises first); no `hide()`/`orderOut` for a browser window anywhere (`Ask.swift` panels only).

Severity Medium–High. Fix: leave the page now and then (a second tab and back), and do not raise a window that is already frontmost (priority fix 15).

---

## 2. What a server can infer

These are patterns the site’s backend sees even if the page’s JavaScript collects nothing.

### S1. Default cadence is fast and has no read-before-act — High

The built-in default (`fast`) has:

- `between_actions_ms = [0, 0]` — no pause between actions;
- `dwell_s = [0, 0]` — no time on the page before a budgeted action;
- `burst = [0, 0]`, `rest_s = [20, 90]` — no burst/rest model;
- `fidget = 0`, `browse = 0` — no idle gestures or feed reading;
- `move_ms = [50, 200]` — fast pointer;
- `actions_per_min = 30` — up to 30 web actions per host per minute;
- `key_error_rate = 0` — perfect typing unless a profile adds it.

Only the `careful`/`steady` styles and the per-site profiles change this. The example config assigns `careful` only to `linkedin.com`, `x.com` and `reddit.com`; Instagram, Facebook, TikTok and everything else stay on `fast` unless the user edits the file. A like or follow can therefore happen immediately after a page loads, and different kinds can follow each other within seconds; the per-kind `min_gap_s` only spaces out repeats of the same recognized kind. On a site where the labels are not recognized (S2), even repeats of the same action can be quick.

This is the single most likely cause of an avoidable restriction on a social site that has not been configured.

Evidence: `Sources/apprentice/Config.swift:67-94`, `:103-130` (`preset`); `agent/config.example.toml:5-43`; `Sources/apprentice/State.swift:370-409` (`beforeAction`); `Sources/apprentice/SiteRules.swift:76-82` (`dwell`).

### S2. Budget and dwell classification is English-label-only — High on non-English sites

`Budgets.kind` scans the element’s label and name for English words: `like`, `follow`, `comment`, `repost`, `connect`, `post`, etc. `Gate.warnings` has a similar English list. A German “Gefällt mir”, a Japanese “いいね”, an icon-only heart with no accessible name, or a custom label such as “Appreciate” is not classified. The click is still gated, but it may not get a per-kind budget and does not get the `dwell_s` that budgeted actions get.

On a non-English site this can turn into a high-velocity like/follow run with no dwell, which is exactly the pattern the budgets were meant to prevent.

Evidence: `Sources/apprentice/SiteRules.swift:135-149` (`Budgets.words` and `kind`), `:157-182` (`check`), `:208-238` (`count`); `Sources/apprentice/State.swift:414-419` (`Gate.words`).

### S3. Soft-block and challenge detection is English-biased and narrow — Medium–High

`Site.inspect` looks only at elements that are new since the last snapshot, outside text fields, and matches a list of English phrases. A localized throttling message, a banner that replaces existing text, or a soft block inside an existing element is missed. The tool then keeps acting, and the site escalates from a soft rate limit to a harder one.

Challenges are slightly better: `Challenge.find` also matches language-independent URL paths (`/challenge`, `/checkpoint`, `/captcha`, …) and scans the title plus every short element name, not only new ones. But the text markers are English, so a localized in-page challenge with no matching path or title marker is still missed.

What happens on a match is set by `[sites] on_soft_block` and `on_challenge` (`stop` by default, or `warn` or `off`); a user who picks `warn` or `off` widens the gap.

This is not a detection signal itself; it is a detection-response gap that makes the next detection worse.

Evidence: `Sources/apprentice/SiteRules.swift:50-63` (`Site.inspect`), `:361-372` (`Challenge.paths` and `find`); `Sources/apprentice/Config.swift:247-251` (`softBlockPhrases`), `:254` (`onSoftBlock`), `:268-272` (`challengeMarkers`).

### S4. No active-hours, session-length or long-break model — Medium

There is no notion of “this account is normally active 09:00–18:00”, no maximum session length, and no long break beyond the in-burst `rest_s` (and that only when a profile sets `burst`). An agent can run a dense block at 03:00 local time, or right after the account was created. Server-side trust and graph models use time-of-day and session shape.

Evidence: `Sources/apprentice/State.swift:370-409`; `Sources/apprentice/Config.swift:80-87`.

### S5. Direct navigation has no link trail — Medium–High

Same as P10. A sequence of `open` calls produces a sequence of top-level navigations with no referrer and no click path. On sites where profile views, feed visits and search results normally precede a follow or a like, this is a strong server-side pattern.

### S6. VM device consistency — High for high-value accounts

A Mac session uses the user’s real Safari/Chrome, profile, cookies, extensions, GPU, fonts and screen. A VM session uses:

- a separate Chromium profile (a new device for each site the first time it is used);
- Debian Linux, `navigator.platform` Linux, Linux UA/CH headers;
- Xvfb 1280×800×24, DPR 1;
- software WebGL (SwiftShader/llvmpipe), no GPU;
- the minimal font set (`fonts-dejavu-core`, `fonts-noto-color-emoji`);
- 2 vCPUs and 2 GB by default;
- no battery, camera, microphone or audio device;
- a separate browser history.

If the account normally uses a Mac, this is a different device. The first sign-in on each site will usually look like a new device, and device-trust systems may challenge it. The project already documents this; `[vm] local = ["site.com"]` keeps the most important accounts on the Mac.

Evidence: `agent/vm/session.sh:6`, `:30-32`; `agent/vm/provision.sh` (package list and timezone); `Sources/apprentice/VM.swift`; `SPEC.md:454`.

### S7. Remote VM IP — High

A local Tart VM shares the Mac’s IP, which is good. A VM on a server elsewhere (`[vm] host`) has a datacenter IP that does not match the account’s normal location, even though the timezone and language are copied from the Mac. The project explicitly does not spoof this. Treat a remote VM as a separate device on a different network, not as the user’s Mac.

Evidence: `SPEC.md:454`; `agent/vm/provision.sh` (timezone only).

### S8. Multiple VMs share an identical fingerprint — High for multi-account

VMs built from the same image normally share the same Chromium build, the same 1280×800 screen, the same font set, the same defaults (2 CPU/2 GB), the same lack of audio, and the same timezone offset if they run on the same host. Even with different cookies, the browser fingerprints cluster. That makes cross-account correlation easier. Multi-account operation is out of scope by design, but parallel sessions per VM are a supported workflow, so the clustering is still real for one person with several accounts.

### S9. HTTP/TLS fingerprints are real, but the platform is not — Medium

The TLS and HTTP/2 fingerprints are a real Chromium, which is good. The `Sec-CH-UA` platform and UA say Linux, while the account may normally be on macOS/Safari. A server that compares the declared platform with the account’s device history sees a mismatch. This is not a bot signature by itself, but it is part of S6/S7.

### S10. No consent step, so a consent wall is left standing — Low

Nothing in the code knows what a cookie/consent banner is: the only page-state checks are challenges and soft-block phrases. A banner is dismissed only if the agent happens to target it; otherwise it stays up for the whole session while the bot acts around it, or is hit blind on the first snapshot with no read time. A site that keys on consent state sees a returning visitor who never accepts, or who accepts without ever looking, which does not match the account’s earlier human sessions.

Evidence: `Sources/apprentice/SiteRules.swift:50-67` (challenge and soft-block checks, nothing else); no `consent`/`cookie`/`gdpr` handling in `Sources/apprentice/`.

Severity Low, confidence likely. Fix: treat a consent wall as a first-class step with its own dwell, and let the user set the preference once per site.

---

## 3. What a native app or the OS can see

This is the part the page cannot see and the part `SPEC.md` under-states. A native app receives an `NSEvent` for events in its own window; it can call `event.cgEvent` and read the same fields apprentice’s own monitors read. Any process with Input Monitoring/Accessibility can also install a CGEvent tap.

### A1. The constant event tag — Critical

`Keys.tag` is `0x646B6374` (ASCII `dkct`). `Keys.post` sets it on **every** event as `eventSourceUserData`, then posts at `.cghidEventTap`:

```swift
static let tag: Int64 = 0x646B_6374
...
e.setIntegerValueField(.eventSourceUserData, value: tag)
...
e.post(tap: .cghidEventTap)
```

A native app can read it from its own `NSEvent`, or from a tap, exactly as apprentice does in `Borrow.watchHuman` and `Watch`:

```swift
if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Keys.tag { ... }
```

The value is constant across installs, so a detector can hardcode it. Real hardware events have `eventSourceUserData == 0`.

Evidence: `Sources/apprentice/Input.swift:224-232`, `:461-468` (`watchHuman`), `:501`, `:528` (`Watch`); `Sources/apprentice/Remote.swift` does not set the tag in the guest, so a VM session does not have this exact tag (it has the XTest/provenance issues below instead).

### A2. Synthetic event provenance — High

Even if the tag is removed, the rest of the CGEvent tells a native app that the event did not come from hardware. A one-off probe on macOS 14 created a `mouseMoved` event with `CGEvent(mouseEventSource: nil, ...)`, set the tag, and posted it at `.cghidEventTap`; a listen-only `.cgSessionEventTap` observed:

| Field | Synthetic (apprentice-style) | Hardware |
| --- | --- | --- |
| `eventSourceUserData` | `0x646B6374` | `0` |
| `eventSourceUnixProcessID` | the posting process PID | `0` |
| `eventSourceStateID` | `0` (private) | `1` (combined session) |
| `mouseEventDeltaX/Y` | `0, 0` | non-zero |
| timestamp | assigned by the system on post | assigned by the system |

The timestamp is **not** a tell: the event object starts with timestamp 0, but the system assigns one when it is posted, and the tap saw a real timestamp. The posting PID, private source state and zero deltas are the tells.

A native app does not need a global tap to see this for events delivered to its own window: it gets the `NSEvent` and can inspect `cgEvent`. The practical conclusion is that **on macOS, input injected with CGEvent is distinguishable from hardware by any app that cares.** Removing the tag removes an easy constant, not the provenance.

Evidence: `Sources/apprentice/Input.swift:227-232` (creation with `nil` source and posting); probe described above (not part of the repo).

### A3. Accessibility attributes forced on the app — High

`enableWebAccessibility` sets `AXManualAccessibility` and `AXEnhancedUserInterface` to true. It is called on attach and when a window has to be found. A native app can read its own AX attributes, and Chrome/WebKit know accessibility is on. `--force-renderer-accessibility` keeps the renderer’s accessibility tree on permanently in the VM.

For a browser this is necessary to read the page. For a native app it is often unnecessary, and it is a state a normal user’s app does not sit in. Restricting the call to browser sessions/web areas would remove an app-level signal.

Evidence: `Sources/apprentice/AX.swift:125-128`; `Sources/apprentice/Commands.swift:512`, `Sources/apprentice/Reader.swift:183` (call sites); `agent/vm/session.sh:30`.

### A4. Process and bundle footprint — High for adversarial apps

A daemon named `apprentice` is running, with a menu-bar item, a unix socket at `~/.apprentice/sock`, state files under `~/.apprentice/`, and a CLI binary in `~/.local/bin`. A non-sandboxed native app can enumerate running applications (`NSWorkspace.runningApplications`), inspect `ps`, or look for the socket/files. Anti-cheat, banking and some enterprise apps do this. A sandboxed app sees less, but the process list is still visible.

This is not a page signal and not something to hide; it is part of the tool’s footprint.

### A5. Accessibility query pattern — Low–Medium

The reader walks up to 40,000 nodes at depth 90 per snapshot and re-reads after actions. A native app with its own accessibility provider can measure query volume and timing: a client that enumerates the whole tree every few seconds is not a typical screen reader. This is niche, but real for apps that instrument their AX server.

Evidence: `Sources/apprentice/Reader.swift:115` (`visited < 40000`), `:113-143` (walker), `:212-229` (snapshot cache).

### A6. Window activation and event timing — Medium

Native apps receive `applicationDidBecomeActive`, `windowDidBecomeKey`, and the event stream. Programmatic activation without a click, followed by a burst of synthetic events, is visible in the same way as P9. macOS also gives the app the event timestamp and the event’s position, so it can measure the same path/timing signals as a web page.

### A7. Screen capture and protected windows — Low

`Capture` uses ScreenCaptureKit with `showsCursor = false`. A protected or DRM window can blank or refuse capture; that is a limitation, not a detection channel. The macOS screen-recording indicator is user-visible, not app-visible. Do not treat capture as stealthy; it is a user-visible permission.

Evidence: `Sources/apprentice/Capture.swift:55-76`.

### A8. VM/X11 artifacts — Medium for guest apps

Inside the VM, a native app can see `Xvfb`, `openbox`, `x11vnc`, `chromium --force-renderer-accessibility`, and the helper process; it can query the XTEST extension; it can observe keymap changes for characters with no key. XTest events are generally indistinguishable from hardware to X clients, but the environment is not. A web page does not see the process list; a guest app does.

Evidence: `agent/vm/session.sh`; `agent/vm/helper.py:388-405`.

### A9. Clipboard writes outside pages — Low

`Keys.paste` is used in the address bar and system file dialogs, not inside web pages. A native app with a pasteboard monitor can see the clipboard being written and restored, but that is an OS-level observation, not a page one.

Evidence: `Sources/apprentice/Input.swift:202-221`; `Sources/apprentice/Commands.swift:555` (`open`), `:1015-1020` (`choose`).

### A10. Power assertions are in the global system state — Low–Medium

With keep-awake on, `Awake` creates two IOPM assertions named `apprentice: a task is running` and holds them for the task plus a 120 s grace. `pmset -g assertions` shows the name and the owning process to any local user, no privileges needed. It also means the display never sleeps and the screen never locks during a three-hour session — which is not what a person at a keyboard looks like, and is the one part of the footprint that is a *behavioural* tell rather than a process one.

Evidence: `Sources/apprentice/Awake.swift:35-43` (`IOPMAssertionCreateWithName`, both display and system sleep), `:14` (`grace = 120`).

Severity Low–Medium. Fix: keep the assertion but name it plainly and shorten the grace period; do not describe keep-awake as invisible.

### A11. Notifications are posted by `osascript` — Low

`SiteRules.notify` shells out to `/usr/bin/osascript` with `display notification … sound name "Ping"`. The notification is therefore attributed to the scripting host rather than to apprentice, and every call spawns a short-lived `osascript` process that a process list or an `NSWorkspace` observer can see. It is a small thing, but it is the same “a script is driving this Mac” story as A1.

Evidence: `Sources/apprentice/SiteRules.swift:64-72`.

Severity Low. Fix: post through `UNUserNotificationCenter` with apprentice’s own bundle, so the notification looks like the app it is.

### A12. Screen Recording permission and the capture indicator — Low

`Capture.ensure` preflights and requests Screen Recording, and every `--image`/`--crop` snapshot runs a ScreenCaptureKit capture with `showsCursor = false`. macOS lists apprentice under Privacy & Security → Screen & System Audio Recording and shows its capture indicator while an image is taken. A process that can read the screen, drive the pointer and hold power assertions is the shape of a remote-control tool, which is a fair description of what this is.

Evidence: `Sources/apprentice/Capture.swift:12-19` (permission), `:55-71` (`SCScreenshotManager`, `showsCursor = false`).

Severity Low; accepted, it is the user’s own screen. Fix: none, but keep captures window-scoped and short, and say so in the docs.

---

## 4. VM-specific page signals

These are in addition to S6–S8.

### V1. Software rendering and missing hardware — High

Xvfb has no GPU. WebGL likely reports SwiftShader/llvmpipe; WebGPU may have no adapter or a software adapter; canvas and audio fingerprints differ from a Mac; `navigator.hardwareConcurrency` is 2; `devicePixelRatio` is 1; the screen is 1280×800; there is no battery, camera, microphone or audio device. A fingerprinting script does not need a bot flag to see that this is not the user’s Mac.

### V2. Fonts and locale — Medium

The provisioner installs only `fonts-dejavu-core` and `fonts-noto-color-emoji` on top of the minimal Debian base. `document.fonts.check` for common macOS fonts fails, and canvas text metrics differ. Language is passed through `APPRENTICE_LANG`; if it is unset, it defaults to `en-US`, which may not match the account’s locale. Timezone is set to the host’s.

Evidence: `agent/vm/provision.sh` (font packages); `agent/vm/session.sh:28-32`.

### V3. Fixed geometry — Medium

The VM browser is launched at `--window-position=0,0 --window-size=1280,800` on a 1280×800 screen. A real Mac browser is often on a Retina display with DPR 2, a different screen size, and a window that is not exactly the full virtual screen. `screen.width/height`, `outerWidth/height`, `devicePixelRatio` and `visualViewport` all record the difference.

Evidence: `agent/vm/session.sh:6`, `:30-32`.

### V4. Replayed input timing — Medium (likely)

`Remote.send` writes each event line to the ssh pipe after the host’s `Pace.sleep`; `helper.py` reads lines and plays them as they arrive. On a local Tart VM this is usually fine. On a remote VM, ssh/TCP buffering can deliver several lines in one read, and the helper then plays them back-to-back. The page sees compressed event timestamps and a burst that does not match the host’s pacing. The same applies to wheel notches, which the helper plays in a tight loop.

Evidence: `Sources/apprentice/Remote.swift:144-149` (`send`), `:176-270` (`post`, `press`, `typeChar`, `act`); `agent/vm/helper.py:418-464` (`play`).

Mitigation direction: include the intended timestamp in each input op and have the helper sleep until it, rather than replaying on arrival. Batch wheel notches with their own delays.

### V5. Keyboard mapping mutation — Medium for non-US layouts

`keycode_for` changes the X keyboard mapping to a spare keycode for any character without a key. X clients see the keymap change, and the page sees an unusual `code`. On a multi-language account this is both a detection signal and a correctness risk.

Evidence: `agent/vm/helper.py:388-405`.

### V6. Identical fingerprint across VMs — High for multi-account

VMs from the same image normally share the same Chromium build, fonts, screen, CPU/memory defaults, timezone offset and lack of hardware. Even if each VM has its own profile, the browser fingerprint is the same class. This is the easiest way to link accounts that are supposed to be separate.

### V7. WebRTC and network mismatch — Medium

A remote VM’s WebRTC candidates and latency reflect the server network, not the user’s Mac, while the timezone and language say the Mac. A page or server can compare. The project does not spoof this.

### V8. Headful Chromium under Xvfb is not headless Chrome — Low

The VM is not `--headless`, so the usual `HeadlessChrome` UA, missing `window.chrome`, zero `outerWidth` checks do not fire. The VM looks like a headful Linux Chromium, which is better than headless but still a different device. Do not assume “not headless” means “not detectable.”

### V9. The guest session file and a global environment marker — Medium for guest apps

`session.sh` writes the session D-Bus address to `/tmp/apprentice-session.env` with the service’s default umask, so any process in the guest can read it and join the accessibility bus. `provision.sh` then appends `DISPLAY=:0` and `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` to `/etc/environment`. A page sees neither; a guest-native app sees that its screen is virtual and that accessibility is being forced on for it.

Evidence: `agent/vm/session.sh:22-24`; `agent/vm/provision.sh:68-69`.

Severity Medium for guest apps, Low for pages. Fix: `install -m 600` (or put the file under `$HOME`), and keep tool-specific variable names out of `/etc/environment`.

### V10. The only input devices are the XTEST fakes — Medium, accepted

Xvfb starts with no pointer or keyboard hardware, so the X server’s device list holds only the virtual core XTEST devices, and `XTestQueryExtension` answers. Any X client can see that every event in the session comes from XTEST. This is upstream of P2 and P8 and is the VM’s version of A2: it cannot be removed without a real device.

Evidence: `agent/vm/session.sh:6` (Xvfb with no input device); `agent/vm/helper.py:418` (`fake` → `xtest.fake_input`).

Severity Medium; **accepted** as device identity. Fix: none. Do not describe VM input as indistinguishable from a physical keyboard.

### V11. Accessibility is forced at the bus, and launched apps inherit the helper’s environment — Low–Medium

`session.sh` sets `org.a11y.Status IsEnabled = true` on the session bus before Chromium starts, so every app on that bus is told a reader is present. `helper.py` sets `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` in its own environment and `launch` starts apps with that environment inherited, so an app started from a session can read the variable and, on the bus, see a client that is not a screen reader.

Evidence: `agent/vm/session.sh:16-20`; `agent/vm/helper.py:36`; `agent/vm/helper.py:483` (`launch` inherits the environment).

Severity Low–Medium. Fix: launch apps with a clean environment, and force accessibility for Chromium only rather than for the whole session bus.

---

## 5. Detection-response gaps

These do not create a signal, but they make a site’s first soft signal turn into a harder one.

### D1. English-only soft-block/challenge lists — Medium–High

`softBlockPhrases` and the `challengeMarkers` text are English. On a localized site, a “try again later” banner in the site’s language is not recognized; a localized challenge is only recognized if its URL or title happens to match one of the built-in paths/markers. The tool keeps acting, and the site applies a longer restriction.

Evidence: `Sources/apprentice/Config.swift:247-251`, `:268-272` (lists), `:355-356` (config overrides); `Sources/apprentice/SiteRules.swift:50-63` (`Site.inspect`), `:361-372` (`Challenge.paths` and `find`).

### D2. Only new elements are inspected — Medium

`Site.inspect` (the soft-block path) compares element keys against the previous snapshot and only checks elements that are new, and only when the URL did not change. A banner that replaces existing text, a message inside an element that was already present, or a soft block shown after a navigation is missed. `Challenge.find` is broader (URL paths, title, every short element name) but its text markers are still English.

Evidence: `Sources/apprentice/SiteRules.swift:53-55`.

### D3. Dwell is tied to URL changes and budgeted kinds — Medium

`Site.dwell` measures time since `pageAt`, which is set when `Session.track` sees a URL change. An SPA route that does not update the AX URL, or an action that is not classified as budgeted, can happen without a dwell. The default profile has no dwell at all.

Evidence: `Sources/apprentice/State.swift:212-217` (`track`), `:333-335` (`notePage`); `Sources/apprentice/SiteRules.swift:74-82` (`dwell`).

### D4. `actions_per_min` is per host, not per account — Low–Medium

`Limits.beforeAction` counts actions per host. `Site.domain` normalizes common prefixes and `twitter.com`/`x.com`, but other subdomains or aliases (`business.facebook.com`, country domains) can have separate counters. A site can see the aggregate.

Evidence: `Sources/apprentice/State.swift:370-409`; `Sources/apprentice/SiteRules.swift:10-16` (`Site.domain`).

### D5. No cap on uncategorized gated clicks — Medium

A click whose label/name does not match a budget word and does not trigger a Gate warning is classified as `nil`; it is still gated and may count as `default` only if `gated` is true. Budgets come only from `budgets.json`: the example file's `default` cap is 120/hour and 500/day, which is generous, and with no file there is no cap at all. On a site where “Appreciate”, “Boost” or an icon-only button is the real like, this bypasses the like budget and the dwell.

Evidence: `Sources/apprentice/Commands.swift:233-239`; `Sources/apprentice/SiteRules.swift:101-131` (`table`, `cap`), `:145-149` (`kind`), `:157-182`, `:208-238`; `agent/budgets.example.json`.

### D6. No time-of-day or session-length model — Medium

Same as S4. A site can see a dense block at an unusual hour or a session that never pauses for more than `rest_s`.

---

## 6. What is already safe, and should stay that way

These are genuine advantages; do not “improve” them into spoofing.

- **No WebDriver, CDP or injected script.** `navigator.webdriver` is false. There is no remote-debugging port, no extension, no page script. This avoids the largest browser-automation fingerprint family.
- **Trusted events.** Every event goes through `.cghidEventTap` on the Mac, so `event.isTrusted` is true and the browser generates the full pointer sequence. In the VM, XTest injects at the X server, so X clients see normal core events.
- **Real browser profile on the Mac.** The session uses the user’s normal Safari/Chrome with their cookies, extensions, history and logins. That is the strongest defence on this Mac.
- **Real keycodes for normal text.** Keys come from the current layout, with Shift for capitals; normal prose produces the right `key`/`code`/`shiftKey`. The exceptions are P2/P3.
- **Paste stays out of pages.** The clipboard is used only in the address bar and system dialogs.
- **Accessibility reads have no standard page API.** A page cannot ask whether the AX tree is attached. The exception is A3 at the app/browser level.
- **The event tag is not exposed to pages.** A page cannot read `eventSourceUserData`; a native app can (A1).
- **Budgets, cooldowns, challenges, navigation gaps and the reload cap.** They are real controls when configured. The problem is defaults and classification, not the mechanism.
- **Manual CAPTCHA only.** The tool stops and asks the user; it never solves a challenge. That is both an ethical boundary and a detection boundary.
- **Randomness from one seeded generator.** No fixed coordinates or fixed delays across installs; the variation is real, even if the curve family is small.
- **One session, one account, one window.** The intended use is one person with their own accounts, which is the best behavioural disguise there is.

---

## 7. Priority fixes

Ordered by expected reduction in detection risk per unit of work. These are suggestions, not applied changes.

1. **Remove the constant tag and rely on provenance filtering where possible.** Stop writing `0x646B6374` into every event. If monitors need to ignore apprentice’s own events, compare `eventSourceUnixProcessID` to the daemon PID or use a per-run random value (still non-zero, still visible, but not a hardcoded signature). Accept that A2 remains: native apps can still see synthetic provenance. Do not claim otherwise in docs.
2. **Make the default web profile `steady`, not `fast`.** Set non-zero `between_actions_ms`, a small `dwell_s`, and `fidget`/`browse` for web sessions unless the user opts out. Keep `fast` for native apps. Add an explicit “social profile” that covers Instagram, Facebook and TikTok, not just LinkedIn/X/Reddit.
3. **Persist the hand and timing profile per account.** Save `Mouse.hand` (speed, side) and a small set of typing parameters in `~/.apprentice` so a daemon restart does not change the “person”. Reuse it across VM and Mac sessions for the same account if appropriate.
4. **Improve keystroke dynamics.** Per-key hold distributions, overlapping keydown/keyup, per-digraph gaps, and a real IME/composition path for CJK. Disable `--pace fast` on web pages.
5. **Improve drag.** Reuse the stroke generator with easing, jitter and a variable hold; do not use a linear constant-speed drag.
6. **Add reaction time and reduce the default `moveMax` plateau.** Draw a reaction delay before the first movement after a focus/page change, and make the duration distribution not truncate at exactly 200 ms for every long move.
7. **Make budget/dwell classification label-independent.** Use ARIA roles/names, icon alt text, a configurable synonym list per locale, and a fallback that treats any gated control as budgeted. Do not rely on English words.
8. **Make soft-block/challenge detection robust.** Scan all visible text, not only new elements; support localization; support a user-supplied phrase list; and stop on an in-place banner.
9. **Prefer in-site links.** Add a first-class “click this link” guidance/flow and use `open` only for the first entry or a deliberate deep link. Preserve a real referrer where the site expects one.
10. **Restrict `enableWebAccessibility` to browsers/web areas.** Do not set `AXManualAccessibility`/`AXEnhancedUserInterface` on native apps that do not need a web area.
11. **Add active-hours and session-length controls.** A quiet-hours window, a maximum session length, a long break after N actions, and a daily cap below the budget caps. Make them defaults for social sites.
12. **Treat the VM as a separate device in the docs and in `doctor`.** Keep high-value accounts on the Mac (`[vm] local`). Add a `doctor` check that warns when a Linux VM is used for an account whose other sessions are macOS, and when `APPRENTICE_LANG` is unset. Do not add fingerprint spoofing.
13. **Fix VM input timing.** Send target timestamps with input ops and have the helper sleep until them; batch wheel notches with delays; preserve/restore the keyboard mapping after a temporary keycode.
14. **Build a canary page.** Add a local HTML page (or a `doctor --fingerprint` command) that prints `navigator.webdriver`, UA/CH, platform, languages, screen/DPR, hardware, WebGL/WebGPU, canvas/audio hashes, focus events, and the timing/overlap of pointer, key and wheel events. Run it in a Mac session and a VM session and compare before/after changes. This is the only way to know which of the “likely” items above are real in the current browser build.
15. **Vary the foreground and the tab.** Open a second tab now and then and come back; leave the page rather than sitting on it; do not raise a window that is already frontmost; reload occasionally (P17/P18).
16. **Tidy the guest environment and give the app its own identity.** `chmod 600` the session env file, keep tool-specific variables out of `/etc/environment`, launch guest apps with a clean environment, and post notifications through `UNUserNotificationCenter` (A11, V9, V11).

---

## 8. Signal matrix

| Signal | Page JS | Server | Native app | Notes |
| --- | --- | --- | --- | --- |
| `eventSourceUserData = 0x646B6374` | no | no | **yes** | A1; readable from `NSEvent.cgEvent` |
| Posting PID / private source state / zero deltas | no | no | **yes** | A2; confirmed by probe |
| `AXManualAccessibility` / `AXEnhancedUserInterface` | no (no API) | no | **yes** | A3; browser internals too |
| Process named `apprentice` | no | no | **yes** | A4; `NSWorkspace`, `ps`, socket |
| Keystroke hold/gap/rollover | **yes** | maybe | yes | P1; typing biometrics |
| Key/code mismatch for exotic characters | **yes** | no | yes | P2; locale-dependent |
| Shift flag without Shift key event | **yes** | no | yes | P3 |
| Mouse path shape, Fitts, 120 Hz, cap | **yes** | maybe | yes | P4 |
| Per-daemon hand change | **yes** | maybe | yes | P5; long-term biometrics |
| Click geometry/hold | **yes** | maybe | yes | P6 |
| Linear drag | **yes** | maybe | yes | P7; drag challenges |
| Wheel line units / bursts | **yes** | maybe | yes | P8, V4 |
| Focus without in-page click | **yes** | no | yes | P9, A6 |
| URL-bar navigation / no referrer | no | **yes** | no | P10, S5 |
| Default fast cadence / no dwell | **yes** | **yes** | yes | S1 |
| English-only budgets | **yes** | **yes** | yes | S2 |
| English-only soft-block detection | no | **yes** | no | D1–D2 |
| Linux/software-WebGL/1280×800 VM fingerprint | **yes** | **yes** | yes | S6, V1–V3 |
| New device / new profile in VM | no | **yes** | no | S6 |
| Multiple VMs with identical fingerprint | no | **yes** | no | S8 |
| No active-hours/session-length model | **yes** | **yes** | yes | S4 |
| Accessibility walk of 40k nodes | no | no | **yes** (AX provider) | A5 |
| Screen capture | no | no | limited | A7; DRM/protected windows |
| Character typed on keycode 0 (`code: "KeyA"`) | **yes** | no | yes | P16 |
| One tab, growing history, no back or reload | **yes** | maybe | no | P17 |
| Page never hidden, window always in front | **yes** | maybe | no | P18 |
| No consent step | no | **yes** | no | S10 |
| `pmset -g assertions` names apprentice | no | no | **yes** (local) | A10 |
| Notification posted by `osascript` | no | no | **yes** (local) | A11 |
| Screen Recording + capture indicator | no | no | limited | A12 |
| Guest env files name the rig | no | no | yes (guest app) | V9 |
| Only XTEST input devices | no | no | yes (guest X app) | V10 |
| A11y forced on the guest session bus | no | no | yes (guest app) | V11 |

---

## 9. Conclusion

On the Mac, the page-level surface is deliberately good: no WebDriver, no CDP, real profile, trusted events, real keycodes for normal text. The remaining page-level risk is behavioural: the default profile is fast and acts without reading, the typing rhythm is mechanically regular, the pointer and drag are generated from a small curve family, and navigation is URL-bar-only.

The app-level surface is the opposite: macOS makes synthetic input easy to identify, and apprentice makes it trivial with a constant tag, a posting PID, a private source state and zero mouse deltas. A native app that wants to know can know. That is not fixable by pacing, and it should not be hidden with spoofing; the right defence is to use the app as the person would and keep the highest-value accounts on the real Mac.

On the VM, the browser is real Chromium but the device is not the user’s: Linux, software WebGL, fixed 1280×800, DPR 1, few fonts, no battery/camera/audio, a new profile per site, and (for a remote VM) a datacenter IP. Treat it as a second device and keep the accounts whose standing matters most on the Mac.

The highest-value work is therefore: safer defaults (S1), label-independent budgets and detection (S2/S3/D1), persistent behavioural profiles (P5), better keystroke and drag models (P1/P7), and honest documentation of the app-level provenance limit (A1/A2). Two cheap behavioural signals sit beside those and cost almost nothing to fix: the page is never hidden and the tab set never changes (P18/P17), and the local footprint names itself in the power assertions and notifications (A10/A11). Everything else is refinement.
