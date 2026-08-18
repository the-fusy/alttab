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
    /// Monotonic counter of front changes (app activation, or our own commit). Any async work kicked
    /// off by ONE front change captures its value and re-checks it on the main hop: a mismatch means
    /// the front has moved on and the in-flight answer describes the past. See noteActivated.
    private var frontEpoch: Int64 = 0

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

        // App activation → bump the newly-front app's window (event-driven MRU backbone).
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.noteActivated(pid: app.processIdentifier)
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
        tearDownApp(pid: app.processIdentifier)
    }

    /// Forget an app entirely: observer, icon, debounce state and every window it owned.
    private func tearDownApp(pid: pid_t) {
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
            let cg = Self.rasterizeIcon(nsIcon)
            DispatchQueue.main.async {
                guard let cg else { return }
                self.iconCache[pid] = cg
                for w in self.windows where w.pid == pid && w.icon == nil { w.icon = cg }
            }
        }
    }

    /// Tahoe's `app.icon` is an HDR Liquid Glass render (extended sRGB, specular > 1.0) sitting
    /// on a translucent chiclet — that rim blooms on the sides of the tile. Prefer the unmasked
    /// Icon Services asset, then flatten to 8-bit sRGB so NSImageView cannot re-bloom it.
    private static func rasterizeIcon(_ image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        if let unmasked = IconServicesSPI.unmaskedCGImage(from: image) {
            return flattenToSRGB(unmasked) ?? unmasked
        }
        return flattenNSImage(image)
    }

    private static func flattenToSRGB(_ cg: CGImage, pixelSize: Int = 256) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return ctx.makeImage()
    }

    private static func flattenNSImage(_ image: NSImage, pixelSize: Int = 256) -> CGImage? {
        var proposed = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let src = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        return flattenToSRGB(src) ?? src
    }

    // MARK: - MRU

    /// Called when a window gains focus (from AppObserver or app activation). Main thread. `pid` is the
    /// owning app when the caller knows it (focus/activation events always do) — used to self-heal a
    /// missed window if the wid is unknown.
    func noteFocused(wid: CGWindowID, pid: pid_t = 0) {
        guard let w = byWindowId[wid] else {
            selfHealIfUnknown(wid: wid, pid: pid)
            return
        }
        // Only retire cold-start z-order seeding once a focus event is actually APPLIED to a tracked
        // window — early focus events for not-yet-enumerated windows must not suppress seeding.
        userFocusObserved = true
        mruCounter &+= 1
        w.mruStamp = mruCounter
        Log.store.debug("MRU bump wid=\(wid, privacy: .public) (\(w.appName, privacy: .public) – \(w.title, privacy: .public)) → \(self.mruCounter, privacy: .public)")
    }

    /// The switcher just committed focus to `wid`. Stamp the time and do the optimistic MRU-0 bump, so
    /// the NEXT summon's alignFrontmostWindow trusts THIS order over a frontmostApplication that still
    /// lags (our SLPS focus path fronts the window asynchronously — see Focus.swift). Passing the pid
    /// also lets the self-heal run if the committed window was momentarily dropped from the store.
    func noteCommitted(wid: CGWindowID, pid: pid_t) {
        // A commit IS a front change, and the authoritative one: it invalidates every AX focus read
        // still queued for the app we are leaving, whose answers would otherwise land after this bump
        // and push a window the user never chose to MRU index 1.
        frontEpoch &+= 1
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

    /// Synchronously enumerate the FRONTMOST app's current-Space windows and add any we don't track yet,
    /// so a window just opened in an app that doesn't emit a reliable kAXWindowCreatedNotification
    /// (some apps recreate their window on open, with a new wid, and their AXObserver often stays
    /// silent) is present on the FIRST Cmd+Tab instead of a summon late. Called on the main thread at
    /// summon, right before the display snapshot.
    ///
    /// Doing AX IPC on the main thread is normally forbidden here (a hung app would freeze the panel and
    /// the event tap), but this is the ONE safe place: the FRONTMOST app is by definition active, so its
    /// AX answers promptly — and a short per-element messaging timeout caps the worst case. Gated to run
    /// ONLY when the frontmost app owns no tracked window (the just-opened-first-window race), so the
    /// common summon pays nothing. A window opened in an app that ALREADY has a tracked window still
    /// appears one summon late — acceptable, since the summon already has a valid target to show.
    ///
    /// Returns whether the frontmost app is definitively WINDOWLESS: its AX answered and it owns no
    /// eligible window at all (you just closed its last one with Cmd+W). The caller needs that
    /// to read the snapshot correctly: "front app owns no tracked window" otherwise means "it has one we
    /// haven't enumerated yet", and the two want opposite first-press targets (see SwitcherController).
    @discardableResult
    func ensureFrontmostAppTracked() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        guard pid > 0, pid != myPid, isEligibleApp(app),
              !windows.contains(where: { $0.pid == pid }) else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1) // bound the main-thread stall if the app hangs
        let appName = app.localizedName ?? ""
        let (elements, axAnswered) = appElement.currentSpaceWindows()
        for el in elements {
            AXUIElementSetMessagingTimeout(el, 0.1)
            guard let wid = el.windowId(), wid != 0, byWindowId[wid] == nil else { continue }
            let attrs = readWindowAttrs(el)
            guard isEligibleWindow(attrs) else { continue }
            mruCounter &+= 1
            let w = WindowInfo(cgWindowId: wid, pid: pid, axElement: el,
                               title: attrs.title ?? "", appName: appName,
                               icon: iconCache[pid], mruStamp: mruCounter)
            windows.append(w)
            byWindowId[wid] = w
            Log.store.debug("sync-added frontmost \(appName, privacy: .public) – \(attrs.title ?? "", privacy: .public) [wid \(wid)] on summon")
        }
        // Windowless only if the app ANSWERED and still owns nothing: an AX failure enumerates as zero
        // windows too, and calling that "windowless" would skip a step on every summon into a hung app.
        return axAnswered && !windows.contains(where: { $0.pid == pid })
    }

    /// Synchronously drop the FRONTMOST app's ghost windows — a window it closed without the
    /// WindowServer destroying the record (some apps do this on Cmd+W) — right before the display snapshot.
    ///
    /// Why this can't wait for the async reconcile: closing a window emits no reliable AX signal
    /// (some apps send no kAXUIElementDestroyed), so the ghost is discovered only by the summon-time
    /// reconcileAllApps — which runs AFTER `sortedForDisplay()` froze the snapshot. The ghost would
    /// therefore be shown for one full summon after every close: exactly the "I hit Cmd+W and the app is
    /// still in the switcher, but selecting it does nothing" report.
    ///
    /// Cheap and AX-free: the ghost signature (not ordered on-screen AND on no Space) is read from the
    /// WindowServer, never from the app, so no hung app can stall the main thread. The expensive
    /// CGWindowList call is made ONLY when a Space query already flagged a candidate, which for the
    /// common summon is never. Restricted to the frontmost app ON PURPOSE: it is by definition active,
    /// so its AX is alive and "the app closed this window" is the only reading left — the same
    /// `axAnswered` gate reconcileApp applies, obtained for free. Background apps keep going through
    /// reconcile, which can afford to ask their AX off-main.
    func dropFrontmostGhostWindows() {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPid != myPid else { return }
        let tracked = windows.filter { $0.pid == frontPid }
        guard !tracked.isEmpty else { return }
        // Spaces first (one cheap WindowServer call per window, and the front app owns few).
        let candidates = tracked.filter { Self.spaces(of: [$0.cgWindowId]).isEmpty }
        guard !candidates.isEmpty else { return }
        let onscreen = Self.onscreenWindowIds()
        guard !onscreen.isEmpty else { return } // CG failure ⇒ liveness unknown ⇒ drop nothing
        let ghosts = candidates.filter { !onscreen.contains($0.cgWindowId) }
        guard !ghosts.isEmpty else { return }
        Log.store.log("summon: dropping \(ghosts.count) ghost window(s) of front app \(ghosts[0].appName, privacy: .public): \(ghosts.map { "\($0.title)#\($0.cgWindowId)" }.joined(separator: " | "), privacy: .public)")
        removeWindows(ghosts)
    }

    /// A focus/activation signal landed on a window we don't track yet: its kAXWindowCreatedNotification
    /// was missed (the per-app observer races app launch, and some apps never emit it reliably), so the
    /// ONLY thing that would discover it is a summon-time reconcile — which runs AFTER the session
    /// snapshot, leaving the window one summon behind ("shows up only after the first Cmd+Tab"). Enumerate
    /// the owning app NOW, off this reliable signal — but debounce per pid: a window AltTab never tracks
    /// (ineligible subrole/size) keeps this wid unknown forever, so an un-debounced reconcile would
    /// re-fire on every focus event for it. Touches no MRU state, which is what lets a focus answer that
    /// is too STALE to bump (see bumpFocusedWindow) still be worth acting on for discovery.
    private func selfHealIfUnknown(wid: CGWindowID, pid: pid_t) {
        guard byWindowId[wid] == nil, pid > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastSelfHealByPid[pid] ?? 0) > selfHealDebounce else { return }
        lastSelfHealByPid[pid] = now
        reconcileApp(pid: pid)
    }

    /// An app just became frontmost. `NSWorkspace` delivers this synchronously on the main thread, so
    /// the ORDER of activations is known exactly here — while the AX read that names the focused
    /// *window* is not: it goes through the serial AXQueue, which trails the user by seconds whenever a
    /// single unresponsive app makes every block sit out the 1s messaging timeout (see reconcileApp's
    /// slow-AX log). Applying those answers as they trickle in re-ordered MRU behind the user's back —
    /// a Cmd+Tab tapped seconds later landed on a window that merely happened to have the last late
    /// bump, the "flips between the last and the one before that" report. So:
    ///   • bump the app's most-recently-used window NOW, from the model alone — no AX, no queue hop.
    ///     That is the same "which window of this app is current" guess alignFrontmostWindow already
    ///     makes at summon, and it is right for every single-window app.
    ///   • ask AX which window actually holds the focus only to REFINE that guess (multi-window apps),
    ///     and apply the answer only while it is still current (the frontEpoch gate below).
    func noteActivated(pid: pid_t) {
        frontEpoch &+= 1
        if let top = windows.filter({ $0.pid == pid }).max(by: { $0.mruStamp < $1.mruStamp }) {
            noteFocused(wid: top.cgWindowId, pid: pid)
        }
        bumpFocusedWindow(ofPid: pid, epoch: frontEpoch)
    }

    /// Apply an AX-derived focus signal ONLY while the owning app is still frontmost. Background apps
    /// fire focused/main-window-changed of their own accord, and a queued AX read can land long after
    /// the user has moved on; either way the bump would corrupt "current window = MRU index 0".
    func noteFocusedIfFrontmost(wid: CGWindowID, pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        noteFocused(wid: wid, pid: pid)
    }

    private func bumpFocusedWindow(ofPid pid: pid_t, epoch: Int64) {
        let appElement = AXUIElementCreateApplication(pid)
        AXQueue.shared.async {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(),
                  // swiftlint:disable:next force_cast
                  let wid = (f as! AXUIElement).windowId() else { return }
            DispatchQueue.main.async {
                // Stale-answer gate. This read was started for ONE front change; if the front has moved
                // on since (another activation, or our own commit), the answer describes the past.
                guard self.frontEpoch == epoch else {
                    Log.store.debug("stale focus bump dropped: pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) epoch \(epoch, privacy: .public) ≠ \(self.frontEpoch, privacy: .public)")
                    // Stale for MRU purposes, still valid as DISCOVERY: the window it names may be one we
                    // never enumerated, and noteFocused's self-heal is what normally finds those. Dropping
                    // the whole answer would leave such a window to be found a summon later.
                    self.selfHealIfUnknown(wid: wid, pid: pid)
                    return
                }
                self.noteFocused(wid: wid, pid: pid)
            }
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
    /// `onscreen` + `currentSpaces` back the ordered-out cull (see reconcileApp); currentSpaces empty
    /// ⇒ Space info unavailable this sweep ⇒ the cull is skipped (conservative, drops no off-Space windows).
    private final class ExistenceSnapshot {
        var wids: Set<CGWindowID>?
        var onscreen: Set<CGWindowID> = []
        var currentSpaces: Set<Int> = []
    }

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

    /// The window ids currently ORDERED ON-SCREEN (any current-Space display; occluded still counts —
    /// kCGWindowIsOnscreen means "ordered in", not "visible"). Used to derive the current Space set and
    /// to spare a visible-but-AX-invisible window from the ordered-out cull. [] = the CG call failed.
    private static func onscreenWindowIds() -> Set<CGWindowID> {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(infos.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// The set of Space ids that host ANY of `wids` (mask 0x7 = all Spaces). The result is a UNION over
    /// the input, not a per-window map — so pass a SINGLE wid to learn one window's Spaces, or the whole
    /// on-screen set to learn "which Spaces are current". [] = no Space (a WindowServer ghost) or the
    /// query failed. Normally called off the main thread with the other reconcile reads; the summon-time
    /// ghost cull (dropFrontmostGhostWindows) calls it on MAIN, which is safe precisely because this is a
    /// WindowServer IPC and not an AX one — no third-party app is on the other end to hang us.
    private static func spaces(of wids: [CGWindowID]) -> Set<Int> {
        guard !wids.isEmpty else { return [] }
        let arr = wids.map { NSNumber(value: $0) } as CFArray
        guard let res = CGSCopySpacesForWindows(_CGSDefaultConnection(), 0x7, arr) as? [NSNumber] else { return [] }
        return Set(res.map { $0.intValue })
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
        AXQueue.shared.async {
            snapshot.wids = Self.allWindowIds()
            snapshot.onscreen = Self.onscreenWindowIds()
            snapshot.currentSpaces = Self.spaces(of: Array(snapshot.onscreen))
        }
        for (pid, _) in observers { reconcileApp(pid: pid, existence: snapshot) }
    }

    private func reconcileApp(pid: pid_t, existence: ExistenceSnapshot? = nil) {
        // Never query a pid that is no longer a running application. `appQuit` normally retires those off
        // NSWorkspace's runningApplications KVO, but that signal is NOT guaranteed for everything we
        // track: MEASURED, a third-party app's WebKit helper process disappeared without one and left
        // its observer behind, so every summon re-queried a dead pid — which answers nothing and
        // therefore sits out the FULL 1s AX messaging timeout on the SERIAL AXQueue, delaying every real
        // app queued behind it (48 such stalls in a 60-summon session; see the slow-AX log below). The
        // check lives here rather than in a separate sweep so it also covers the self-heal path, and it
        // is self-correcting: a false negative just re-adds the app on the next reconcileAllApps.
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            if observers[pid] != nil {
                Log.store.log("dropping observer for pid \(pid, privacy: .public) — no longer a running application (no NSWorkspace quit signal arrived)")
            }
            tearDownApp(pid: pid)
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let appName = app.localizedName ?? ""
        // Snapshot the app's tracked wids HERE (still on the main thread, before the AXQueue hop) so the
        // ordered-out classification below runs entirely off-main. Stale-by-the-time-we-apply is fine:
        // applyReconcile re-derives `absent` from the live store and only intersects it with this set.
        let trackedWids = windows.filter { $0.pid == pid }.map { $0.cgWindowId }
        AXQueue.shared.async {
            let existing = existence?.wids ?? Self.allWindowIds()
            let onscreen = existence?.onscreen ?? Self.onscreenWindowIds()
            let currentSpaces = existence?.currentSpaces ?? Self.spaces(of: Array(onscreen))
            // Enumerate FIRST: whether the app's AX answered gates the no-Space cull below.
            let axStart = ProcessInfo.processInfo.systemUptime
            let (elements, axAnswered) = appElement.currentSpaceWindows()
            // AXQueue is serial: one app that answers slowly (or not at all — the global messaging
            // timeout is 1s) delays every block behind it, and a summon enqueues one block per app. That
            // backlog no longer corrupts MRU (bumps are gated on frontEpoch), but it does delay window
            // discovery — so name the culprit instead of leaving it to be inferred from timestamps.
            let axElapsed = ProcessInfo.processInfo.systemUptime - axStart
            if axElapsed > 0.5 {
                Log.store.log("slow AX: \(appName, privacy: .public) [pid \(pid, privacy: .public)] took \(String(format: "%.2f", axElapsed), privacy: .public)s to enumerate windows (answered=\(axAnswered, privacy: .public)) — stalls the serial AXQueue")
            }
            // Ghost cull. An app that closes a window without destroying its WindowServer record leaves a
            // tracked window that the plain existence oracle never drops (a stock macOS app does exactly this on
            // Cmd+W; so does an AX-DEAD app like a backgrounded Electron-style one, whose kAXWindows returns
            // kAXErrorCannotComplete so ALL its windows look "absent from the current Space"). Two ghost
            // signatures, both requiring the window to NOT be ordered on-screen:
            //   • assigned to the CURRENT Space (spaces ⊆ currentSpaces, non-empty) — ordered out where we
            //     can see it ⇒ dead. A healthy app keeps even its ordered-out windows in kAXWindows, so
            //     this only bites an AX-dead app's leftover.
            //   • assigned to NO Space (spaces=[]) — the WindowServer still lists the id but places it
            //     nowhere. MEASURED (macOS 26): every live state keeps its Space id — ordered-out,
            //     minimized-to-Dock and app-hidden (Cmd+H) windows all report the Space they sit on, and
            //     another Space keeps a non-current id. Only a closed-but-not-destroyed window reports [].
            //     Gated on `axAnswered`: with a DEAD AX we cannot tell "closed" from "app not answering",
            //     so we keep sparing it (that is how a "close-to-tray" app may park a background window).
            // A window on ANOTHER Space keeps a non-current id and is spared by both rules. currentSpaces
            // empty ⇒ Space info unavailable ⇒ leave the sets nil so the cull is skipped and we never
            // over-drop.
            var orderedOutDead: Set<CGWindowID>?
            var noSpaceDead: Set<CGWindowID>?
            if !currentSpaces.isEmpty {
                var orderedOut = Set<CGWindowID>(), noSpace = Set<CGWindowID>()
                for wid in trackedWids where !onscreen.contains(wid) { // ordered on-screen ⇒ alive
                    let sp = Self.spaces(of: [wid])
                    if sp.isEmpty {
                        if axAnswered { noSpace.insert(wid) }
                    } else if sp.allSatisfy({ currentSpaces.contains($0) }) {
                        orderedOut.insert(wid)
                    }
                }
                orderedOutDead = orderedOut
                noSpaceDead = noSpace
            }
            var live: [(CGWindowID, AXUIElement, WindowAttrs)] = []
            for el in elements {
                guard let wid = el.windowId(), wid != 0 else { continue }
                let attrs = readWindowAttrs(el)
                guard isEligibleWindow(attrs) else { continue }
                live.append((wid, el, attrs))
            }
            DispatchQueue.main.async {
                self.applyReconcile(pid: pid, live: live, existing: existing,
                                    orderedOutDead: orderedOutDead, noSpaceDead: noSpaceDead,
                                    appName: appName)
            }
        }
    }

    private func applyReconcile(pid: pid_t, live: [(CGWindowID, AXUIElement, WindowAttrs)],
                                existing: Set<CGWindowID>?, orderedOutDead: Set<CGWindowID>?,
                                noSpaceDead: Set<CGWindowID>?, appName: String) {
        // The app can quit between the AXQueue read and this main-thread apply; appQuit has already
        // torn down its observer and removed its windows — adding `live` back would resurrect them.
        guard observers[pid] != nil else { return }
        let liveWids = Set(live.map { $0.0 })
        // kAXWindows covers the CURRENT Space only, so "absent from it" is NOT "closed": windows on
        // other Spaces (e.g. a fullscreen-video Space) must survive a reconcile run from elsewhere —
        // dropping them used to gut the model and erase MRU history whenever a summon happened on
        // another Space. A tracked window is dead when the WindowServer no longer lists it at all
        // (`gone`), or when it is still listed but carries a ghost signature: ordered out on the CURRENT
        // Space (`orderedOut`), or on NO Space at all with the app's AX answering (`noSpace` — the
        // closed-but-not-destroyed window; see reconcileApp). With no existence info (CG failure) we drop
        // nothing and rely on kAXUIElementDestroyed; with no Space info both ghost sets are nil and only
        // the `gone` rule fires.
        let absent = windows.filter { $0.pid == pid && !liveWids.contains($0.cgWindowId) }
        let listed = absent.filter { existing?.contains($0.cgWindowId) == true }
        let gone = absent.filter { existing?.contains($0.cgWindowId) == false }
        let orderedOut = listed.filter { orderedOutDead?.contains($0.cgWindowId) == true }
        let noSpace = listed.filter { noSpaceDead?.contains($0.cgWindowId) == true }
        let dead = gone + orderedOut + noSpace
        if absent.count > dead.count {
            Log.store.debug("reconcile \(appName, privacy: .public): keeping \(absent.count - dead.count) off-Space window(s)")
        }
        if !dead.isEmpty {
            Log.store.log("reconcile \(appName, privacy: .public): dropping \(dead.count) window(s) [\(gone.count) gone, \(orderedOut.count) ordered-out, \(noSpace.count) no-Space]: \(dead.map { "\($0.title)#\($0.cgWindowId)" }.joined(separator: " | "), privacy: .public)")
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
