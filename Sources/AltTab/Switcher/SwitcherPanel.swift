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
    var onHover: ((Int) -> Void)?
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

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        contentView = effectView

        grid.onHover = { [weak self] in self?.onHover?($0) }
        grid.onClick = { [weak self] in self?.onClick?($0) }
        grid.onClose = { [weak self] in self?.onClose?($0) }
        effectView.addSubview(grid)
    }

    // A borderless/non-activating panel must opt in to becoming key to receive keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(windows: [WindowInfo], selected: Int) {
        let screen = Self.targetScreen()
        let maxWidth = screen.visibleFrame.width * 0.92
        let size = grid.build(windows: windows, selected: selected, maxWidth: maxWidth)
        grid.frame = NSRect(origin: NSPoint(x: outerInset, y: outerInset), size: size)
        setContentSize(size)
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        alphaValue = 1
        makeKeyAndOrderFront(nil)
    }

    /// Re-lay-out an already-visible panel (e.g. after closing a tile) WITHOUT re-centering, so tiles
    /// don't jump under the cursor. Keeps the top edge and horizontal center fixed.
    func rebuild(windows: [WindowInfo], selected: Int) {
        let anchorCenterX = frame.midX
        let anchorTop = frame.maxY
        let maxWidth = Self.targetScreen().visibleFrame.width * 0.92
        let size = grid.build(windows: windows, selected: selected, maxWidth: maxWidth)
        grid.frame = NSRect(origin: NSPoint(x: outerInset, y: outerInset), size: size)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: anchorCenterX - size.width / 2, y: anchorTop - size.height))
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
