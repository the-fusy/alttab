//
//  NativeCmdTab.swift
//  AltTab
//
//  Takes over the native macOS Cmd+Tab by disabling its system symbolic hotkeys, and restores them.
//  The underlying CGSSetSymbolicHotKeyEnabled is declared once in PrivateAPIs.swift.
//

import CoreGraphics

enum NativeCmdTab {
    // Symbolic-hotkey IDs (alt-tab study: src/macos/api-wrappers/SkyLight.framework.swift:164-168):
    //   1 = Cmd+Tab        (forward app switcher)
    //   2 = Cmd+Shift+Tab  (backward app switcher)
    // We disable BOTH: leaving #2 enabled would let the native backward switcher fight our panel.
    // We do NOT touch #6 (Cmd+key-above-Tab / `~`) since our binding is Tab only.
    private static let ids: [Int32] = [1, 2]

    /// Disable the native switcher so our Carbon hotkey reliably receives Cmd+Tab.
    /// Call AFTER Accessibility is granted and AFTER our hotkeys are registered.
    static func disable() {
        for id in ids { CGSSetSymbolicHotKeyEnabled(id, false) }
        Log.hotkeys.log("native Cmd+Tab disabled (symbolic hotkeys 1,2)")
    }

    /// Restore the native switcher. Runs on quit AND (best-effort) from crash/signal handlers.
    /// NOTE: CGSSetSymbolicHotKeyEnabled does Mach IPC to the WindowServer, so this is NOT strictly
    /// async-signal-safe — from a signal handler it is best-effort and could theoretically hang.
    static func restore() {
        for id in ids { CGSSetSymbolicHotKeyEnabled(id, true) }
    }
}
