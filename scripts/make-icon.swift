#!/usr/bin/env swift  // Draws the Sapling app icon and packs it into an .icns.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//
// Drawn in code rather than from an SF Symbol: Apple's symbol licence does not
// cover app icons. Everything is laid out on a 1024pt canvas and scaled, so
// every size in the iconset comes from the same vector drawing.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A leaf from `base` to `tip`, bulging `width` to either side of the midrib.
func leaf(from base: NSPoint, to tip: NSPoint, width: CGFloat, lean: CGFloat = 0.12) -> NSBezierPath {
    let dx = tip.x - base.x
    let dy = tip.y - base.y
    let length = hypot(dx, dy)
    let nx = -dy / length
    let ny = dx / length
    func along(_ t: CGFloat, _ offset: CGFloat) -> NSPoint {
        NSPoint(x: base.x + dx * t + nx * offset, y: base.y + dy * t + ny * offset)
    }
    let path = NSBezierPath()
    path.move(to: base)
    path.curve(
        to: tip, controlPoint1: along(0.25, width * (1 + lean)), controlPoint2: along(0.75, width * 0.9))
    path.curve(
        to: base, controlPoint1: along(0.75, -width * 0.9), controlPoint2: along(0.25, -width * (1 - lean)))
    path.close()
    return path
}

func drawLeaf(from base: NSPoint, to tip: NSPoint, width: CGFloat) {
    let shape = leaf(from: base, to: tip, width: width)
    NSGradient(starting: color(0xF6FCEE), ending: color(0xB9E39F))?.draw(in: shape, angle: -60)

    let vein = NSBezierPath()
    vein.move(to: base)
    vein.line(to: NSPoint(x: base.x + (tip.x - base.x) * 0.82, y: base.y + (tip.y - base.y) * 0.82))
    vein.lineWidth = 7
    vein.lineCapStyle = .round
    color(0x2E8B57, 0.35).setStroke()
    vein.stroke()
}

func drawIcon(in context: NSGraphicsContext, size: CGFloat) {
    context.cgContext.scaleBy(x: size / 1024, y: size / 1024)

    // The macOS icon grid: an 824pt body centred on the 1024pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.28)
    lift.shadowOffset = NSSize(width: 0, height: -10)
    lift.shadowBlurRadius = 22
    lift.set()
    color(0x14593A).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: color(0x46B474), ending: color(0x115235))?.draw(in: body, angle: -90)

    // A soft glow behind the plant, so it reads as lit rather than pasted on.
    let glow = NSGradient(colors: [color(0xE8FFD8, 0.28), color(0xE8FFD8, 0.08), color(0xE8FFD8, 0)])
    glow?.draw(
        fromCenter: NSPoint(x: 520, y: 600), radius: 0, toCenter: NSPoint(x: 520, y: 600), radius: 400,
        options: [])

    // The plant, with one shadow under all of it.
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = color(0x06281A, 0.45)
    drop.shadowOffset = NSSize(width: 0, height: -8)
    drop.shadowBlurRadius = 18
    drop.set()
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 508, y: 230))
    stem.curve(
        to: NSPoint(x: 522, y: 690), controlPoint1: NSPoint(x: 490, y: 430),
        controlPoint2: NSPoint(x: 540, y: 560))
    stem.lineWidth = 34
    stem.lineCapStyle = .round
    color(0xEAF6DE).setStroke()
    stem.stroke()

    drawLeaf(from: NSPoint(x: 508, y: 470), to: NSPoint(x: 268, y: 600), width: 92)
    drawLeaf(from: NSPoint(x: 526, y: 570), to: NSPoint(x: 790, y: 735), width: 118)
    drawLeaf(from: NSPoint(x: 522, y: 680), to: NSPoint(x: 548, y: 858), width: 62)

    context.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // Soil, over the foot of the stem so the plant grows out of it.
    let mound = NSBezierPath()
    mound.move(to: NSPoint(x: 100, y: 100))
    mound.line(to: NSPoint(x: 100, y: 250))
    mound.curve(
        to: NSPoint(x: 924, y: 250), controlPoint1: NSPoint(x: 330, y: 345),
        controlPoint2: NSPoint(x: 694, y: 345))
    mound.line(to: NSPoint(x: 924, y: 100))
    mound.close()
    NSGradient(starting: color(0x0E4A2E), ending: color(0x0A3622))?.draw(in: mound, angle: -90)

    // A faint rim, as macOS icons have, so it holds its edge on any wallpaper.
    NSGraphicsContext.restoreGraphicsState()
    squircle.lineWidth = 2
    NSColor.white.withAlphaComponent(0.18).setStroke()
    squircle.stroke()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(in: context, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] {
    try png(size: 1024).write(to: URL(fileURLWithPath: preview))
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
