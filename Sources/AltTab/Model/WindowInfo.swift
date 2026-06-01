//
//  WindowInfo.swift
//  AltTab
//
//  One tile == one visible standard window on the CURRENT Space.
//  Identity is the CGWindowID (from the private _AXUIElementGetWindow).
//

import Cocoa
import ApplicationServices

/// Reference type: AXObserver callbacks mutate it in place and the store indexes it by WID,
/// so value semantics would fight us.
final class WindowInfo {
    /// Stable identity across the window's lifetime. From `_AXUIElementGetWindow`.
    let cgWindowId: CGWindowID
    /// pid of the owning app. Used to fetch the shared icon and to route AX/focus calls.
    let pid: pid_t
    /// The AX element. ALL cross-process reads/commands through this must happen off the main thread.
    let axElement: AXUIElement

    /// Last-known title (AX kAXTitleAttribute, falling back to app localizedName).
    var title: String
    /// App display name — fallback title source and shown alongside the icon.
    var appName: String
    /// Cached app icon (one CGImage per app, shared by all its windows). Set off-main, read on main.
    var icon: CGImage?

    /// Per-window MRU stamp. Higher == more recently focused. Sorted DESC at show time.
    /// A single global Int64 counter (WindowStore.mruCounter) is bumped on each focus and copied
    /// here — O(1), and equivalent ordering to alt-tab's dense-rank rotation (Windows.swift:444-458).
    var mruStamp: Int64

    init(cgWindowId: CGWindowID, pid: pid_t, axElement: AXUIElement,
         title: String, appName: String, icon: CGImage?, mruStamp: Int64) {
        self.cgWindowId = cgWindowId
        self.pid = pid
        self.axElement = axElement
        self.title = title
        self.appName = appName
        self.icon = icon
        self.mruStamp = mruStamp
    }

    /// Title shown in the tile. AX title → app name (never empty).
    var displayTitle: String { title.isEmpty ? appName : title }

    /// Outcome of pressing the window's close button.
    enum CloseOutcome {
        case closed          // the window went away (or had no close button) — safe to drop the tile
        case needsAttention  // a confirmation dialog (e.g. "Save changes?") is now blocking the close
    }

    /// Press the window's close button (the tile's ✕), then report whether the window actually closed
    /// or a confirmation sheet popped up. Runs off-main; `completion` is delivered on the MAIN thread.
    /// Mirrors alt-tab Window.close() (Window.swift:163-189) minus the fullscreen special-case, plus a
    /// sheet-detection poll: a "Do you want to save?" dialog must be surfaced, not silently stranded.
    func close(completion: @escaping (CloseOutcome) -> Void) {
        AXQueue.shared.async { [axElement] in
            var closeButton: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axElement, kAXCloseButtonAttribute as CFString, &closeButton)
            guard err == .success, let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() else {
                DispatchQueue.main.async { completion(.closed) } // nothing to press ⇒ treat as gone
                return
            }
            // swiftlint:disable:next force_cast
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            WindowInfo.pollAfterClose(axElement, attempt: 0, completion: completion)
        }
    }

    /// After pressing close, the app either destroys the window or attaches a modal sheet (unsaved
    /// changes, "close all tabs?", a running-process warning, …). Poll a few times for that sheet; if it
    /// appears the close is blocked and the caller should surface the window. Runs on the AXQueue,
    /// delaying between attempts via a main hop so it never busy-blocks the serial queue.
    private static func pollAfterClose(_ window: AXUIElement, attempt: Int,
                                       completion: @escaping (CloseOutcome) -> Void) {
        let maxAttempts = 6
        // Window element gone ⇒ it really closed.
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
            DispatchQueue.main.async { completion(.closed) }
            return
        }
        if hasBlockingSheet(window) {
            DispatchQueue.main.async { completion(.needsAttention) }
            return
        }
        guard attempt < maxAttempts else {
            DispatchQueue.main.async { completion(.closed) } // no sheet appeared ⇒ assume closed/closing
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            AXQueue.shared.async { pollAfterClose(window, attempt: attempt + 1, completion: completion) }
        }
    }

    /// True if the window currently hosts a modal sheet — the AX role macOS gives "Save changes?" et al.
    private static func hasBlockingSheet(_ window: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return false }
        for kid in kids {
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(kid, kAXRoleAttribute as CFString, &r) == .success,
               (r as? String) == (kAXSheetRole as String) { return true }
        }
        return false
    }
}

extension WindowInfo: Equatable, Hashable {
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.cgWindowId == rhs.cgWindowId }
    func hash(into hasher: inout Hasher) { hasher.combine(cgWindowId) }
}
