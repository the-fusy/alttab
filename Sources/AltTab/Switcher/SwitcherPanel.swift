//
//  SwitcherPanel.swift
//  AltTab
//
//  The single, reused overlay window. A non-activating panel so it can take keystrokes (Esc, Tab)
//  for its own controls WITHOUT activating AltTab or stealing app-level focus from the foreground
//  app. Blur background via NSVisualEffectView; tiles laid out by SwitcherView.
//

import Cocoa

final class SwitcherPanel: NSPanel {
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let effectView = NSVisualEffectView()
    private let grid = SwitcherView()
    private let outerInset: CGFloat = 0 // SwitcherView bakes its own margins

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu // sits above context menus; .screenSaver would break drag-and-drop
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isMovable = false
        setAccessibilitySubrole(.unknown) // keep our own window out of any future capture/list
        // Dark vibrant appearance so the title label / close-button semantic colors resolve light on the
        // dark HUD blur (matches the native Cmd+Tab switcher).
        appearance = NSAppearance(named: .vibrantDark)

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.masksToBounds = true
        contentView = effectView

        grid.onClick = { [weak self] in self?.onClick?($0) }
        grid.onClose = { [weak self] in self?.onClose?($0) }
        effectView.addSubview(grid)
    }

    // A borderless/non-activating panel must opt in to becoming key to receive keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(windows: [WindowInfo], selected: Int) {
        let vf = Self.targetScreen().visibleFrame
        let size = grid.build(windows: windows, selected: selected, maxWidth: vf.width * 0.92, maxHeight: vf.height * 0.9)
        grid.frame = NSRect(origin: NSPoint(x: outerInset, y: outerInset), size: size)
        setContentSize(size)
        let centered = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        setFrameOrigin(clamp(centered, size: size, in: vf))
        alphaValue = 1
        makeKeyAndOrderFront(nil)
    }

    /// Re-lay-out an already-visible panel (e.g. after closing a tile) WITHOUT re-centering, so tiles
    /// don't jump under the cursor. Keeps the top edge and horizontal center fixed.
    func rebuild(windows: [WindowInfo], selected: Int) {
        let vf = Self.targetScreen().visibleFrame
        let anchorCenterX = frame.midX
        let anchorTop = frame.maxY
        let size = grid.build(windows: windows, selected: selected, maxWidth: vf.width * 0.92, maxHeight: vf.height * 0.9)
        grid.frame = NSRect(origin: NSPoint(x: outerInset, y: outerInset), size: size)
        setContentSize(size)
        let anchored = NSPoint(x: anchorCenterX - size.width / 2, y: anchorTop - size.height)
        setFrameOrigin(clamp(anchored, size: size, in: vf))
    }

    /// Keep the whole panel inside the screen's usable area. If it is taller than the screen (a great
    /// many windows), anchor its TOP so the first rows — including the pre-selected previous window —
    /// stay visible rather than centering it half-off both edges.
    private func clamp(_ origin: NSPoint, size: NSSize, in vf: NSRect) -> NSPoint {
        var o = origin
        o.x = (size.width <= vf.width) ? max(vf.minX, min(o.x, vf.maxX - size.width)) : vf.minX
        o.y = (size.height <= vf.height) ? max(vf.minY, min(o.y, vf.maxY - size.height)) : vf.maxY - size.height
        return o
    }

    func select(_ index: Int) { grid.select(index) }

    override func orderOut(_ sender: Any?) {
        alphaValue = 0 // mask any WindowServer lag in the actual orderOut
        super.orderOut(sender)
    }

    /// Screen under the mouse, else the main screen.
    static func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
