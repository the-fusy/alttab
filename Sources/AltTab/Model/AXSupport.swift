//
//  AXSupport.swift
//  AltTab
//
//  Low-level Accessibility helpers: a background queue + run-loop thread for cross-process AX IPC,
//  batched attribute reads, the AX→CGWindowID accessor, and the single window-eligibility filter.
//  (_AXUIElementGetWindow itself is declared in PrivateAPIs.swift.)
//

import Cocoa
import ApplicationServices

/// Single SERIAL background queue for ALL cross-process AX reads/commands. Serial (not concurrent)
/// so reads complete in submission order — that, plus FIFO `DispatchQueue.main.async` hops, keeps AX
/// events applied to the model in the order the OS delivered them (a concurrent queue could let a
/// window's "created" read finish after its "destroyed" read and resurrect a dead window). The 1s
/// AX messaging timeout (setGlobalMessagingTimeout) caps how long any single hung app can stall it.
final class AXQueue {
    static let shared = AXQueue()
    private let queue = DispatchQueue(label: "dev.fusy.alttab.ax", qos: .userInteractive)
    func async(_ work: @escaping () -> Void) { queue.async(execute: work) }
}

/// One background thread owning a CFRunLoop, so AXObserver sources have somewhere to fire.
/// Port of alt-tab BackgroundWork.BackgroundThreadWithRunLoop (BackgroundWork.swift:113-144),
/// reduced to a single instance (alt-tab runs four such threads).
final class AXRunLoopThread: Thread, @unchecked Sendable {
    static let shared = AXRunLoopThread()
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    func startAndWait() {
        guard runLoop == nil else { return }
        name = "com.wintab.axEvents"
        qualityOfService = .userInteractive
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A no-op source keeps CFRunLoopRun() alive until real observer sources are added.
        var ctx = CFRunLoopSourceContext()
        ctx.perform = { _ in }
        CFRunLoopAddSource(runLoop, CFRunLoopSourceCreate(nil, 0, &ctx), .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
}

extension AXUIElement {
    /// Set once at startup on the system-wide element. alt-tab uses 1s (AXUIElement.swift:13-16),
    /// down from the 6s default, so one unresponsive app can't block the AX queue for long.
    static func setGlobalMessagingTimeout(_ seconds: Float = 1) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// CGWindowID for a window element, or nil if AX can't resolve it (e.g. a stale element).
    func windowId() -> CGWindowID? {
        var id = CGWindowID(0)
        return _AXUIElementGetWindow(self, &id) == .success ? id : nil
    }

    /// The app's current-Space windows via kAXWindowsAttribute (AXUIElement.swift:139-150).
    /// We deliberately do NOT brute-force other-Space windows (AXUIElement.swift:153-176 DROPPED).
    func currentSpaceWindows() -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXWindowsAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        // macOS sometimes returns duplicate elements (e.g. Mail at login); dedupe while PRESERVING the
        // kAXWindows front-to-back order. `Array(Set:)` would randomize it, scrambling the per-app MRU
        // seeding so "previous window" (index 1) became arbitrary for any multi-window app.
        var seen = Set<AXUIElement>()
        return arr.filter { seen.insert($0).inserted }
    }
}

/// Result of one batched window-attribute read.
struct WindowAttrs {
    var title: String?
    var subrole: String?
    var size: CGSize?
}

/// Batched read of [title, subrole, size] in ONE IPC round-trip via
/// AXUIElementCopyMultipleAttributeValues (alt-tab AXUIElement.swift:64-93).
func readWindowAttrs(_ element: AXUIElement) -> WindowAttrs {
    let keys = [kAXTitleAttribute, kAXSubroleAttribute, kAXSizeAttribute] as CFArray
    var out = WindowAttrs()
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, keys, AXCopyMultipleAttributeOptions(), &values) == .success,
          let array = values as? [CFTypeRef] else { return out }
    if array.count > 0, CFGetTypeID(array[0]) == CFStringGetTypeID() { out.title = array[0] as? String }
    if array.count > 1, CFGetTypeID(array[1]) == CFStringGetTypeID() { out.subrole = array[1] as? String }
    if array.count > 2, CFGetTypeID(array[2]) == AXValueGetTypeID() {
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        if AXValueGetValue(array[2] as! AXValue, .cgSize, &size) { out.size = size }
    }
    return out
}

/// AltTab's single window filter: standard windows only, above a minimum size.
/// Replaces alt-tab's WindowDiscriminator.isActualWindow; without Spaces/minimize/level it's just this.
func isEligibleWindow(_ attrs: WindowAttrs) -> Bool {
    guard attrs.subrole == (kAXStandardWindowSubrole as String) else { return false }
    if let s = attrs.size, s.width < 24 || s.height < 24 { return false } // drop zero/tiny ghosts
    return true
}
