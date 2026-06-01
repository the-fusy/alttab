//
//  TileView.swift
//  AltTab
//
//  One cell in the native-style switcher: just the app icon, a soft rounded selection halo behind the
//  selected one, and a ✕ close button shown on hover. The icon size is chosen ADAPTIVELY by SwitcherView
//  (bigger when few windows, smaller when many) and passed in. The window title is NOT drawn here — the
//  row's single title label (SwitcherView) shows the selected window's title, exactly like macOS Cmd+Tab.
//

import Cocoa

final class TileView: NSView {
    /// Single source of truth for cell geometry, shared with SwitcherView's layout math.
    static func inset(for iconSize: CGFloat) -> CGFloat { (iconSize * 0.16).rounded() }
    static func cell(for iconSize: CGFloat) -> CGFloat { iconSize + inset(for: iconSize) * 2 }

    let index: Int
    private let iconSize: CGFloat
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }

    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?

    init(index: Int, window: WindowInfo, iconSize: CGFloat) {
        self.index = index
        self.iconSize = iconSize
        let inset = Self.inset(for: iconSize)
        let cell = iconSize + inset * 2
        super.init(frame: NSRect(x: 0, y: 0, width: cell, height: cell))
        wantsLayer = true

        // Icon, centered in the cell.
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let cg = window.icon {
            iconView.image = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
        }
        iconView.frame = NSRect(x: inset, y: inset, width: iconSize, height: iconSize)
        addSubview(iconView)

        // Close button (hover-only, top-left corner of the cell; flipped coords ⇒ small y = top).
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        let cb: CGFloat = 22
        closeButton.frame = NSRect(x: 5, y: 5, width: cb, height: cb)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        // Soft, neutral rounded halo (NOT a saturated blue) — the macOS Cmd+Tab selection look.
        let pad = Self.inset(for: iconSize) * 0.45
        let r = bounds.insetBy(dx: pad, dy: pad)
        let radius = iconSize * 0.2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.22).setFill()
        path.fill()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        // Hover only reveals the close affordance — it does NOT change the selection. Selection moves
        // only via the keyboard (Cmd+Tab) or an explicit click on a tile.
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(index) // click a tile = switch to it
    }

    @objc private func closeClicked() {
        onClose?(index)
    }
}
