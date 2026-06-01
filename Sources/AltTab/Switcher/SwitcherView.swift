//
//  SwitcherView.swift
//  AltTab
//
//  Lays out one TileView per window in a left-to-right wrapping grid (manual layout, no Auto Layout,
//  no NSCollectionView) and tracks the selection highlight. Mouse hover selects, click commits,
//  the per-tile ✕ closes.
//

import Cocoa

final class SwitcherView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var tiles: [TileView] = []
    private var selected = 0

    private let margin: CGFloat = 16
    private let spacing: CGFloat = 10

    override var isFlipped: Bool { true } // top-left origin, so rows fill downward

    /// Build tiles, wrapping within `maxWidth`. Returns the total content size (incl. margins).
    @discardableResult
    func build(windows: [WindowInfo], selected: Int, maxWidth: CGFloat) -> NSSize {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        self.selected = selected

        let tw = TileView.width, th = TileView.height
        let count = max(windows.count, 1)
        let avail = max(maxWidth - margin * 2, tw)
        let perRow = max(1, Int((avail + spacing) / (tw + spacing)))
        let cols = min(perRow, count)
        let rows = Int(ceil(Double(count) / Double(cols)))

        for (i, w) in windows.enumerated() {
            let row = i / cols
            let col = i % cols
            let tile = TileView(index: i, window: w)
            tile.frame = NSRect(x: margin + CGFloat(col) * (tw + spacing),
                                y: margin + CGFloat(row) * (th + spacing),
                                width: tw, height: th)
            tile.isSelected = (i == selected)
            tile.onHover = { [weak self] in self?.onHover?($0) }
            tile.onClick = { [weak self] in self?.onClick?($0) }
            tile.onClose = { [weak self] in self?.onClose?($0) }
            addSubview(tile)
            tiles.append(tile)
        }

        let width = margin * 2 + CGFloat(cols) * tw + CGFloat(cols - 1) * spacing
        let height = margin * 2 + CGFloat(rows) * th + CGFloat(rows - 1) * spacing
        return NSSize(width: width, height: height)
    }

    func select(_ index: Int) {
        guard index != selected else { return }
        if tiles.indices.contains(selected) { tiles[selected].isSelected = false }
        if tiles.indices.contains(index) { tiles[index].isSelected = true }
        selected = index
    }
}
