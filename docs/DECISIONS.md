# AltTab — Decisions & Architecture

This is the **canonical, portable record** of what AltTab is, why it exists, and
every product/technical decision behind it. It lives in the repo on purpose: clone
the repo and you have the full context, no external notes required.

> Status legend: ✅ locked · 🔁 likely but revisable · ❓ open

---

## 1. What & why

**AltTab** is a minimal, fast macOS window switcher for Apple Silicon. It is a
**from-scratch reimplementation** inspired by
[alt-tab-macos](https://github.com/lwouis/alt-tab-macos) — *not* a fork.

> **On the name.** "AltTab" is a deliberate, openly-acknowledged homage: to the Windows
> **Alt+Tab** (whose behavior the author missed) and to lwouis's macOS **AltTab**. We don't
> hide the reference. To avoid colliding with the original in the system, our bundle id is
> the distinct **`dev.fusy.alttab`** (the original is `com.lwouis.alt-tab-macos`).

**Motivation.** alt-tab-macos is excellent but heavy (~27k lines of Swift): Pro
licensing, Sparkle auto-update, crash reporting, search, an exceptions editor,
macros, 9 shortcut slots, window thumbnails, a preview panel, and a very large
settings window (`ControlsTab.swift` alone is ~1400 lines). That surface area makes
it feel sluggish and means updates frequently break things. AltTab keeps only the
core and bets on **speed over breadth of features**.

**Distribution.** Open-source on GitHub, distributed as a signed + notarized `.app`
using the maintainer's Apple **Developer ID**. **Not** the App Store — AltTab relies
on a small set of private SkyLight/Accessibility APIs that the App Store forbids
(this is an accepted trade-off; there is no public API for the things AltTab does).

**Targets.** Apple Silicon (M1 / M2 Pro), macOS 13+ (Ventura and later).

---

## 2. Product decisions (locked)

| # | Decision | Detail |
|---|----------|--------|
| P1 ✅ | **One hotkey: Cmd+Tab** | Overrides the native macOS Cmd+Tab. The native Cmd+Tab and Cmd+Shift+Tab are disabled while AltTab runs (private `CGSSetSymbolicHotKeyEnabled`) and **restored on quit and on crash/signal**. |
| P2 ✅ | **List = windows, one tile per window** | Apps with multiple windows show multiple tiles. Each tile = **app icon + window title**. |
| P3 ✅ | **Icons only, no thumbnails** | No live window previews ⇒ **no Screen Recording permission required**. Only Accessibility is needed. |
| P4 ✅ | **Per-window MRU** | All windows sorted by last-use time (most recent first). A quick Cmd+Tab tap commits the **previous window** (the tile pre-selected at index 1). |
| P5 ✅ | **Cycling & commit** | Hold Cmd + press Tab → next; tap Shift (Cmd+Shift) → previous; **release Cmd → commit highlighted tile**; Esc → cancel; click commits. |
| P6 🔁 | **All-Spaces window list** (revised from "current Space only") | Originally current-Space-only, but the kAXWindows-based reconcile gutted the model whenever a summon ran on another Space (e.g. fullscreen YouTube creates its own Space): every other-Space window was dropped as "dead" and its MRU history erased. Now a window seen once stays tracked when its Space goes to the background; reconcile drops a window only when the WindowServer no longer lists it (`CGWindowList`, all Spaces), and committing an other-Space window switches Space — matching native Cmd+Tab semantics. Known gap: windows on a Space never visited since launch stay unknown until first visit (we still don't brute-force other-Space enumeration, see T5). Still **no** Dock interaction (the user keeps the Dock hidden/unused). |
| P7 ✅ | **Fast-flip with no flicker** | At session start the previous window is pre-selected and the panel draw is **deferred ~100 ms**. Releasing Cmd before then flips to the previous window without the panel ever appearing. |
| P8 ✅ | **Tile close button** | Each tile shows a close-window (✕) button on hover. A quit-app button is a nice-to-have, not required. |
| P9 ✅ | **Menu-bar agent** | `LSUIElement` background app (no Dock tile). An `NSStatusItem` provides Quit + a couple of toggles. Settings persist in `UserDefaults`. **No** large settings window. |

### Explicitly dropped vs alt-tab
Sparkle, AppCenter/crash reporting, ShortcutRecorder, Pro/licensing, search,
exceptions editor, macros, multiple shortcut slots, preview panel, window
thumbnails, RTL handling, Liquid Glass, and the big settings window.

---

## 3. Technical decisions

| # | Decision | Rationale |
|---|----------|-----------|
| T1 🔁 | **AppKit, no SwiftUI** for the switcher | The switcher must appear instantly and never animate implicitly; raw `NSPanel`/`NSView`/`CALayer` is what alt-tab uses and what gives precise, fast control. |
| T2 🔁 | **SwiftPM executable + a bundling/codesign script** (no `.xcodeproj` to hand-maintain, no npm/Python) | Fully CLI-buildable and reproducible; `swift build` + one script produces and signs `AltTab.app`. Keeps the repo plain-text and reviewable — the opposite of bloat. |
| T3 🔁 | **Swift language mode v5** | Avoids the Swift 6 strict-concurrency compile wall for AppKit code that legitimately uses background run-loop threads for Accessibility IPC and the event tap. |
| T4 ✅ | **All private APIs isolated in one file** (`PrivateAPIs.swift`) | When a macOS update breaks a private symbol, the blast radius is one file. Live private surface: 7 linked SkyLight/AX symbols (see T9) plus a runtime-only Icon Services path (`IconServicesSPI`) that is not linked and falls back to public `app.icon` flattening. |
| T5 🔁 | **Apps via `NSWorkspace.runningApplications` + KVO**; **windows via per-app Accessibility** (`AXUIElementCreateApplication` → `kAXWindowsAttribute`) | `kAXWindowsAttribute` can only *enumerate* current-Space windows; we still avoid the brute-force `_AXUIElementCreateWithRemoteToken` trick. Cross-Space coverage comes from remembering windows once seen (P6), with `CGWindowList` (all Spaces) as the liveness oracle — kAXWindows absence means "other Space", not "closed". |
| T6 ✅ | **Window identity = `CGWindowID`** via private `_AXUIElementGetWindow` | Stable identity across AX re-fetches; one tiny, very stable private call. |
| T7 ✅ | **MRU = monotonic counter per window**, bumped on `kAXApplicationActivatedNotification` / `kAXFocusedWindowChangedNotification` / `kAXMainWindowChangedNotification` | Simpler than and equivalent to alt-tab's dense-rank rotation. Sort descending at show time. **`kAXMainWindowChangedNotification` is required** for native window-tab switches (terminals, browsers): selecting another tab re-points the app's *main* window with no app-activation and often no focused-window-changed, so without it the just-used tab never reaches MRU-0 and Cmd+Tab lands on the previously-used tab. We read the app's `kAXMainWindow` and bump it, gated on the app being frontmost (same index-0 invariant as the focused-window path). |
| T8 ✅ | **AX IPC off the main thread**, with a low `AXUIElementSetMessagingTimeout`; mutate the model on main | An unresponsive app must never freeze the switcher. |
| T9 ✅ | **Focus/raise = private SLPS (primary), public fallback** | Initially shipped public-only (`kAXRaise` + `activate`), but the review judged that unreliable for fronting a *specific* window of a multi-window app — the app's whole job. So the primary path is the proven SLPS sequence the original AltTab uses: `_SLPSSetFrontProcessWithOptions` (front process, name window id) → `makeKeyWindow` (the 0xf8-byte WindowServer record) → `kAXRaise`. The public-only path remains in `Focus.swift` as a one-line fallback if a future macOS breaks the record. **macOS 27 note:** an earlier belt-and-suspenders `NSRunningApplication.activate(options: [])` tail was **removed** — on macOS 27 even the deprecated empty-option form raises *all* of a multi-window app's windows as a group (every sibling jumps in front of the app you switched from), defeating the per-window front. SLPS alone fronts the exact named window, so the tail was pure regression. This raises the live private surface to 5 symbols — accepted: precise focus is the point. |
| T10 ✅ | **Input model** | Carbon `RegisterEventHotKey` for Cmd+Tab (re-fires each Tab while Cmd held → drives both summon and forward cycling); a `CGEventTap` (background run-loop thread) watching `.flagsChanged` (Cmd release = commit, never absorbed; while a session is up, a Shift down-edge = step back one — Cmd+Shift, gated on the Shift keycode so each tap = one step) and `.keyDown` (Esc = cancel, absorbed while a session is active). Esc lives in the tap rather than an `NSEvent` local monitor because a non-activating panel can't reliably receive a local monitor's key events. Plus a hardware-modifier poll so a dropped Cmd-up can't strand the panel. |
| T11 ✅ | **Login item via `SMAppService`** (macOS 13+) | One line; far simpler than hand-writing a launchd LaunchAgent plist. *(Optional, exposed as a menu-bar toggle.)* |
| T12 ✅ | **Embed `Info.plist` into the Mach-O** (`-sectcreate __TEXT __info_plist`) | A plain SwiftPM executable has no embedded `__info_plist`; without it macOS LaunchServices refuses to launch the assembled `.app` (launchd error 125). Added as a linker flag in `Package.swift`. |

---

## 4. Required permissions
- **Accessibility** (`AXIsProcessTrusted`) — mandatory; without it no window
  enumeration or focusing is possible.
- **Screen Recording** — **not required** (icons only, no thumbnails).

---

## 5. Build, run & verification status

**Build pipeline (no Xcode, no JS/Python):**
```
./build.sh                  # swift build -c release → assemble AltTab.app → ad-hoc sign + verify
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./build.sh   # release signing
```
Then notarize per the commented block in `build.sh` (`xcrun notarytool` + `stapler`).

**Verified on this machine (Apple Silicon, macOS 14.5, CLT-only, Swift 6.0.3):**
compiles debug+release with **0 warnings**; bundles + ad-hoc-signs under hardened
runtime with the 2-key entitlements; `codesign --verify --strict` passes; SkyLight
is linked (`otool -L`); `Info.plist` is embedded; the binary **launches and runs**
without crashing (direct exec). *Not yet interactively tested* — that needs the user
to grant Accessibility and exercise Cmd+Tab.

**Re-verified on macOS 26.4.1 / Swift 6.3.1 / Xcode toolchain** (target `arm64-apple-macosx26.0`):
compiles release with **0 warnings**; bundles + ad-hoc-signs; SkyLight linked and `Info.plist`
embedded. All five private symbols (`CGSSetSymbolicHotKeyEnabled`, `_AXUIElementGetWindow`,
`GetProcessForPID`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`) confirmed
**resolvable at runtime via `dlsym`** in the macOS 26 dyld shared cache — so the SLPS focus path
and the native-Cmd+Tab toggle still bind. Interactively **runs** on macOS 26 (user-confirmed). The
binary is now produced solely against the macOS 26.4 SDK (`minos` 13.0); the 13/14/15 back-deploy
floor has **not** been re-validated on this toolchain (prior validation was macOS 14.5 / Swift 6.0.3).

> Note: `open AltTab.app` from an automated/Background launchd session fails with
> launchd error 125 ("Domain does not support specified action") because that session
> can't reach the GUI launch domain. Launching from Finder or a normal Terminal
> (the Aqua GUI session) works. Session-context limitation, not an app bug.

**First-run permission:** AltTab needs **Accessibility** (System Settings ▸ Privacy &
Security ▸ Accessibility). Ad-hoc signing changes the code hash on every rebuild, which
**revokes** the grant — for day-to-day dev, sign with a *stable* self-signed identity
(or Developer ID) so the grant sticks. No Screen Recording permission is needed.

---

## 6. Code review pass (pre-first-commit)

A multi-agent adversarial review (concurrency, session state-machine, AX model, focus,
AppKit) ran before the first commit and surfaced 14 verified findings, all addressed:

- **MRU/ordering:** serial AX queue + FIFO `DispatchQueue.main.async` hops (no out-of-order
  events / zombie windows); `isActive` guard so background apps don't corrupt index 0;
  on-screen **z-order seeding** (`CGWindowList`) so the first Cmd+Tab lands on the true
  previous window; destroy handled by element-identity match (no full reconcile per close).
- **Safety:** self-free AX observer callback (no use-after-free via refcon); restore native
  Cmd+Tab on more crash signals (SIGSEGV/SIGABRT/…); comments corrected re: the restore not
  being strictly async-signal-safe.
- **Session:** single-window Space → no-op; synchronous fast-tap race guard; Esc moved into
  the event tap; broadened app filter (regular + accessory, not just regular) + summon-time
  pickup of newly-eligible apps; reconcile throttle; close-tile rebuild keeps the panel anchored.
- **Focus:** switched to the SLPS path (see T9).

## 7. Open questions / to validate
- Interactive validation of the full gesture (fast flip, hold-to-browse, Esc, multi-window
  focus, MRU "previous window" correctness) once Accessibility is granted.
- Exact tile look (sizing, spacing, highlight) — tune after first run.
- Minimum deployment target stays 13.0 unless an API forces 14.0.

---

## 8. How decisions are recorded
Every non-trivial decision goes in this file (and the matching tables above are kept
current). Keep entries short and state the *why*, not just the *what*. This file is
the single source of truth for project intent; the code is the source of truth for
behavior.

---

## 9. Post-first-run changes (after interactive testing on macOS 26)

After the first real run, the following were decided and applied:

- **Switcher look → native macOS Cmd+Tab style** (revises P2's *presentation*, not its
  per-window model). One centered row of **app icons only**, a soft neutral
  rounded **halo** on the selected icon (the saturated-blue full-tile fill read as
  "Linux/generic"), and a single **title label beneath the row** showing only the
  *selected* window's title. Tiles still map 1:1 to windows; the title label is how
  same-app windows are told apart.
- **Single-row invariant — icons adaptively resize, they do NOT wrap.** The design intent
  is that the switcher is **always one row**. `SwitcherView.chooseIconSize` shrinks the
  icon (maxIcon 120 → minIcon 64, step 8) to the largest size at which **all** windows fit
  one row within the width budget (`screen × 0.92`); it deliberately does **not** consider
  height. The trigger for shrinking is "doesn't fit one row by **width**", never "doesn't
  fit by height" — an earlier height-only criterion was the bug that let big icons wrap to a
  second row instead of shrinking. **Assumption:** the window count never exceeds what fits
  in one row at `minIcon` (≈18 on a 1080p display, more on wider screens), so in practice we
  never wrap. Multi-row wrap in `build` + the **top-anchored `SwitcherPanel.clamp()`** is a
  defensive fallback only (it repositions the panel; it does not crop or scroll — an accepted
  gap for an unrealistic count).
- **Close (✕) surfaces a blocking save dialog.** Pressing a tile's ✕ presses the AX
  close button, then polls briefly for an `AXSheet` (the "Save changes?" / "Close all
  tabs?" / running-process dialogs). If one appears, the panel steps aside and the
  window is fronted via `Focus.focus` so the user actually sees and answers the dialog,
  instead of it being stranded in the background with the tile already gone.
- **Tahoe Liquid Glass icon rim stripped at cache time.** `NSRunningApplication.icon` is now an
  HDR (extended sRGB) Icon Services render sitting on a translucent chiclet — the specular
  rim blooms on the sides of every tile. `WindowStore.cacheIcon` asks Icon Services (runtime
  SPI, isolated in `PrivateAPIs.IconServicesSPI`) for the unmasked asset and flattens it to
  8-bit sRGB; the tile's `NSImageView` is non-vibrant and locked to `.standard` dynamic range
  so the HUD cannot re-apply a glass edge. If the SPI disappears we still flatten `app.icon`
  and live with the plate. Matches the existing "no Liquid Glass" product cut vs alt-tab-macos.
- **App icon added** (`Resources/AltTab.icns`, wired via `CFBundleIconFile`): a blue
  squircle with two overlapping window cards, drawn programmatically (CoreGraphics) at
  all sizes — no asset catalog, no external tooling. The menu-bar item keeps its
  monochrome SF Symbol (template images are the correct menu-bar convention).
- **Correctness fixes from the pre-run adversarial review** (all verified): MRU is now
  bumped optimistically on commit (fixes a stale-snapshot wrong-flip on rapid double-tap);
  `sessionActive` is lock-guarded across the event-tap thread; the window-destroyed event
  is routed through the serial AXQueue (ordering); per-app window order is preserved
  (ordered dedupe + front-most-highest stamping) instead of randomized by `Set`;
  `userFocusObserved` only latches once a focus event is actually applied; a missed
  destroy identity-match forces an un-throttled per-app reconcile; the Launch-at-Login
  toggle reflects real `SMAppService` status and surfaces `.requiresApproval`.

---

## 10. Window liveness: the "closed window still in the switcher" class of bug (0.1.6)

Symptom (a stock macOS app, Cmd+W): the window is gone from the screen, but its tile stays in the
switcher and selecting it does nothing. Measured on macOS 26 with a WindowServer-only probe
(`CGWindowList` + `CGSCopySpacesForWindows`, no AX), across every way a window can leave the
screen:

| state | listed by the WindowServer | ordered on-screen | Spaces |
|---|---|---|---|
| open | yes | yes | `[current]` |
| closed (ordinary AppKit `close`) | **no** | — | — |
| ordered out ("close to tray") | yes | no | `[current]` |
| minimized to the Dock | yes | no | `[current]` |
| app hidden (Cmd+H) | yes | no | `[current]` |
| **closed in the app above** | yes | no | **`[]`** |

Two conclusions drive the fix:

- **"On no Space at all" is an unambiguous ghost signature.** Every state in which a window
  can still be switched to keeps its Space id; only a closed-but-not-destroyed window reports
  an empty set. That leftover therefore escaped both existing rules (`gone` — still
  listed; ordered-out-on-current-Space — no Space to compare), which is why it survived until
  the process itself quit. It is now culled, **gated on the app's AX having answered**: with a
  dead AX (a backgrounded Electron-style app returns `kAXErrorCannotComplete`) "not in `kAXWindows`" says
  nothing, so those are still spared. `currentSpaceWindows()` returns that `answered` flag —
  previously an AX failure and a genuinely window-less app were indistinguishable.
- **Timeliness needs a synchronous cull, symmetric to `ensureFrontmostAppTracked`.** Closing a
  window emits no reliable AX signal (some apps send no `kAXUIElementDestroyed`), so a ghost is
  found only by the summon-time reconcile — which runs *after* `sortedForDisplay()` froze the
  snapshot, showing the ghost for one full summon after every close. `dropFrontmostGhostWindows()`
  culls it on the main thread before the snapshot. It is AX-free (the signature comes from the
  WindowServer, so no hung app can stall main), pays for the `CGWindowList` call only when a
  Space query already flagged a candidate, and is restricted to the frontmost app — which, being
  active, satisfies the same `axAnswered` gate for free.

---

## 11. Stale focus answers: the "Cmd+Tab flips between the last and the one before that" bug (0.1.7)

Symptom: a single Cmd+Tab occasionally lands on the app used *two* switches ago instead of the
previous one — intermittently, and only during quick back-and-forth switching.

Measured, not guessed. `log show` over a working day, pairing every `commit → W` with the next
`summon: … top:`, found 12 of ~160 fast pairs where the resulting order was not "W on top, the rest
unchanged". Eight of them kept index 0 correct and had **indices 1 and 2 swapped** — exactly the
symptom. A live debug stream then caught it happening with no user input at all:

(A, B, C are three ordinary apps; seconds are relative)

```
29.381  COMMIT A#1
29.382  MRU bump A#1 → 12871     ← ours, correct
29.966  MRU bump B#2 → 12872     ← no key was pressed
31.021  MRU bump C#3 → 12873
32.074  MRU bump B#2 → 12874
33.128  MRU bump C#3 → 12875
34.173  MRU bump B#2 → 12876
34.738  summon top: A, B, C      ← expected [A, C, B]
```

Two facts pin the cause. The phantom bumps arrive **1.05s apart, every time** — the global AX
messaging timeout (`setGlobalMessagingTimeout(1)`), i.e. the serial `AXQueue` sitting out a timeout
per block. And the stream contains no `AX applicationActivated`/`mainWindowChanged` lines at all, so
every one of those bumps came from the only path to `noteFocused` without a debug line in front of
it: `bumpFocusedWindow`, driven by `NSWorkspace.didActivateApplication`.

So the MRU backbone was **asking AX which window has the focus, and applying whatever came back,
whenever it came back**. Activation notifications are prompt and ordered; the AX read that refines
them is neither, because a summon enqueues one reconcile block per app and one unresponsive app
delays everything behind it. Answers landed seconds late, after the user had committed elsewhere,
and pushed a window nobody chose to MRU index 1. `alignFrontmostWindow` hid half of it by fixing
index 0 at summon — which is why the top of the list always looked right and the *previous* window
did not.

The fix separates the trustworthy signal from the slow one:

- **Order comes from `NSWorkspace`, synchronously.** `noteActivated(pid:)` runs on the main thread
  and bumps the app's most-recently-used window from the model alone — no AX, no queue hop. That is
  the same "which window of this app is current" guess `alignFrontmostWindow` already makes, and it
  is exact for every single-window app.
- **AX only refines, and only while still current.** `frontEpoch` counts front changes (activation
  *and* our own commit — a commit invalidates every read queued for the app being left). A queued
  read captures the epoch and is discarded on the main hop if it no longer matches.
- **Stale for MRU ≠ useless.** A discarded answer still runs `selfHealIfUnknown`, so a focus signal
  naming a window we never enumerated keeps triggering discovery. Dropping the whole answer would
  have re-introduced "the window shows up only after the first Cmd+Tab" (§9).
- **The same gate on every AX path.** `focusedWindowChanged` and `mainWindowChanged` already required
  the owning app to be active; `applicationActivated` — a backstop duplicate of the NSWorkspace path
  — required nothing at all. All three now go through `noteFocusedIfFrontmost`.

The queue backlog itself is a separate, lesser problem: it no longer corrupts MRU, but it does delay
window discovery. `reconcileApp` now logs any app whose AX enumeration takes over 0.5s — and that log,
on its very first run, named the cause outright:

```
slow AX: <app> Web Content took 1.00s to enumerate windows (answered=false)   ×48 in 60 summons
```

A single culprit, and it was **not running** — absent from both `ps` and `lsappinfo`. Its observer had
leaked: `appQuit` retires apps off the `NSWorkspace.runningApplications` KVO, and that signal never
arrived for this WebKit helper process. Every summon then re-queried a dead pid, which answers nothing
and so sits out the full 1s messaging timeout — on the *serial* AXQueue, delaying every real app behind it.
That single leak was the whole backlog. `reconcileApp` now refuses to query a pid that is no longer a
running application and tears the app down instead. The check sits at the top of `reconcileApp` (not in
a separate sweep) so it covers the self-heal path too, and it is self-correcting: a false negative just
re-adds the app on the next `reconcileAllApps`.
