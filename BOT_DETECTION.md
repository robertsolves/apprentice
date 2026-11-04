# Bot-detection audit

What a site, a server, a native app or the Linux VM can tell apart from a person using the same browser by hand, and what apprentice does about each. The aim is that Meta, Instagram, TikTok, LinkedIn, Reddit and X see the user's own account used at a person's pace, with a person's input, and no fingerprint spoofing (a non-goal: where the only fix would be to lie about the device, the item is **accepted**).

**The bar:** every check a page or a server can run on apprentice's input comes back "human" or "inconclusive", never "bot". A signal that reads as a bot is a bug, whatever its severity. The accepted items are the exceptions this bar cannot reach without spoofing: what only the OS sees (A2) and the VM being another device (S6).

- **Audited:** `6f958ba` (2026-11-02), static read of `Sources/apprentice`, `agent/vm` and the shell entry points, plus OS probes of the CGEvent fields apprentice posts.
- **Fixed:** `b4513c0` and `7313b81` (2026-11-02).
- **Measured:** `agent/canary.html` on this Mac (Chrome 156, macOS 26.2) and in the VM (Chromium); results below. Re-run it after any change to `Input.swift`, `Fidget.swift` or `agent/vm/helper.py`. The `canary-full-test` flow and `playbooks/web/canary.md` went with the packaged playbooks on 2026-11-05 (git history keeps them); the page's own panel lists the checks.

## Status at a glance

| Mark | Meaning | Items |
| --- | --- | --- |
| ✅ | Fixed and measured on the canary | P1 P2 P3 P6 P7 P16 P18 P19 · S2 · V4 |
| ☑️ | Fixed; covered by `selftest`, not measurable on a page | P4 P5 P9 P10 P13 P14 P17 P21 P22 · S1 S3 S4 S5 S12 · A1 A3 · D1 D2 D3 · V9 |
| 🔁 | Changed since the canary run: measure again | P1 P7 (per-pair typing rhythm, drag correction and settle) |
| 🔍 | Measured: not a tell, left as it is | P8 P20 |
| ⛔ | Accepted: device identity or the tool's own footprint; the fix would be spoofing | P15 · S6–S9 S11 · A2 A4 A7 A8 A12 · V1 V3 V6–V8 V10–V12 |
| ⏳ | Open, in `TODO.md` | P11 P12 · S10 · A5 A11 · V5 · P17's new tab per site |

Who can see a signal matters more than its severity: **page** (JavaScript in the site), **server** (requests, timing, account history), **native app / OS** (event and process metadata a page never sees), **VM** (the Linux guest is another device).

## Measured on the canary

Mac, Chrome, one full run (32 checks, 31 passed by apprentice; the password check passes only with the user's own `confirm`, which is the gate working):

| What the page measured | Result | Item |
| --- | --- | --- |
| `navigator.webdriver` · untrusted events | false · 0 | safe list |
| Moves whose `movementX/Y` disagree with the coordinates | 6 of 1143; 9% zero, from the settle's sub-pixel rests | P19 ✅ |
| Pointer rate · coalesced samples per event | 92–95 Hz · 1.02 | P4 |
| Key hold · flight (ms) | 94 ± 27 · 219 ± 173 | P1 ✅ |
| Overlapping keys (rollover) | 6 of 52, 15 of 87 | P1 ✅ |
| Shift keydowns · shifted keys with no Shift down | present · 0 | P3 ✅ |
| `code: "KeyA"` for another character | 0; the emoji arrived as one paste | P16 ✅ |
| Accents (é, ï, ß) | typed exactly, through dead keys (4 compositions, as a real dead key gives) | P2 ✅ |
| Wheel `deltaMode` · `deltaY` | 0 (pixels) · multiples of 40, what a notched mouse wheel gives in Chrome on macOS | P8 P20 🔍 |
| Button hold (ms) | 156 ± 28 | P6 ✅ |
| Drag path length over straight distance · speed variation | 1.033 · 0.78 | P7 ✅ |
| blur / focus after cmd+tab | seen, and back | P18 ✅ |
| A "Gefällt mir" click | budgeted as a like | S2 ✅ |

VM, Chromium: typing, the map, form controls, routes and back, popups, dialog, drag, chat and the feed all pass after the `7313b81` helper fixes (V4); its measurements have not been read yet.

## Page JavaScript

| ID | Signal | Sev. | Status and what changed |
| --- | --- | --- | --- |
| P1 | Keystroke rhythm: uniform hold, no overlap, `fast` gaps on pages | High | ✅ Holds are log-normal around the person's own hold, `--pace fast` is ignored on web pages; only a site the user lists as `fastest` (`pace <site> fastest`, meant for logged-out scouting) is pasted into, by their choice. Gaps are now timed from one key down to the next, so overlap comes from the timing itself (never on one finger or one key); see P22 for the per-pair rhythm |
| P2 | `key`/`code` disagree for accents and exotic characters | Med | ✅ Option layer and dead keys come from the layout (`Keys.sequences`); the US table is used only when the layout cannot be read |
| P3 | Shift is a flag with no Shift keydown | Low–Med | ✅ Shift, cmd, option and ctrl are `flagsChanged` keys of their own; Shift is held across a run of capitals. The VM already pressed `Shift_L` |
| P4 | Mouse paths: small curve family, every long move capped at `move_ms` max, 120 Hz | High | ☑️ Above the cap a move still grows slowly (`Mouse.duration`), the sample rate is drawn per stroke (100–135 Hz). No deliberate miss-click: a miss can click something else |
| P5 | The "hand" changes on every daemon start | Med–High | ☑️ `Hand` is drawn once and kept in `hand.json`, shared by every VM's daemon |
| P6 | Clicks: fixed hold, centre-heavy | Low–Med | ✅ Button hold is log-normal around the hand's own median |
| P7 | Linear drag | High | ✅ Already one curved stroke with a drawn shape, speed profile and hold before this audit; measured above. Since then a drag over 120 px reaches a little short of or past the drop and corrects, and every drag settles with micro-moves before the release |
| P8 | Wheel in line units, bursts | Med | 🔍 Chrome reports pixels in steps of 40, as from a mouse wheel; nothing to change on the Mac. VM notches are now spaced (V4) |
| P9 | Focus raised with no click in the page | Med | ☑️ A frontmost window is not raised again; a reaction delay follows the raise |
| P10 | Every page reached through the address bar | Med–High | ☑️ Agent docs and playbooks: arrive with `open`, then follow links and go back; `open` on the same site prints that tip |
| P11 | Click-select-type form entry, never Tab | Low–Med | ⏳ |
| P12 | No IME composition for CJK | Med for CJK | ⏳ Characters no key types are pasted (P16) |
| P13 | No reaction time before the first move | Low–Med | ☑️ A log-normal 0.1–0.9 s look before the hand moves (not in `mode = "fast"`) |
| P14 | Pointer perfectly still between actions | Low | ☑️ `steady` (web) and `careful` (social) carry fidgets and drift by default |
| P15 | Accessibility forced on the browser | Med | ⛔ The tree is how apprentice reads; scoped to web apps (A3) |
| P16 | Characters with no key posted on the "a" key | Med | ✅ Pasted on their own, clipboard restored |
| P17 | One tab, no back, no reload | Med | ☑️ `key cmd+[` / `key cmd+r` always existed; docs and playbooks now use them. ⏳ a new tab per site |
| P18 | Page never blurred | Med–High | ✅ Now and then a fidget switches to the last app with cmd+tab and back. `visibilityState` stays `visible` |
| P19 | `movementX/Y` possibly zero while the pointer moves | Med | ✅ Every move carries its deltas |
| P20 | Line-mode wheel ticks | Low–Med | 🔍 See P8 |
| P21 | The pointer rests on one pixel twice: an exact `--at` point, an exact `drag --by` offset, or a landing that repeats on a small control | Med | ☑️ Every rest (landing, settle, `--at` aim, drop) is checked against the last 256 (`Mouse.Rest`) and redrawn or nudged 1–6 px, so no two paths share both ends. `--at` lands within 1–2 px of the point; `drag --by` lets go about 1% off the offset. In memory, per daemon run |
| P22 | Key gaps with no per-pair structure: each gap drawn around one mean, so "ed" (one finger) runs as fast as "th" (two hands), and a pair's rhythm is not the same from day to day | High | ☑️ `Typing.interval`: with a recording (learned from the person's own typing a few minutes at a time by `Typing.Sampler`, or `apprentice typing learn` at once), each pair keeps the person's own time; a pair not recorded is interpolated from recorded pairs of its kind, weighted by key distance, fingers and rows. Without one, the kind (same finger, same hand, other hand, to and from space) and the distance between the keys set the gap, and each pair keeps a lasting lean from the hand's seed. Slips follow the person's own rate, run length and time to notice, once learned. Only timings are stored, never text |

## Server

| ID | Signal | Sev. | Status and what changed |
| --- | --- | --- | --- |
| S1 | Fast default cadence: no gap, dwell, bursts or fidgets | High | ☑️ Web pages run at `steady`; Facebook, Instagram, Threads, TikTok, LinkedIn, X/Twitter, Reddit, Pinterest, YouTube and Bluesky at `careful` (`[social]` in `agent/sites.toml`). `[pace.styles]` overrides both |
| S2 | Budget kinds read from English labels only | High | ✅ Twelve more languages, CJK matched inside text, `[sites.kinds]` adds words |
| S3 | Soft-block and challenge detection narrow | Med–High | ☑️ See D1–D3 |
| S4 | No active hours, sitting length or daily model | Med | ☑️ `quiet_hours`, `session_max_min` with `break_min`, `actions_per_day`; on in `careful` (2–6, 50 min, 400), exit 4 |
| S5 | No link trail before a like or follow | Med–High | ☑️ See P10 |
| S6 | The VM is a different device | High | ⛔ `doctor` says so; keep important accounts on the Mac (`[vm] local`) |
| S7 | A remote VM has a datacenter address | High | ⛔ |
| S8 | VMs from one image share a fingerprint | High for several accounts | ⛔ Several accounts on one site is out of scope |
| S9 | `Sec-CH-UA` says Linux where the account's history is macOS | Med | ⛔ Part of S6 |
| S10 | No consent-wall step | Low | ⏳ |
| S11 | One image on the wire (JA4, HTTP/2, TCP) | Med–High | ⛔ Part of S8 |
| S12 | Mac zone and language over a remote VM's network | Med for remote VMs | ☑️ `doctor` warns for a remote host |

## Native app / OS (macOS)

| ID | Signal | Sev. | Status and what changed |
| --- | --- | --- | --- |
| A1 | Constant event tag `0x646B6374` on every posted event | Critical | ☑️ Drawn per daemon run, inside 31 bits; still present, no longer one value every install shares |
| A2 | Posted-event provenance (posting PID, source state) | High | ⛔ Any app that looks can tell posted input from hardware; never claim otherwise |
| A3 | Web accessibility forced on every app | High | ☑️ Only on browsers and apps that bundle Chromium or Electron (`showsWeb`) |
| A4 | apprentice's process, socket and files | High for adversarial apps | ⛔ The tool's footprint; not hidden |
| A5 | Accessibility walk of up to 40,000 nodes after every action | Low–Med | ⏳ A smaller re-read |
| A6 | Window activation with no click | Med | ☑️ See P9 |
| A7 | Screen capture | Low | ⛔ |
| A8 | VM and X11 artifacts seen from the guest | Med for guest apps | ⛔ |
| A9 | Clipboard writes outside pages | Low | Unchanged: address bar, file dialogs, and characters no key types |
| A10 | Keep-awake power assertion | Low–Med | Unchanged: opt-in and plainly named |
| A11 | Notifications through `osascript` | Low | ⏳ Needs an app bundle |
| A12 | Screen Recording and its indicator | Low | ⛔ |

## VM (on top of S6–S8)

| ID | Signal | Sev. | Status and what changed |
| --- | --- | --- | --- |
| V1 | Software WebGL, 2 vCPUs, DPR 1, no battery, camera or audio | High | ⛔ |
| V2 | Few fonts; locale | Med | Unchanged: the Mac's language is passed in at install; see V12 |
| V3 | Fixed 1280×800 geometry | Med | ⛔ |
| V4 | Input replayed back to back when ssh delivers lines together | Med | ✅ Each input op carries the host's time and the helper plays it at that spacing, anchored on the quickest trip seen; wheel notches spaced. Verified by exact typing in the VM |
| V5 | Spare keycodes remapped for characters with no key | Med | ⏳ Mapping kept per character, bounded; the helper now waits for apps to see a new mapping |
| V6 | Same fingerprint across VMs | High for several accounts | ⛔ |
| V7 | WebRTC and latency show the server's network | Med | ⛔ |
| V8 | Headful under Xvfb, still a Linux device | Low | ⛔ "Not headless" is not "not detectable" |
| V9 | Guest env file world-readable | Med for guest apps | ☑️ `600` |
| V10 | Only XTEST input devices | Med | ⛔ |
| V11 | Accessibility forced on the guest's session bus | Low–Med | ⛔ GTK and Qt apps are read through it |
| V12 | Two-package font set | Med | ⛔ More fonts make a better Linux, not a Mac |

## Detection response

| ID | Gap | Sev. | Status and what changed |
| --- | --- | --- | --- |
| D1 | Soft-block and challenge phrases in English only | Med–High | ☑️ The big sites' wording in other languages built in; `soft_block_extra` and `challenge_extra` add more |
| D2 | Only new elements on the same page inspected | Med | ☑️ A sparse page after a navigation, and its title, are read too; a long page that merely mentions a phrase is not |
| D3 | Dwell tied to address changes | Med | ☑️ A page that swaps most of its content in place counts as a new page for the dwell |

## What is already safe, and must stay so

- **No WebDriver, CDP or injected script.** `navigator.webdriver` is false, with no debugging port, extension or page script: the largest family of automation tells [7][8] does not apply.
- **Trusted events through the system input stream**, the user's real browser profile on the Mac, and real key codes from the current layout.
- **One account per site, a person's pace, budgets, cooldowns and challenge stops**, which matter more than any single input signal on social sites [4].
- **CAPTCHAs are the user's.** apprentice stops and asks; it never solves a check. That is both an ethical and a detection boundary.
- **Honest limits.** A native app can always tell posted input from hardware (A2), and the VM is always another device (S6). The docs say so.

## References

1. MDN, `PointerEvent.getCoalescedEvents()`. https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/getCoalescedEvents
2. Clearcote, "Pointer events arrive on hardware time" and sibling checks (`pointer-movement-delta-coherence`, `pointer-kinematics`, `settle-before-press`, `keystroke-timing-distribution`, `event-istrusted-provenance`). https://www.clearcotelabs.com/audit/checks/pointer-event-cadence
3. Fingerprint, "Smart Signals reference": datacenter and proxy flags, timezone-versus-IP, `fonts`/`emoji`/canvas/WebGL attributes. https://docs.fingerprint.com/docs/smart-signals-reference
4. Gundelach, Mühlhauser and Herrmann, "Detecting Bot Detection": 46% of 10,000 sites probe automation-only properties; header-level signals cause most headless-Chrome blocks. https://arxiv.org/html/2606.14525v1
5. Cloudflare, "JA3/JA4 fingerprint". https://developers.cloudflare.com/bots/additional-configurations/ja3-ja4-fingerprint/
6. Shuster et al., "Passive Fingerprinting of HTTP/2 Clients", Black Hat EU '17. https://blackhat.com/docs/eu-17/materials/eu-17-Shuster-Passive-Fingerprinting-Of-HTTP2-Clients-wp.pdf
7. DataDome, "How New Headless Chrome & the CDP Signal Are Impacting Bot Detection". https://datadome.co/threat-research/how-new-headless-chrome-the-cdp-signal-are-impacting-bot-detection/
8. Castle, "Why a classic CDP bot detection signal suddenly stopped working". https://blog.castle.io/why-a-classic-cdp-bot-detection-signal-suddenly-stopped-working-and-nobody-noticed/
9. Netresec, "Passive OS Fingerprinting"; browserleaks TCP test. https://www.netresec.com/?page=Blog&month=2011-11&post=Passive-OS-Fingerprinting · https://browserleaks.com/tcp
10. MDN, `WheelEvent.deltaMode`. https://developer.mozilla.org/en-US/docs/Web/API/WheelEvent/deltaMode
11. "Keystroke Dynamics: Concepts, Techniques, and Applications". https://arxiv.org/html/2303.04605v3
12. CreepJS: consistency and "lie" checks. https://github.com/abrahamjuliot/creepjs
13. MDN, `MouseEvent.movementX`. https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/movementX

Vendor sources are cited for what they measure, not for claims about accuracy.
