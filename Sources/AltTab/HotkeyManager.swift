//
//  HotkeyManager.swift
//  AltTab
//
//  The Cmd+Tab override + session input. Two inputs:
//    (a) Carbon RegisterEventHotKey for Cmd+Tab / Cmd+Shift+Tab — the initial trigger AND every cycle
//        while Cmd stays held (re-fires on each Tab press; needs no Accessibility permission itself).
//    (b) A CGEventTap (background run-loop thread) watching .flagsChanged (Cmd RELEASE = commit) and
//        .keyDown (Esc = cancel, absorbed while a session is active). Handling Esc in the tap — rather
//        than an NSEvent local monitor — works reliably even though our panel is non-activating.
//

import Cocoa
import Carbon.HIToolbox

// MARK: - Session interface (implemented by SwitcherController; @MainActor).
@MainActor
protocol SwitcherSessionControlling: AnyObject {
    var isActive: Bool { get }
    func summonOrCycleForward()   // Cmd+Tab: first press summons (index 1 preselected), again cycles next
    func cycleBackward()          // Cmd+Shift+Tab
    func commit()                 // Cmd released → focus highlighted tile
    func cancel()                 // Esc
}

// MARK: - Carbon hotkey IDs.
private enum HotkeyID: UInt32 { case next = 1, previous = 2 }
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
    /// (on its background thread) whether to absorb Esc. The controller keeps this in sync.
    var sessionActive = false

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

    // MARK: - (a) Carbon hotkeys.
    // kEventHotKeyNoOptions lets the hotkey re-fire on each Tab press while Cmd stays held, so the
    // same hotkey drives both summon and cycle.
    private func installCarbonHotkeys() {
        let target = GetEventDispatcherTarget() // works without Accessibility
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let which = hkID.id
            Task { @MainActor in
                guard let s = HotkeyManager.shared.session else { return }
                if which == HotkeyID.previous.rawValue { s.cycleBackward() } else { s.summonOrCycleForward() }
            }
            return noErr
        }
        InstallEventHandler(target, handler, 1, &spec, nil, &hotKeyHandler)
        register(.next, keyCode: UInt32(kVK_Tab), mods: UInt32(cmdKey), target: target)
        register(.previous, keyCode: UInt32(kVK_Tab), mods: UInt32(cmdKey | shiftKey), target: target)
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
                // Never absorb modifier events — the previously-focused app must still see Cmd-up.
                if !event.flags.contains(.maskCommand) {
                    Task { @MainActor in
                        guard let s = HotkeyManager.shared.session, s.isActive else { return }
                        s.commit()
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
