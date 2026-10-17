// Renders assets/AppIcon.icns  —  run:  swift assets/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS-style rounded square with margin
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1))!
        .draw(in: path, angle: -90)
    // lock glyph
    let cfg = NSImage.SymbolConfiguration(pointSize: r.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)]))
    if let g = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let gs = g.size
        g.draw(in: NSRect(x: (s - gs.width) / 2, y: (s - gs.height) / 2, width: gs.width, height: gs.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets")
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: set.appendingPathComponent("icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: set.appendingPathComponent("icon_\(b)x\(b)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("wrote", dir.appendingPathComponent("AppIcon.icns").path)
