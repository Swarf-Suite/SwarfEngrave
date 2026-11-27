import CAMCore
import Foundation
import Testing
@testable import EngraveCore

@Suite struct PathOpsTests {
    func square(_ x: Double, _ y: Double, _ s: Double) -> Path2D { Path2D.rect(width: s, height: s).mapped { $0 + V2(x, y) } }

    @Test func unionOfOverlappingSquares() {
        let u = PathOps.union([square(0, 0, 10), square(5, 0, 10)])
        #expect(abs(PathOps.area(u) - 150) < 1e-6)
        #expect(u.subpaths.count == 1)
        #expect(u.subpaths[0].segments.count == 3)  // a 15×10 rectangle
    }

    @Test func subtractMakesHole() {
        let r = PathOps.subtract(square(0, 0, 20), square(0, 0, 10))
        #expect(abs(PathOps.area(r) - 300) < 1e-6)
        #expect(r.subpaths.count == 2)
        let areas = r.flattened().map(\.signedArea).sorted()
        #expect(abs(areas[0] + 100) < 1e-6 && abs(areas[1] - 400) < 1e-6)  // hole clockwise
    }

    @Test func intersectAndExclude() {
        let a = square(0, 0, 10), b = square(5, 5, 10)
        #expect(abs(PathOps.area(PathOps.intersect(a, b)) - 25) < 1e-6)
        #expect(abs(PathOps.area(PathOps.exclude(a, b)) - 150) < 1e-6)
    }

    @Test func collinearAndSharedEdges() {
        // Two squares sharing an edge, plus an exact duplicate.
        let u = PathOps.union([square(0, 0, 10), square(10, 0, 10), square(10, 0, 10)])
        #expect(abs(PathOps.area(u) - 200) < 1e-6)
        #expect(u.subpaths.count == 1)
        #expect(u.subpaths[0].segments.count == 3)  // collinear vertices removed: a 4-corner rectangle
    }

    @Test func circlesAndOrientationIndependence() {
        let a = Path2D.ellipse(width: 20, height: 20)
        let b = Path2D(a.subpaths.map(ImportGeometry.reversed)).mapped { $0 + V2(10, 0) }  // clockwise
        let u = PathOps.union([a, b])
        let r = 10.0, d = 10.0
        let lens = 2 * r * r * acos(d / (2 * r)) - d / 2 * (4 * r * r - d * d).squareRoot()
        #expect(abs(PathOps.area(u) - (2 * Double.pi * r * r - lens)) < 1.0)  // flattening at 0.01 mm loses a little area
    }

    @Test func evenOddFill() {
        var p = square(0, 0, 20)
        p.append(square(0, 0, 10))  // same orientation
        #expect(abs(PathOps.area(p, fillRule: .nonZero) - 400) < 1e-6)
        #expect(abs(PathOps.area(p, fillRule: .evenOdd) - 300) < 1e-6)
    }

    @Test func overlappingTextGlyphs() {
        var spec = TextSpec(string: "ooo", fontName: "Helvetica-Bold", size: 10)
        spec.tracking = -3  // force overlaps
        let t = TextOutliner.path(for: spec)
        let u = PathOps.union([t])
        let a = PathOps.area(u)
        #expect(a > 0)
        #expect(a < PathOps.area(t, fillRule: .nonZero) + 1e-6)
        // Holes stay holes: union area is less than the outer outlines' area.
        #expect(u.flattened().contains { $0.signedArea < 0 })
    }

    @Test func offsetSquareRoundCorners() {
        let o = PathOps.offset(square(0, 0, 10), by: 1)
        let expected = 100 + 4 * 10 + Double.pi
        #expect(abs(PathOps.area(o) - expected) < 0.05)
        let i = PathOps.offset(square(0, 0, 10), by: -1)
        #expect(abs(PathOps.area(i) - 64) < 0.01)
        let gone = PathOps.offset(square(0, 0, 10), by: -6)
        #expect(gone.isEmpty)
    }

    @Test func offsetOpenLineMakesCapsule() {
        let o = PathOps.offset(Path2D.line(length: 10), by: 1)
        #expect(abs(PathOps.area(o) - (20 + Double.pi)) < 0.05)
    }

    @Test func simplifyReducesPoints() {
        let c = Path2D.ellipse(width: 50, height: 50)
        let s = PathOps.simplify(c, tolerance: 0.1)
        #expect(s.subpaths.count == 1)
        #expect(s.subpaths[0].segments.count < c.flattened(tolerance: 0.001)[0].points.count)
        #expect(abs(PathOps.area(s) - Double.pi * 625) < 25 * 0.1 * 2 * Double.pi)
    }

    @Test func manyEdgesPerformance() {
        var paths: [Path2D] = []
        for i in 0..<200 { paths.append(Path2D.ellipse(width: 6, height: 6).mapped { $0 + V2(Double(i % 20) * 4, Double(i / 20) * 4) }) }
        let t0 = Date()
        let u = PathOps.union(paths)
        #expect(!u.isEmpty)
        #expect(Date().timeIntervalSince(t0) < 10)
    }
}

