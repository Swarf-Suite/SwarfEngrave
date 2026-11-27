// Renders Resources/AppIcon.icns: a sage V-groove carved into a dark slate block.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // Background: dark slate rounded square.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(white: 0.19, alpha: 1), NSColor(white: 0.08, alpha: 1)])!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.06).setStroke()
    bg.lineWidth = 6 * s
    bg.stroke()

    // The V-groove seen end on: two sloped walls meeting at the bottom.
    let sage = NSColor(red: 0x7c / 255, green: 0xc4 / 255, blue: 0xa6 / 255, alpha: 1)
    let sageBright = NSColor(red: 0x9b / 255, green: 0xd6 / 255, blue: 0xbd / 255, alpha: 1)
    let sageDark = NSColor(red: 0x3f / 255, green: 0x6e / 255, blue: 0x5b / 255, alpha: 1)
    let top: CGFloat = 690, bottom: CGFloat = 300, left: CGFloat = 250, right: CGFloat = 774, mid: CGFloat = 512
    let lip: CGFloat = 70
    let leftWall = NSBezierPath()
    leftWall.move(to: NSPoint(x: left * s, y: top * s))
    leftWall.line(to: NSPoint(x: (left + lip) * s, y: top * s))
    leftWall.line(to: NSPoint(x: mid * s, y: (bottom + 120) * s))
    leftWall.line(to: NSPoint(x: mid * s, y: bottom * s))
    leftWall.close()
    NSGradient(colors: [sageBright, sage])!.draw(in: leftWall, angle: -60)
    let rightWall = NSBezierPath()
    rightWall.move(to: NSPoint(x: right * s, y: top * s))
    rightWall.line(to: NSPoint(x: (right - lip) * s, y: top * s))
    rightWall.line(to: NSPoint(x: mid * s, y: (bottom + 120) * s))
    rightWall.line(to: NSPoint(x: mid * s, y: bottom * s))
    rightWall.close()
    NSGradient(colors: [sage, sageDark])!.draw(in: rightWall, angle: -120)

    // Stock surface either side of the groove.
    ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
    ctx.setLineWidth(14 * s)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 190 * s, y: top * s)); ctx.addLine(to: CGPoint(x: left * s, y: top * s)); ctx.strokePath()
    ctx.move(to: CGPoint(x: right * s, y: top * s)); ctx.addLine(to: CGPoint(x: 834 * s, y: top * s)); ctx.strokePath()
    img.unlockFocus()
    return img
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let set = out.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
