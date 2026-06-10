//
//  WindowStore.swift
//  AltTab
//
//  The live model of every standard window seen on ANY Space, kept up to date by
//  NSWorkspace KVO (app launch/quit) + per-app AX observers, and ordered by per-window MRU.
//  kAXWindows can only ENUMERATE current-Space windows, so a window seen once stays tracked when
//  its Space goes to the background; liveness comes from the WindowServer (CGWindowList, all
//  Spaces), NOT from kAXWindows absence — see applyReconcile.
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
    /// Debounce for the focus-driven self-heal reconcile, keyed per pid (uptime seconds). reconcileApp
    /// is otherwise UNthrottled, so a focus/activation event naming a window AltTab will never track
    /// (non-standard subrole or sub-24px — filtered by isEligibleWindow) would re-fire a full AX
    /// enumeration on EVERY such event; this caps it to one sweep per app per 0.25s. Keyed per pid (not
    /// per wid) ON PURPOSE: per-wid would re-open the unbounded fan-out when an app ping-pongs focus
    /// between distinct ineligible windows, and would grow without bound (we get no destroy events for
    /// windows we don't track). The cost is that a genuinely-new eligible window in an app that also has
    /// a "hot" ineligible window can be discovered up to one debounce window late — harmless, since
    /// reconcileApp enumerates ALL the app's windows and the summon-time reconcileAllApps is a backstop.
    private var lastSelfHealByPid: [pid_t: TimeInterval] = [:]
    /// Uptime of the last switcher commit, and the app that was frontmost AT that moment (the app we
    /// switched away FROM). Right after a commit our optimistic MRU-0 (set in noteCommitted) is
    /// authoritative while frontmostApplication still lags (Focus fronts the window asynchronously via
    /// SLPS) and keeps reporting the from-app. alignFrontmostWindow uses BOTH to suppress realignment
    /// ONLY in that stale window — keyed on the from-app so a genuine switch to a third app is NOT
    /// suppressed (see alignFrontmostWindow).
    private var lastCommitUptime: TimeInterval = 0
    private var lastCommitFromPid: pid_t = 0
    private let selfHealDebounce: TimeInterval = 0.25

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
        lastSelfHealByPid[pid] = nil
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

    /// Called when a window gains focus (from AppObserver or app activation). Main thread. `pid` is the
    /// owning app when the caller knows it (focus/activation events always do) — used to self-heal a
    /// missed window if the wid is unknown.
    func noteFocused(wid: CGWindowID, pid: pid_t = 0) {
        guard let w = byWindowId[wid] else {
            // Focus/activation landed on a window we don't track yet: its kAXWindowCreatedNotification
            // was missed (the per-app observer races app launch, and some apps never emit it reliably),
            // so the ONLY thing that would discover it is a summon-time reconcile — which runs AFTER the
            // session snapshot, leaving the window one summon behind ("shows up only after the first
            // Cmd+Tab"). Self-heal by enumerating the owning app NOW, off this reliable focus signal —
            // but debounce per pid: a window AltTab never tracks (ineligible subrole/size) keeps this wid
            // unknown forever, so an un-debounced reconcile would re-fire on every focus event for it.
            let now = ProcessInfo.processInfo.systemUptime
            if pid > 0, now - (lastSelfHealByPid[pid] ?? 0) > selfHealDebounce {
                lastSelfHealByPid[pid] = now
                reconcileApp(pid: pid)
            }
            return
        }
        // Only retire cold-start z-order seeding once a focus event is actually APPLIED to a tracked
        // window — early focus events for not-yet-enumerated windows must not suppress seeding.
        userFocusObserved = true
        mruCounter &+= 1
        w.mruStamp = mruCounter
    }

    /// The switcher just committed focus to `wid`. Stamp the time and do the optimistic MRU-0 bump, so
    /// the NEXT summon's alignFrontmostWindow trusts THIS order over a frontmostApplication that still
    /// lags (our SLPS focus path fronts the window asynchronously — see Focus.swift). Passing the pid
    /// also lets the self-heal run if the committed window was momentarily dropped from the store.
    func noteCommitted(wid: CGWindowID, pid: pid_t) {
        lastCommitUptime = ProcessInfo.processInfo.systemUptime
        // The app frontmost right now (the panel is non-activating, and Focus hasn't fronted the target
        // yet) is the app we're switching away from — the one a lagging frontmostApplication will keep
        // reporting until our SLPS commit propagates.
        lastCommitFromPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        noteFocused(wid: wid, pid: pid)
    }

    /// Realign MRU to whatever app is frontmost RIGHT NOW. Called synchronously at summon. The MRU
    /// backbone is entirely event-driven (app-activated / focused-window-changed / window-created), and
    /// every one of those hops through the AXQueue and a main-thread async — so a Cmd+Tab fired right
    /// after opening a window can outrun them, leaving the just-focused window either un-promoted or
    /// not-yet-enumerated. Either way the snapshot would wrongly treat the PREVIOUS app as the current
    /// one (and skip a step). `frontmostApplication` is maintained by the OS synchronously and needs no
    /// AX IPC, so it's a safe main-thread oracle for "what is actually current".
    ///
    /// Returns whether the frontmost app owns a tracked window: false ⇒ it was just opened and hasn't
    /// been enumerated yet, so the caller must treat the current MRU-0 as the *previous* window (land
    /// the first forward press ON it) rather than skipping past it.
    @discardableResult
    func alignFrontmostWindow() -> Bool {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPid != myPid else { return true } // unknown / our own front → leave the order as-is
        guard let top = windows.filter({ $0.pid == frontPid }).max(by: { $0.mruStamp < $1.mruStamp }) else {
            return false // frontmost app owns no tracked window yet — just opened, not enumerated
        }
        // Just after our OWN commit, frontmostApplication still lags our async SLPS focus and keeps
        // reporting the app we switched away FROM. Re-stamping THAT stale app would demote the window we
        // just committed to and re-select it — the A→B→A flip breaks. Suppress realignment only in that
        // exact case: a recent commit AND frontmost still == the from-app. Keying on the from-app (not
        // the committed app) is deliberate — the hazard IS frontmost reporting the previous app; a
        // genuine switch to a DIFFERENT app within the window is a real frontmost and must still realign.
        if frontPid == lastCommitFromPid, ProcessInfo.processInfo.systemUptime - lastCommitUptime < 0.3 {
            return true
        }
        if windows.contains(where: { $0.mruStamp > top.mruStamp }) {
            mruCounter &+= 1
            top.mruStamp = mruCounter
            userFocusObserved = true // a real realignment; don't let cold-start seeding clobber it
        }
        return true
    }

    private func bumpFocusedWindow(ofPid pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXQueue.shared.async {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(),
                  // swiftlint:disable:next force_cast
                  let wid = (f as! AXUIElement).windowId() else { return }
            DispatchQueue.main.async { self.noteFocused(wid: wid, pid: pid) }
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

    /// One CG existence snapshot shared by a whole reconcile sweep. Written, then read, ONLY on the
    /// serial AXQueue (the snapshot block is enqueued before the per-app blocks), so no lock needed.
    private final class ExistenceSnapshot { var wids: Set<CGWindowID>? }

    /// Every window the WindowServer currently knows about, across ALL Spaces (minimized included).
    /// The liveness oracle for reconcile: absence from kAXWindows only means "not on the current
    /// Space"; absence from THIS set means the window is really gone. nil = the CG call failed.
    private static func allWindowIds() -> Set<CGWindowID>? {
        guard let infos = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            // Degraded mode: liveness unknown, this pass drops nothing. Stale windows can linger
            // until the next successful snapshot (or an AX destroyed event) — keep it diagnosable.
            Log.store.error("CGWindowListCopyWindowInfo failed — liveness unknown, dropping nothing this pass")
            return nil
        }
        return Set(infos.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
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
        // ONE existence snapshot for the whole sweep — one WindowServer IPC instead of one per app.
        let snapshot = ExistenceSnapshot()
        AXQueue.shared.async { snapshot.wids = Self.allWindowIds() }
        for (pid, _) in observers { reconcileApp(pid: pid, existence: snapshot) }
    }

    private func reconcileApp(pid: pid_t, existence: ExistenceSnapshot? = nil) {
        let appElement = AXUIElementCreateApplication(pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        AXQueue.shared.async {
            let existing = existence?.wids ?? Self.allWindowIds()
            let elements = appElement.currentSpaceWindows()
            var live: [(CGWindowID, AXUIElement, WindowAttrs)] = []
            for el in elements {
                guard let wid = el.windowId(), wid != 0 else { continue }
                let attrs = readWindowAttrs(el)
                guard isEligibleWindow(attrs) else { continue }
                live.append((wid, el, attrs))
            }
            DispatchQueue.main.async { self.applyReconcile(pid: pid, live: live, existing: existing, appName: appName) }
        }
    }

    private func applyReconcile(pid: pid_t, live: [(CGWindowID, AXUIElement, WindowAttrs)],
                                existing: Set<CGWindowID>?, appName: String) {
        // The app can quit between the AXQueue read and this main-thread apply; appQuit has already
        // torn down its observer and removed its windows — adding `live` back would resurrect them.
        guard observers[pid] != nil else { return }
        let liveWids = Set(live.map { $0.0 })
        // kAXWindows covers the CURRENT Space only, so "absent from it" is NOT "closed": windows on
        // other Spaces (e.g. a fullscreen-video Space) must survive a reconcile run from elsewhere —
        // dropping them used to gut the model and erase MRU history whenever a summon happened on
        // another Space. A window is dead only when the WindowServer itself no longer lists it; with
        // no existence info (CG failure) we drop nothing and rely on kAXUIElementDestroyed.
        let absent = windows.filter { $0.pid == pid && !liveWids.contains($0.cgWindowId) }
        let dead = absent.filter { existing?.contains($0.cgWindowId) == false }
        if absent.count > dead.count {
            Log.store.debug("reconcile \(appName, privacy: .public): keeping \(absent.count - dead.count) off-Space window(s)")
        }
        if !dead.isEmpty {
            Log.store.log("reconcile \(appName, privacy: .public): dropping \(dead.count) window(s) gone from WindowServer: \(dead.map { "\($0.title)#\($0.cgWindowId)" }.joined(separator: " | "), privacy: .public)")
            removeWindows(dead)
        }
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
        Log.store.debug("AX created: \(appName, privacy: .public) – \(attrs.title ?? "", privacy: .public) [wid \(wid)]")
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
            Log.store.debug("AX destroyed: \(w.appName, privacy: .public) – \(w.title, privacy: .public) [wid \(w.cgWindowId)]")
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
