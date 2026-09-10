// Generates AppIcon.icns: a G whose counter is the record dot.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//   swift scripts/make-icon.swift preview.png 512     (single PNG, for the README)
//
// Every measurement is a fraction of the canvas, so the mark is redrawn at each
// size rather than scaled — it stays readable from 16pt up to 1024pt.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let outPath = arguments.first ?? "AppIcon.icns"
let singleSize = arguments.count > 1 ? Int(arguments[1]) : nil

/// macOS app icons are a superellipse, not a rounded rectangle with circular
/// corners: the sides run straight and ease into the corner with no visible seam.
/// Exponent 6.2 lands on the same silhouette as the system apps.
func squircle(in rect: CGRect, exponent n: CGFloat = 6.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let point = CGPoint(x: rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                            y: rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// Draws into an explicit pixel buffer rather than NSImage.lockFocus, which
/// allocates at the current display's scale factor — on a Retina Mac that produced
/// files twice their nominal size, iconutil then slotted them one step up, and the
/// 16pt and 128pt representations were dropped entirely.
func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)          // one point per pixel
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)

    let tile = CGRect(x: s * 0.055, y: s * 0.055, width: s * 0.89, height: s * 0.89)
    ctx.saveGState()
    ctx.addPath(squircle(in: tile))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(red: 0.24, green: 0.25, blue: 0.46, alpha: 1).cgColor,
                 NSColor(red: 0.06, green: 0.06, blue: 0.14, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: tile.midX, y: tile.midY)
    let radius = s * 0.245, weight = s * 0.098
    let ivory = NSColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1).cgColor

    // The G: a ring with its mouth at the upper right, closed by a bar running
    // inward from the lower terminal. The bar has to stay inside the ring's outer
    // edge and sit below centre — above it the letter reads as an "e", and past
    // the edge it reads as a "Q".
    let mouth: CGFloat = 0.18 * .pi
    ctx.setStrokeColor(ivory)
    ctx.setLineWidth(weight)
    ctx.setLineCap(.butt)
    ctx.addArc(center: c, radius: radius, startAngle: -mouth, endAngle: 0.12 * .pi, clockwise: true)
    ctx.strokePath()

    let barY = c.y - radius * sin(mouth)
    ctx.setLineCap(.round)
    ctx.setLineWidth(weight * 0.84)
    ctx.move(to: CGPoint(x: c.x + radius * cos(mouth), y: barY))
    ctx.addLine(to: CGPoint(x: c.x + radius * 0.18, y: barY))
    ctx.strokePath()

    // The record dot, sitting in the counter.
    let dot = s * 0.066
    ctx.setFillColor(NSColor(red: 1.0, green: 0.29, blue: 0.24, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y + s * 0.028 - dot, width: dot * 2, height: dot * 2))

    NSGraphicsContext.current?.flushGraphics()
    return rep
}

func png(_ px: Int) -> Data {
    draw(px).representation(using: .png, properties: [:])!
}

if let size = singleSize {
    try! png(size).write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(size)×\(size))")
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(outPath)" : "iconutil failed")
exit(iconutil.terminationStatus)
