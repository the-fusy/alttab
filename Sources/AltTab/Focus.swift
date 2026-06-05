//
//  Focus.swift
//  AltTab
//
//  Raise-and-focus the EXACT chosen window on the CURRENT Space.
//
//  PRIMARY path uses the private SLPS sequence (the same one the original AltTab uses), because that
//  is what reliably fronts a SPECIFIC window of a multi-window app (two Finder/Safari windows): we
//  tell the WindowServer to front the process while naming the target window id, post the synthetic
//  "make key" event record, then AXRaise. The public-API path (kAXRaise + activate) is kept as a
//  one-line fallback in case a future macOS breaks the SLPS record layout.
//
//  All cross-process work runs OFF the main thread: these calls can block against an unresponsive app,
//  and blocking main would freeze the panel and the keyboard CGEventTap.
//

import Cocoa
import ApplicationServices

enum Focus {

    /// Serial queue so successive commits can't interleave; .userInitiated — the user is waiting.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "dev.fusy.alttab.focus"
        return q
    }()

    /// Minimal data Focus needs, carried by value so we never touch model objects off-main.
    struct Target {
        let axWindow: AXUIElement
        let pid: pid_t
        let cgWindowId: CGWindowID
    }

    /// Commit focus to `target`. MUST be called AFTER the panel UI has been hidden on the main thread.
    static func focus(_ target: Target) {
        queue.addOperation {
            focusViaSLPS(target)
            // If a future macOS breaks the SLPS record, swap the line above for: focusPublic(target)
        }
    }

    // MARK: - PRIMARY: precise window focus via SLPS
    // Ported byte-for-byte from alt-tab-macos Window.focus()/makeKeyWindow (Window.swift:252-277),
    // itself from Hammerspoon issue #370.

    private static func focusViaSLPS(_ target: Target) {
        guard target.cgWindowId != 0 else {
            Log.focus.error("no wid for pid \(target.pid, privacy: .public) — public-API fallback")
            focusPublic(target); return
        }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(target.pid, &psn) == noErr else {
            Log.focus.error("GetProcessForPID failed for pid \(target.pid, privacy: .public) — public-API fallback")
            focusPublic(target); return
        }
        _SLPSSetFrontProcessWithOptions(&psn, target.cgWindowId, 0x200 /* userGenerated */)
        makeKeyWindow(&psn, target.cgWindowId)
        AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString)
        // Belt-and-suspenders: ensure the app is frontmost even if SLPS no-ops on some OS build.
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    /// The undocumented 0xf8-byte WindowServer event record that makes a specific window key.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        var wid = wid
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    // MARK: - FALLBACK: public APIs only (no private symbols)

    private static func focusPublic(_ target: Target) {
        AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Do NOT pass .activateAllWindows — it re-orders sibling windows and can defeat the raise.
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
        }
    }
}
