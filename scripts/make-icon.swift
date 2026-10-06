// Draws Take's app icon (a white ring around a red dot on a charcoal tile) and writes AppIcon.icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Take.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024   // drawn on Apple's 1024 icon grid

    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1), ending: NSColor(calibratedWhite: 0.09, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    let ring = NSBezierPath(ovalIn: NSRect(x: 262 * s, y: 262 * s, width: 500 * s, height: 500 * s))
    ring.lineWidth = 44 * s
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
    ring.stroke()

    NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 352 * s, y: 352 * s, width: 320 * s, height: 320 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
