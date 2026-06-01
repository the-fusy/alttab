//
//  HotkeyManager.swift
//  AltTab
//
//  The Cmd+Tab override + session input. Two inputs:
//    (a) Carbon RegisterEventHotKey for Cmd+Tab — the initial trigger AND every forward cycle while Cmd
//        stays held (re-fires on each Tab press; needs no Accessibility permission itself).
//    (b) A CGEventTap (background run-loop thread) watching .flagsChanged (Cmd RELEASE = commit; while a
//        session is up, a Shift DOWN-edge = step backward one) and .keyDown (Esc = cancel, absorbed while
//        a session is active). Handling Esc in the tap — rather than an NSEvent local monitor — works
//        reliably even though our panel is non-activating.
//

import Cocoa
import Carbon.HIToolbox
import os

// MARK: - Session interface (implemented by SwitcherController; @MainActor).
@MainActor
protocol SwitcherSessionControlling: AnyObject {
    var isActive: Bool { get }
    func summonOrCycleForward()   // Cmd+Tab: first press summons (index 1 preselected), again cycles next
    func cycleBackward()          // Cmd+Shift: Shift tapped while the session is up → step back one
    func commit()                 // Cmd released → focus highlighted tile
    func cancel()                 // Esc
}

// MARK: - Carbon hotkey IDs.
private enum HotkeyID: UInt32 { case next = 1 }
private let kSignature: OSType = 0x416C_5462 // 'AlTb'

// MARK: - Background run-loop thread hosting the CGEventTap.
final class RunLoopThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        self.qualityOfService = .userInteractive
        start()
        ready.wait() // block until runLoop is initialized
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        var ctx = CFRunLoopSourceContext()
        ctx.perform = { _ in }
        CFRunLoopAddSource(runLoop, CFRunLoopSourceCreate(nil, 0, &ctx), .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Set once at startup. Its (main-actor-isolated) methods are only called from `Task { @MainActor }`.
    weak var session: SwitcherSessionControlling?

    /// Nonisolated mirror of session.isActive, so the event-tap callback can decide synchronously
    /// (on its background thread) whether to absorb Esc. Lock-guarded because it is WRITTEN on the main
    /// thread (SwitcherController.begin/end) and READ on the CGEventTap's background thread: a plain Bool
    /// would be a data race (no happens-before edge, and the compiler could hoist/cache the read).
    private let _sessionActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    var sessionActive: Bool {
        get { _sessionActive.withLock { $0 } }
        set { _sessionActive.withLock { $0 = newValue } }
    }

    private static var eventTap: CFMachPort?
    private let tapThread = RunLoopThread(name: "dev.fusy.alttab.inputEvents")
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyHandler: EventHandlerRef?

    private init() {}

    /// Call AFTER permissions resolve. Order: register hotkeys → install tap → disable native Cmd+Tab.
    func start(session: SwitcherSessionControlling) {
        self.session = session
        installCarbonHotkeys()
        installEventTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil)
        NativeCmdTab.disable()
    }

    // MARK: - (a) Carbon hotkey: Cmd+Tab (forward).
    // kEventHotKeyNoOptions lets the hotkey re-fire on each Tab press while Cmd stays held, so the
    // single hotkey drives both summon and forward cycling. (Backward is Cmd+Shift, handled in the tap.)
    private func installCarbonHotkeys() {
        let target = GetEventDispatcherTarget() // works without Accessibility
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            Task { @MainActor in HotkeyManager.shared.session?.summonOrCycleForward() }
            return noErr
        }
        InstallEventHandler(target, handler, 1, &spec, nil, &hotKeyHandler)
        register(.next, keyCode: UInt32(kVK_Tab), mods: UInt32(cmdKey), target: target)
    }

    private func register(_ id: HotkeyID, keyCode: UInt32, mods: UInt32, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: kSignature, id: id.rawValue)
        RegisterEventHotKey(keyCode, mods, hkID, target, UInt32(kEventHotKeyNoOptions), &ref)
        hotKeyRefs.append(ref)
    }

    // MARK: - (b) CGEventTap: Cmd RELEASE = commit (flagsChanged), Esc = cancel (keyDown).
    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            switch type {
            case .flagsChanged:
                // Never absorb modifier events — the previously-focused app must still see them.
                let flags = event.flags
                if !flags.contains(.maskCommand) {
                    // Cmd released → commit the highlighted tile.
                    Task { @MainActor in
                        guard let s = HotkeyManager.shared.session, s.isActive else { return }
                        s.commit()
                    }
                } else if HotkeyManager.shared.sessionActive, flags.contains(.maskShift) {
                    // Cmd still held + Shift now present. Gate on the keycode so ONLY the Shift key's own
                    // transition fires this (not another modifier changing while Shift happens to be held),
                    // which — together with flagsChanged having no key-repeat — makes each physical Shift
                    // tap step back exactly one. Cmd+Shift replaces the old Cmd+Shift+Tab.
                    let kc = event.getIntegerValueField(.keyboardEventKeycode)
                    if kc == Int64(kVK_Shift) || kc == Int64(kVK_RightShift) {
                        Task { @MainActor in
                            guard let s = HotkeyManager.shared.session, s.isActive else { return }
                            s.cycleBackward()
                        }
                    }
                }
            case .keyDown:
                if HotkeyManager.shared.sessionActive,
                   event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                    Task { @MainActor in HotkeyManager.shared.session?.cancel() }
                    return nil // absorb Esc so the foreground app doesn't also receive it
                }
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = HotkeyManager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        // .defaultTap (not listenOnly) so we can absorb Esc. Requires Accessibility (already granted).
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else {
            NSLog("AltTab: failed to create event tap (Accessibility not granted?)")
            return
        }
        HotkeyManager.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(tapThread.runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Robustness.
    @objc private func onWake() {
        reEnableTapIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reEnableTapIfNeeded() }
    }

    func reEnableTapIfNeeded() {
        guard let tap = HotkeyManager.eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        for ref in hotKeyRefs { if let ref { UnregisterEventHotKey(ref) } }
        hotKeyRefs.removeAll()
        if let h = hotKeyHandler { RemoveEventHandler(h); hotKeyHandler = nil }
        if let tap = HotkeyManager.eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        NativeCmdTab.restore()
    }
}
