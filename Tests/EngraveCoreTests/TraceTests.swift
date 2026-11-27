import CAMCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EngraveCore

@Suite struct TraceTests {
    /// White canvas with black discs; optional white hole in the first.
    func image(size: Int, discs: [(CGFloat, CGFloat, CGFloat)], hole: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for (x, y, r) in discs { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        if hole > 0, let d = discs.first {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: d.0 - hole, y: d.1 - hole, width: 2 * hole, height: 2 * hole))
        }
        return ctx.makeImage()!
    }

    @Test func tracesACircle() {
        var o = TraceOptions()
        o.targetWidth = 100  // 200 px → 0.5 mm/px
        let p = ImageTracer.trace(cgImage: image(size: 200, discs: [(100, 100, 60)]), options: o)
        #expect(p.subpaths.count == 1)
        let fl = p.flattened()
        #expect(fl[0].signedArea > 0)  // counter-clockwise, Y up
        let r = 30.0
        #expect(abs(PathOps.area(p) - Double.pi * r * r) < Double.pi * r * r * 0.02)
        let b = p.tightBounds()!
        #expect(abs(b.center.x - 50) < 0.5 && abs(b.center.y - 50) < 0.5)
    }

    @Test func holesAreClockwiseAndSpecksDropped() {
        var o = TraceOptions()
        o.targetWidth = 100
        o.minDetail = 2  // 4 px
        let img = image(size: 200, discs: [(100, 100, 60), (20, 20, 1.2)], hole: 20)
        let p = ImageTracer.trace(cgImage: img, options: o)
        let areas = p.flattened().map(\.signedArea).sorted()
        #expect(areas.count == 2)
        #expect(areas[0] < 0 && areas[1] > 0)
        let expect = Double.pi * (30 * 30 - 10 * 10)
        #expect(abs(PathOps.area(p, fillRule: .evenOdd) - expect) < expect * 0.03)
        #expect(abs(PathOps.area(p, fillRule: .nonZero) - expect) < expect * 0.03)
    }

    @Test func invertTracesLightAreas() {
        var o = TraceOptions()
        o.invert = true
        o.smoothing = 0
        let p = ImageTracer.trace(cgImage: image(size: 100, discs: [(50, 50, 30)]), options: o)
        // The white background (square with a round hole).
        #expect(abs(PathOps.area(p) - (10000 - Double.pi * 900) / 1) < 200)
    }

    @Test func largeImageIsFast() {
        var discs: [(CGFloat, CGFloat, CGFloat)] = []
        for i in 0..<100 { discs.append((CGFloat(100 + (i % 10) * 190), CGFloat(100 + (i / 10) * 190), 70)) }
        let img = image(size: 2000, discs: discs)
        let t0 = Date()
        let p = ImageTracer.trace(cgImage: img, options: TraceOptions())
        let dt = Date().timeIntervalSince(t0)
        #expect(p.subpaths.count == 100)
        #expect(dt < 5)  // debug build; well under a second in release
    }

    @Test func loadsAPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swarf-trace-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let img = image(size: 64, discs: [(32, 32, 20)])
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        let loaded = try ImageTracer.loadImage(url: url)
        #expect(loaded.width == 64)
    }
}
