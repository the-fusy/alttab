//
//  AppObserver.swift
//  AltTab
//
//  Owns one AXObserver for one app. The C callback (AXObserverCallback) can't capture Swift context;
//  rather than pass `self` as an unretained refcon (which risks a use-after-free if the observer is
//  torn down while a callback is in flight), the callback is fully self-free: it resolves the pid
//  from the delivered element and routes everything through the WindowStore singleton. All
//  cross-process reads run on the serial AXQueue; all model mutation hops to the main thread FIFO.
//

import Cocoa
import ApplicationServices

final class AppObserver {
    let pid: pid_t
    private let appElement: AXUIElement
    private var observer: AXObserver?

    /// Exactly the notifications our reduced scope needs (no resize/move/minimize/hidden).
    private static let notifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationActivatedNotification,
        kAXTitleChangedNotification,
    ]

    init(pid: pid_t, runningApp: NSRunningApplication) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
    }

    // MARK: - Setup / teardown

    func setUp() {
        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &obs) == .success, let obs else { return }
        self.observer = obs
        AXQueue.shared.async { [appElement] in
            for name in Self.notifications {
                AXObserverAddNotification(obs, appElement, name as CFString, nil)
            }
        }
        if let rl = AXRunLoopThread.shared.runLoop {
            CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }

    /// Detach the source and drop the observer. Without removing the source, every quit app would
    /// leak an orphaned source on the AX thread's runloop forever (alt-tab's dominant VM leak).
    func tearDown() {
        guard let observer else { return }
        if let rl = AXRunLoopThread.shared.runLoop {
            CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(observer), .commonModes)
        }
        self.observer = nil // ARC dealloc tears down all subscriptions.
    }

    // MARK: - C callback (self-free)

    /// Fires on the AX run-loop thread. Resolves everything from `element` + the singleton store, so a
    /// torn-down AppObserver is never dereferenced. Mirrors alt-tab's element-driven dispatch.
    private static let callback: AXObserverCallback = { _, element, notificationName, _ in
        handleEvent(type: notificationName as String, element: element)
    }

    private static func handleEvent(type: String, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        switch type {
        case kAXUIElementDestroyedNotification:
            // `element` is the destroyed window (stale). Route through the SAME serial AXQueue as the
            // created/title/focus reads (no IPC needed here — the bounce only enforces ordering) so OS
            // delivery order is preserved on the way to main; otherwise a `created` read still queued on
            // AXQueue could land AFTER this destroy and resurrect the window. Match by identity on main;
            // this avoids the full reconcile that a failed windowId() would otherwise force per close.
            AXQueue.shared.async {
                DispatchQueue.main.async { WindowStore.shared.removeWindow(matching: element) }
            }

        case kAXWindowCreatedNotification:
            AXQueue.shared.async {
                let attrs = readWindowAttrs(element)
                DispatchQueue.main.async { WindowStore.shared.addWindow(pid: pid, element: element, attrs: attrs) }
            }

        case kAXTitleChangedNotification:
            AXQueue.shared.async {
                guard let wid = element.windowId() else { return }
                let attrs = readWindowAttrs(element)
                DispatchQueue.main.async { WindowStore.shared.updateTitle(wid: wid, title: attrs.title) }
            }

        case kAXFocusedWindowChangedNotification:
            // `element` is the newly-focused window. Only bump MRU if the OWNING app is frontmost —
            // background apps fire focused-window-changed too (e.g. Photoshop focuses a window after
            // you've already switched away), which would otherwise corrupt "current window = index 0".
            AXQueue.shared.async {
                guard let wid = element.windowId() else { return }
                DispatchQueue.main.async {
                    guard NSRunningApplication(processIdentifier: pid)?.isActive == true else { return }
                    WindowStore.shared.noteFocused(wid: wid)
                }
            }

        case kAXApplicationActivatedNotification:
            // `element` is the app; read its focused window and bump that window's MRU.
            AXQueue.shared.async {
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                      let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return }
                // swiftlint:disable:next force_cast
                guard let wid = (f as! AXUIElement).windowId() else { return }
                DispatchQueue.main.async { WindowStore.shared.noteFocused(wid: wid) }
            }

        default:
            break
        }
    }
}
