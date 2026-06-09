# AltTab

A minimal, fast macOS window switcher for Apple Silicon. One shortcut, all your
windows in most-recently-used order, instant flip to the previous window.

> **Name / homage.** This is a tribute to the Windows **Alt+Tab** (whose behavior I missed)
> and to [lwouis's **AltTab** for macOS](https://github.com/lwouis/alt-tab-macos) — I'm not
> hiding the reference. It's a from-scratch, deliberately tiny take that keeps only the core
> switcher and bets on **speed over breadth of features**. To stay out of the original's way
> in the system, the bundle id is `dev.fusy.alttab` (the original is `com.lwouis.alt-tab-macos`).

See [`docs/DECISIONS.md`](docs/DECISIONS.md) for the full rationale and every design choice.

## What it does

- **Cmd+Tab** opens the switcher (it replaces the native Cmd+Tab while running, and
  restores it on quit/crash).
- Lists your standard windows, one tile per window (app icon + window title), sorted by
  **most recently used**. Windows on other Spaces appear once you've visited their Space;
  switching to one moves you there.
- A quick tap-and-release flips straight to the **previous window** — the panel doesn't
  even appear.
- Hold **Cmd** and press **Tab** to cycle forward, tap **Shift** (i.e. **Cmd+Shift**) to
  step back, **Esc** to cancel, release **Cmd** to switch. Click a tile to switch;
  the ✕ on a tile closes that window.

## What it intentionally does *not* do

No window thumbnails, no Screen Recording permission, no minimized/hidden windows, no Dock
dependency, no settings window, no auto-updater, no licensing. Just the switcher.

## Requirements

- Apple Silicon (M1/M2…), macOS 13+.
- **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility).
  No Screen Recording permission is needed.
- Build: the Swift toolchain (Xcode or Command Line Tools). No npm/Python.

## Build & run

```sh
./build.sh                 # → build/AltTab.app (ad-hoc signed, for local use)
```

Then launch `build/AltTab.app` from Finder, and grant Accessibility when prompted.

> **Dev tip:** ad-hoc signing changes the app's code hash on every rebuild, which makes
> macOS forget the Accessibility grant. To keep the grant across rebuilds, sign with a
> stable identity:
> ```sh
> SIGN_IDENTITY="AltTab Dev" ./build.sh         # a self-signed identity you create once
> ```

### Release (Developer ID + notarization)

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
# then notarize + staple — see the commented block at the bottom of build.sh
```

## How it works (one paragraph)

Apps come from `NSWorkspace` + KVO; windows from per-app Accessibility
(`AXUIElementCreateApplication` → `kAXWindows`), identified by `CGWindowID`. MRU is a
per-window counter bumped on focus-change AX events, all handled on a background
run-loop thread so an unresponsive app never freezes the UI. The hotkey is a Carbon
hot key plus a `CGEventTap` that watches for the Cmd key being released (= commit) and
Esc (= cancel). The overlay is a single reused non-activating `NSPanel`. Focusing the
chosen window uses the private SkyLight "make-key" sequence (so the *exact* window of a
multi-window app is fronted), with a public-API fallback. Private APIs are confined to
`Sources/AltTab/PrivateAPIs.swift`.

## License

MIT — see [`LICENSE`](LICENSE).

---

*Not affiliated with or endorsed by lwouis/alt-tab-macos.*
