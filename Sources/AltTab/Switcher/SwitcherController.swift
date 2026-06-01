//
//  SwitcherController.swift
//  AltTab
//
//  The session brain. Conforms to SwitcherSessionControlling (driven by HotkeyManager) and ties
//  together the window model, the panel, and the focus commit. Implements the fast-flip:
//  pre-select the previous window (index 1) and DEFER drawing the panel ~100ms, so a quick
//  Cmd+Tab tap flips to the previous window with no panel ever appearing.
//

import Cocoa

@MainActor
final class SwitcherController: SwitcherSessionControlling {
    static let shared = SwitcherController()

    private let panel = SwitcherPanel()

    /// Stable snapshot for the lifetime of one session (MRU-sorted, most-recent first).
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private var active = false
    private var panelShown = false
    private var drawGeneration = 0
    private var pollTimer: Timer?

    /// Time the panel waits before drawing on first summon. Release Cmd before this → no panel.
    private let displayDelay: TimeInterval = 0.1

    private init() {
        panel.onClick = { [weak self] in self?.mouseCommit($0) }
        panel.onClose = { [weak self] in self?.closeTile($0) }
    }

    var isActive: Bool { active }

    // MARK: - Input from HotkeyManager

    func summonOrCycleForward() {
        if !active { begin(forward: true) } else { move(by: +1) }
    }

    func cycleBackward() {
        if !active { begin(forward: false) } else { move(by: -1) }
    }

    func commit() {
        guard active else { return }
        let target = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
        end()
        if let target {
            // Optimistically make the chosen window MRU index 0 NOW, on the main thread, so a fast second
            // Cmd+Tab sees the new order immediately instead of racing the async AX activation notification
            // (which can lag tens of ms or be coalesced away, breaking the A→B→A "previous window" flip).
            WindowStore.shared.noteFocused(wid: target.cgWindowId)
            Focus.focus(.init(axWindow: target.axElement, pid: target.pid, cgWindowId: target.cgWindowId))
        }
    }

    func cancel() {
        guard active else { return }
        end() // leave focus untouched — we never stole it
    }

    // MARK: - Session lifecycle

    private func begin(forward: Bool) {
        windows = WindowStore.shared.sortedForDisplay()
        // Need at least two windows to switch between; one (or zero) → nothing to do, no panel.
        guard windows.count > 1 else { windows = []; return }
        active = true
        HotkeyManager.shared.sessionActive = true // lets the event tap absorb Esc while we're up
        panelShown = false
        let n = windows.count
        // index 0 == current window; forward first press → previous (1); backward first press → last.
        selectedIndex = forward ? 1 : n - 1
        drawGeneration += 1
        let gen = drawGeneration

        // Fast-tap race: if Cmd was released before this began (the tap's commit found !active and
        // bailed), commit the pre-selected window immediately — instant flip, no 100ms wait, no panel.
        if !NSEvent.modifierFlags.contains(.command) { commit(); return }

        WindowStore.shared.reconcileAllApps() // best-effort refresh of the live store (not this snapshot)
        startPollTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + displayDelay) { [weak self] in
            guard let self, self.active, self.drawGeneration == gen, !self.panelShown else { return }
            // Race guard: if Cmd was already released (tap missed the up event), commit now — no flash.
            if NSEvent.modifierFlags.contains(.command) { self.showPanel() } else { self.commit() }
        }
    }

    private func showPanel() {
        guard active, !panelShown else { return }
        panelShown = true
        panel.show(windows: windows, selected: selectedIndex)
    }

    private func move(by delta: Int) {
        guard active, !windows.isEmpty else { return }
        let n = windows.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
        if panelShown { panel.select(selectedIndex) } else { showPanel() } // cycling means: show it now
    }

    private func end() {
        active = false
        HotkeyManager.shared.sessionActive = false
        panelShown = false
        stopPollTimer()
        panel.orderOut(nil)
        windows = []
    }

    // MARK: - Mouse

    // A tile is selected only by an EXPLICIT click — hovering no longer moves the selection.
    private func mouseCommit(_ idx: Int) {
        guard active, windows.indices.contains(idx) else { return }
        selectedIndex = idx
        commit()
    }

    private func closeTile(_ idx: Int) {
        guard active, windows.indices.contains(idx) else { return }
        let target = windows[idx]
        // Optimistic UI: drop the tile immediately so the panel stays snappy.
        windows.remove(at: idx)
        if windows.isEmpty {
            cancel()
        } else {
            if selectedIndex >= windows.count { selectedIndex = windows.count - 1 }
            panel.rebuild(windows: windows, selected: selectedIndex) // re-lay-out without re-centering
        }
        // Press close; if a confirmation dialog ("Save changes?") blocks it, step out of the way and
        // bring that dialog to the front so the user can actually answer it (it would otherwise be
        // stranded behind everything, with the tile already gone).
        target.close { [weak self] outcome in
            guard case .needsAttention = outcome else { return }
            if let self, self.active { self.end() } // hide our panel before fronting the dialog
            Focus.focus(.init(axWindow: target.axElement, pid: target.pid, cgWindowId: target.cgWindowId))
        }
    }

    // MARK: - Stuck-panel fallback: if a Cmd-up flagsChanged was dropped, poll the hardware modifier.

    private func startPollTimer() {
        stopPollTimer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                if !NSEvent.modifierFlags.contains(.command) { self.commit() }
            }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate(); pollTimer = nil
    }
}
