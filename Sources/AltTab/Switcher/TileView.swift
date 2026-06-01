//
//  TileView.swift
//  AltTab
//
//  One cell: app icon on top, window title below, a ✕ close button shown on hover, and a rounded
//  selection highlight. Plain AppKit views — fine for the handful of tiles a fast switcher shows.
//

import Cocoa

final class TileView: NSView {
    static let width: CGFloat = 150
    static let height: CGFloat = 124

    let index: Int
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?

    private static let iconSize: CGFloat = 64

    init(index: Int, window: WindowInfo) {
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true

        // Icon (top, centered).
        let s = Self.iconSize
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let cg = window.icon {
            iconView.image = NSImage(cgImage: cg, size: NSSize(width: s, height: s))
        }
        iconView.frame = NSRect(x: (Self.width - s) / 2, y: 16, width: s, height: s)
        addSubview(iconView)

        // Title (below icon, up to 2 truncated lines).
        titleField.stringValue = window.displayTitle
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 11)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 2
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.frame = NSRect(x: 6, y: 16 + s + 6, width: Self.width - 12, height: 34)
        addSubview(titleField)

        // Close button (hover-only, top-left).
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.frame = NSRect(x: 7, y: 7, width: 20, height: 20)
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
        let r = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.9).setFill()
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
        onHover?(index)
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
