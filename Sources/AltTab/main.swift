//
//  main.swift
//  AltTab
//
//  Process entry point. Installs crash/signal restore for the native Cmd+Tab BEFORE anything else
//  (the symbolic-hotkey disable persists past process death, so a crash must not leave Cmd+Tab dead),
//  then starts the agent app.
//

import AppKit
import Darwin

// BEST-EFFORT restore of native Cmd+Tab on abnormal termination. NativeCmdTab.restore() ultimately
// calls CGSSetSymbolicHotKeyEnabled, which does Mach IPC to the WindowServer — that is NOT strictly
// async-signal-safe and could in theory hang if the crash happened while holding a CG lock. We accept
// that: a best-effort restore is far better than reliably leaving the user with a dead Cmd+Tab.
//  - SIGTERM: Activity Monitor quit / `kill` (applicationWillTerminate is NOT called)
//  - SIGINT:  Ctrl-C from a terminal
//  - SIGTRAP/SIGILL: Swift runtime trap (force-unwrap nil, precondition failure, etc.)
//  - SIGSEGV/SIGABRT/SIGBUS: hard crashes
//  (SIGKILL cannot be caught — accept that edge case.)
for sig in [SIGTERM, SIGINT, SIGTRAP, SIGILL, SIGSEGV, SIGABRT, SIGBUS] {
    signal(sig) { s in
        NativeCmdTab.restore()
        signal(s, SIG_DFL) // re-raise with the default handler so the process still terminates/cores
        raise(s)
    }
}

// ObjC-side exceptions (e.g. from AppKit) bypass the Swift signal path; catch them too.
NSSetUncaughtExceptionHandler { _ in
    NativeCmdTab.restore()
}

let app = NSApplication.shared
// Agent app: no Dock tile, no app menu bar (also LSUIElement=true in Info.plist).
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
