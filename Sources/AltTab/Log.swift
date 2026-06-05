//
//  Log.swift
//  AltTab
//
//  Unified-logging handles, one per subsystem area. Default-level (.log) events are PERSISTED by
//  the OS, so a bug can be diagnosed after the fact:
//    log show --last 10m --predicate 'subsystem == "dev.fusy.alttab"'     (or scripts/logs.sh)
//  .debug events are memory-only — visible in a live `log stream --level debug`, gone afterwards.
//  Dynamic strings are interpolated with `privacy: .public` on purpose: the log stays on this
//  machine and redacted "<private>" window titles would defeat the point of the diagnostics.
//

import os

enum Log {
    private static let subsystem = "dev.fusy.alttab"
    static let app     = Logger(subsystem: subsystem, category: "app")     // lifecycle, menubar
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys") // Carbon hotkey, event tap, native override
    static let session = Logger(subsystem: subsystem, category: "session") // switcher sessions (summon/commit/cancel)
    static let store   = Logger(subsystem: subsystem, category: "store")   // window model add/drop/reconcile
    static let focus   = Logger(subsystem: subsystem, category: "focus")   // SLPS focus path + fallbacks
}
