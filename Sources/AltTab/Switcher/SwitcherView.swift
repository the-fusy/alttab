//
//  SwitcherView.swift
//  AltTab
//
//  Native-style layout: a SINGLE centered row of app-icon tiles plus ONE title label beneath that
//  shows the SELECTED window's title — like the macOS Cmd+Tab switcher. The icon size is chosen
//  ADAPTIVELY: large (up to maxIcon) when few windows, stepping down toward minIcon when there are enough
//  windows that the big size wouldn't fit one row WIDTHWISE. So 2 windows ⇒ big icons, compact panel;
//  many windows ⇒ smaller icons that still fit one row. The design invariant is one row — we assume the
//  window count never exceeds what fits at minIcon, so wrapping (in `build`) is only a defensive fallback.
//  Manual layout, no Auto Layout / NSCollectionView.
//

import Cocoa

final class SwitcherView: NSView {
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var tiles: [TileView] = []
    private var titles: [String] = []
    private var selected = 0

    private lazy var titleLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.alignment = .center
        f.font = .systemFont(ofSize: 14, weight: .medium)
        f.textColor = .labelColor
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        f.drawsBackground = false
        return f
    }()

    private let hMargin: CGFloat = 22
    private let vMargin: CGFloat = 20
    private let spacing: CGFloat = 10
    private let titleGap: CGFloat = 12
    private let titleHeight: CGFloat = 20
    private let minWidth: CGFloat = 280   // keep room for a readable title even with 1–2 icons

    private let maxIcon: CGFloat = 120    // big icons when few windows (~1.7× the old fixed 72)
    private let minIcon: CGFloat = 64     // floor when many windows must fit
    private let iconStep: CGFloat = 8

    override var isFlipped: Bool { true } // top-left origin, so rows fill downward

    /// Build tiles in centered wrapping rows. Icon size adapts so the grid fits a single row within
    /// `maxWidth`; only an extreme window count wraps (see `chooseIconSize`).
    @discardableResult
    func build(windows: [WindowInfo], selected: Int, maxWidth: CGFloat) -> NSSize {
        if titleLabel.superview == nil { addSubview(titleLabel) }
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        titles = windows.map { $0.displayTitle }
        self.selected = selected

        let count = max(windows.count, 1)
        let iconSize = chooseIconSize(count: count, maxWidth: maxWidth)
        let cell = TileView.cell(for: iconSize)

        let avail = max(maxWidth - hMargin * 2, cell)
        let perRow = max(1, Int((avail + spacing) / (cell + spacing)))
        let cols = min(perRow, count)
        let rows = Int(ceil(Double(count) / Double(cols)))

        let gridWidth = CGFloat(cols) * cell + CGFloat(cols - 1) * spacing
        let gridHeight = CGFloat(rows) * cell + CGFloat(rows - 1) * spacing
        let contentWidth = max(gridWidth + hMargin * 2, minWidth)
        let gridOriginX = (contentWidth - gridWidth) / 2

        for (i, w) in windows.enumerated() {
            let row = i / cols
            let col = i % cols
            // Center the (possibly partial) last row rather than left-aligning it.
            let tilesInRow = (row == rows - 1) ? (count - (rows - 1) * cols) : cols
            let rowWidth = CGFloat(tilesInRow) * cell + CGFloat(tilesInRow - 1) * spacing
            let rowOriginX = gridOriginX + (gridWidth - rowWidth) / 2
            let tile = TileView(index: i, window: w, iconSize: iconSize)
            tile.frame = NSRect(x: rowOriginX + CGFloat(col) * (cell + spacing),
                                y: vMargin + CGFloat(row) * (cell + spacing),
                                width: cell, height: cell)
            tile.isSelected = (i == selected)
            tile.onClick = { [weak self] in self?.onClick?($0) }
            tile.onClose = { [weak self] in self?.onClose?($0) }
            addSubview(tile)
            tiles.append(tile)
        }

        let labelY = vMargin + gridHeight + titleGap
        titleLabel.frame = NSRect(x: hMargin, y: labelY, width: contentWidth - hMargin * 2, height: titleHeight)
        updateTitle()

        let contentHeight = labelY + titleHeight + vMargin
        return NSSize(width: contentWidth, height: contentHeight)
    }

    /// Largest icon size (maxIcon→minIcon) that keeps every tile on a SINGLE row. Few windows keep
    /// maxIcon (big); more windows step it down so they still fit one row. Only when even minIcon can't
    /// fit them all in one row do we fall back to minIcon and let `build` wrap into multiple rows.
    /// Height is intentionally NOT a constraint here — wrapping is a width problem. In the extreme
    /// many-window case a tall multi-row grid can exceed the screen; `SwitcherPanel.clamp()` then anchors
    /// the panel's top edge so the first rows stay visible (it does not crop or scroll — pre-existing gap).
    private func chooseIconSize(count: Int, maxWidth: CGFloat) -> CGFloat {
        var size = maxIcon
        while size > minIcon {
            let cell = TileView.cell(for: size)
            let avail = max(maxWidth - hMargin * 2, cell)
            let perRow = max(1, Int((avail + spacing) / (cell + spacing)))
            if perRow >= count { break } // everything fits one row at this size
            size -= iconStep
        }
        return size
    }

    func select(_ index: Int) {
        guard index != selected else { return }
        if tiles.indices.contains(selected) { tiles[selected].isSelected = false }
        if tiles.indices.contains(index) { tiles[index].isSelected = true }
        selected = index
        updateTitle()
    }

    private func updateTitle() {
        titleLabel.stringValue = titles.indices.contains(selected) ? titles[selected] : ""
    }
}
