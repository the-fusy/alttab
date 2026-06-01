//
//  makeicon.swift
//  AltTab — app-icon generator (no asset catalog, no external tooling).
//
//  Draws the icon programmatically with CoreGraphics/AppKit at every required size and writes a
//  .iconset folder. Regenerate the bundled icon with:
//
//      swift scripts/makeicon.swift /tmp/AltTab.iconset
//      iconutil -c icns -o Resources/AltTab.icns /tmp/AltTab.iconset
//
//  build.sh then copies Resources/AltTab.icns into the .app (CFBundleIconFile=AltTab in Info.plist).
//  Motif: a blue "squircle" (native macOS shape) with two overlapping window cards = a window switcher.
//

import AppKit

// Draws the AltTab app icon at an arbitrary pixel size and returns PNG data.

func roundedCard(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func drawIcon(_ s: CGFloat) {
    // --- Background squircle ---
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = (s - 2 * inset) * 0.2237   // Apple's continuous-corner ratio
    let bg = roundedCard(rect, radius)

    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.40, green: 0.62, blue: 1.00, alpha: 1),   // top
        NSColor(srgbRed: 0.17, green: 0.33, blue: 0.85, alpha: 1),   // bottom
    ])!
    grad.draw(in: bg, angle: -90)

    // Soft top sheen for depth.
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.20),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let cardW = s * 0.46
    let cardH = s * 0.36
    let cardR = s * 0.045

    // --- Back card (upper-right, faint) ---
    let back = NSRect(x: s * 0.345, y: s * 0.405, width: cardW, height: cardH)
    NSColor.white.withAlphaComponent(0.42).setFill()
    roundedCard(back, cardR).fill()

    // --- Front card (lower-left) with a soft drop shadow ---
    let front = NSRect(x: s * 0.195, y: s * 0.255, width: cardW, height: cardH)
    let frontPath = roundedCard(front, cardR)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.white.setFill()
    frontPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Front card interior (clip to the card).
    NSGraphicsContext.saveGraphicsState()
    frontPath.addClip()

    // Title bar.
    let titleBarH = cardH * 0.27
    let titleBar = NSRect(x: front.minX, y: front.maxY - titleBarH, width: front.width, height: titleBarH)
    NSColor(srgbRed: 0.20, green: 0.37, blue: 0.88, alpha: 1).setFill()
    NSBezierPath(rect: titleBar).fill()

    // Traffic-light dots.
    let dotR = titleBarH * 0.20
    let dy = titleBar.midY
    let dotColors = [
        NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.78, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.28, green: 0.82, blue: 0.35, alpha: 1),
    ]
    for (i, c) in dotColors.enumerated() {
        let cx = front.minX + titleBarH * 0.55 + CGFloat(i) * dotR * 2.7
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: dy - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    // Content lines.
    let lineH = cardH * 0.07
    let lineX = front.minX + cardW * 0.12
    let lineW = cardW * 0.70
    let widths: [CGFloat] = [1.0, 0.72, 0.46]
    var ly = titleBar.minY - cardH * 0.16
    for wf in widths {
        NSColor(white: 0.80, alpha: 1).setFill()
        roundedCard(NSRect(x: lineX, y: ly - lineH, width: lineW * wf, height: lineH), lineH / 2).fill()
        ly -= lineH + cardH * 0.115
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(CGFloat(size))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Build the .iconset directory.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AltTab.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (filename, pixel size)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
var cache: [Int: Data] = [:]
for (name, px) in variants {
    let data = cache[px] ?? render(px)
    cache[px] = data
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(variants.count) PNGs to \(outDir)")
