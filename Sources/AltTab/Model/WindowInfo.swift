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

    /// Press the window's close button (the tile's ✕). Runs off-main.
    /// Mirrors alt-tab Window.close() (Window.swift:163-189) minus the fullscreen special-case.
    func close() {
        AXQueue.shared.async { [axElement] in
            var closeButton: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axElement, kAXCloseButtonAttribute as CFString, &closeButton)
            if err == .success, let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() {
                // swiftlint:disable:next force_cast
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }
}

extension WindowInfo: Equatable, Hashable {
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.cgWindowId == rhs.cgWindowId }
    func hash(into hasher: inout Hasher) { hasher.combine(cgWindowId) }
}
