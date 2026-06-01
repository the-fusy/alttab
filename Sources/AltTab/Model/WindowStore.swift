//
//  WindowStore.swift
//  AltTab
//
//  The live model of every visible standard window on the current Space, kept up to date by
//  NSWorkspace KVO (app launch/quit) + per-app AX observers, and ordered by per-window MRU.
//
//  Threading contract: this object is NOT actor-isolated, but EVERY method must be called on the
//  MAIN THREAD. Background AX reads happen on the serial AXQueue and hop back via
//  `DispatchQueue.main.async` (FIFO) before touching any state here. Keeping it nonisolated (rather
//  than @MainActor) is what lets those FIFO main hops call in directly and preserve event order.
//

import Cocoa
import ApplicationServices

final class WindowStore: NSObject {
    static let shared = WindowStore()

    /// The model. Snapshot via `sortedForDisplay()` at show time.
    private(set) var windows: [WindowInfo] = []
    /// WID → window. Identity lookups + dead-window diffing during reconcile.
    private(set) var byWindowId: [CGWindowID: WindowInfo] = [:]

    private var observers: [pid_t: AppObserver] = [:]
    private var iconCache: [pid_t: CGImage] = [:]

    /// Monotonic MRU counter. Bumped on each focus; the focused window copies the new value.
    private var mruCounter: Int64 = 0
    /// Set once any real focus signal arrives, after which we stop z-order-seeding (so we never
    /// clobber genuine user activity during the cold-start seeding window).
    private var userFocusObserved = false
    /// Throttle for the per-summon reconcile sweep (uptime seconds; monotonic).
    private var lastReconcile: TimeInterval = 0

    private let myPid = getpid()
    private var appsKVO: NSKeyValueObservation?
    private var activateObserver: NSObjectProtocol?

    /// Track any process with a UI (regular OR accessory), excluding pure background daemons and
    /// ourselves. The per-window subrole/size filter (isEligibleWindow) discards junk windows, so a
    /// broad app filter is safe and avoids missing accessory apps that own real windows.
    private func isEligibleApp(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier > 0 && app.processIdentifier != myPid && app.activationPolicy != .prohibited
    }

    // MARK: - Lifecycle

    func start() {
        AXUIElement.setGlobalMessagingTimeout(1)
        AXRunLoopThread.shared.startAndWait()

        appsKVO = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let launched = change.newValue ?? []
            let quit = change.oldValue ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                for app in launched where self.isEligibleApp(app) { self.appLaunched(app) }
                for app in quit { self.appQuit(app) }
            }
        }

        // App activation → bump the newly-front app's focused window (event-driven MRU backbone).
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.bumpFocusedWindow(ofPid: app.processIdentifier)
        }

        for app in NSWorkspace.shared.runningApplications where isEligibleApp(app) { appLaunched(app) }
        // Cold-start MRU: enumeration is async, so seed on-screen z-order until windows arrive.
        seedZOrder(retriesLeft: 10)
    }

    func stop() {
        appsKVO?.invalidate(); appsKVO = nil
        if let activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(activateObserver) }
        activateObserver = nil
        for (_, obs) in observers { obs.tearDown() }
        observers.removeAll()
    }

    // MARK: - App launch / quit

    private func appLaunched(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, observers[pid] == nil else { return }
        cacheIcon(for: app)
        let observer = AppObserver(pid: pid, runningApp: app)
        observers[pid] = observer
        observer.setUp()
        reconcileApp(pid: pid) // initial windows send no created-notification
    }

    private func appQuit(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        observers[pid]?.tearDown()
        observers[pid] = nil
        iconCache[pid] = nil
        removeWindows(windows.filter { $0.pid == pid })
    }

    private func cacheIcon(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard iconCache[pid] == nil else { return }
        let nsIcon = app.icon
        AXQueue.shared.async {
            var proposed = CGRect(x: 0, y: 0, width: 128, height: 128)
            let cg = nsIcon?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            DispatchQueue.main.async {
                guard let cg else { return }
                self.iconCache[pid] = cg
                for w in self.windows where w.pid == pid && w.icon == nil { w.icon = cg }
            }
        }
    }

    // MARK: - MRU

    /// Called when a window gains focus (from AppObserver or app activation). Main thread.
    func noteFocused(wid: CGWindowID) {
        guard let w = byWindowId[wid] else { return }
        // Only retire cold-start z-order seeding once a focus event is actually APPLIED to a tracked
        // window — early focus events for not-yet-enumerated windows must not suppress seeding.
        userFocusObserved = true
        mruCounter &+= 1
        w.mruStamp = mruCounter
    }

    private func bumpFocusedWindow(ofPid pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXQueue.shared.async {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(),
                  // swiftlint:disable:next force_cast
                  let wid = (f as! AXUIElement).windowId() else { return }
            DispatchQueue.main.async { self.noteFocused(wid: wid) }
        }
    }

    /// Cold-start MRU seed: assign stamps from the on-screen front-to-back z-order (current Space),
    /// so the very first Cmd+Tab lands on the true previous window (index 1). Re-seeds every 200ms
    /// until either the model is populated and stable, retries run out, or a real focus event arrives
    /// (userFocusObserved) — after which event-driven MRU takes over and we must not clobber it.
    private func seedZOrder(retriesLeft: Int) {
        guard retriesLeft > 0, !userFocusObserved else { return }
        if !byWindowId.isEmpty,
           let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] {
            // infos is front-to-back; iterate reversed so the frontmost window gets the highest stamp.
            for info in infos.reversed() {
                guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let w = byWindowId[num] else { continue }
                mruCounter &+= 1
                w.mruStamp = mruCounter
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.seedZOrder(retriesLeft: retriesLeft - 1)
        }
    }

    // MARK: - Show-time API

    /// MRU-sorted snapshot for the panel. Most-recent first; ties broken by WID for stability.
    func sortedForDisplay() -> [WindowInfo] {
        windows.sorted { $0.mruStamp != $1.mruStamp ? $0.mruStamp > $1.mruStamp : $0.cgWindowId < $1.cgWindowId }
    }

    /// Re-enumerate tracked apps' current-Space windows (drop dead, add new) and pick up any
    /// newly-eligible app not yet tracked (e.g. one that transitioned to a UI policy after launch).
    /// Called on each summon; throttled so rapid summons don't stack fan-outs.
    func reconcileAllApps() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReconcile > 0.25 else { return }
        lastReconcile = now
        for app in NSWorkspace.shared.runningApplications where isEligibleApp(app) && observers[app.processIdentifier] == nil {
            appLaunched(app)
        }
        for (pid, _) in observers { reconcileApp(pid: pid) }
    }

    private func reconcileApp(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        AXQueue.shared.async {
            let elements = appElement.currentSpaceWindows()
            var live: [(CGWindowID, AXUIElement, WindowAttrs)] = []
            for el in elements {
                guard let wid = el.windowId(), wid != 0 else { continue }
                let attrs = readWindowAttrs(el)
                guard isEligibleWindow(attrs) else { continue }
                live.append((wid, el, attrs))
            }
            DispatchQueue.main.async { self.applyReconcile(pid: pid, live: live, appName: appName) }
        }
    }

    private func applyReconcile(pid: pid_t, live: [(CGWindowID, AXUIElement, WindowAttrs)], appName: String) {
        let liveWids = Set(live.map { $0.0 })
        let dead = windows.filter { $0.pid == pid && !liveWids.contains($0.cgWindowId) }
        if !dead.isEmpty { removeWindows(dead) }
        // `live` is front-to-back (kAXWindows order). Stamp NEW windows back-to-front so the front-most
        // window gets the highest stamp ⇒ sorts to index 0 — matching seedZOrder's z-order convention.
        for (wid, el, attrs) in live.reversed() {
            if let existing = byWindowId[wid] {
                if let t = attrs.title, !t.isEmpty { existing.title = t }
            } else {
                mruCounter &+= 1
                let w = WindowInfo(cgWindowId: wid, pid: pid, axElement: el,
                                   title: attrs.title ?? "", appName: appName,
                                   icon: iconCache[pid], mruStamp: mruCounter)
                windows.append(w)
                byWindowId[wid] = w
            }
        }
    }

    // MARK: - Mutation primitives (main thread)

    /// Add a single window discovered via kAXWindowCreatedNotification.
    func addWindow(pid: pid_t, element: AXUIElement, attrs: WindowAttrs) {
        guard isEligibleWindow(attrs), let wid = element.windowId(), wid != 0,
              byWindowId[wid] == nil else { return }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        mruCounter &+= 1
        let w = WindowInfo(cgWindowId: wid, pid: pid, axElement: element,
                           title: attrs.title ?? "", appName: appName,
                           icon: iconCache[pid], mruStamp: mruCounter)
        windows.append(w)
        byWindowId[wid] = w
    }

    func updateTitle(wid: CGWindowID, title: String?) {
        guard let w = byWindowId[wid], let title, !title.isEmpty else { return }
        w.title = title
    }

    /// Remove a window identified by its (possibly already-destroyed) AX element. Matching by element
    /// identity avoids the full reconcile that a failed windowId() lookup would otherwise force.
    func removeWindow(matching element: AXUIElement) {
        if let w = windows.first(where: { CFEqual($0.axElement, element) }) {
            removeWindows([w])
        } else {
            // Identity match missed (the element changed under us). Force an UN-throttled per-app sweep so
            // the dead window can't linger just because a summon reconcile ran <0.25s earlier.
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if pid > 0 { reconcileApp(pid: pid) } else { reconcileAllApps() }
        }
    }

    func removeWindow(wid: CGWindowID) {
        guard let w = byWindowId[wid] else { return }
        removeWindows([w])
    }

    private func removeWindows(_ toRemove: [WindowInfo]) {
        guard !toRemove.isEmpty else { return }
        let wids = Set(toRemove.map { $0.cgWindowId })
        windows.removeAll { wids.contains($0.cgWindowId) }
        for wid in wids { byWindowId[wid] = nil }
    }
}
