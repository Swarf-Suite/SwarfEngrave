import CAMCore
import CoreGraphics
import Foundation
import Testing
@testable import EngraveCore

@Suite struct ImportTests {
    @Test func svgUnitsViewBoxAndFlip() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 200 100">
          <rect x="0" y="0" width="20" height="10"/>
        </svg>
        """
        let art = try ArtworkImporter.importSVG(svg)
        #expect(art.layers.count == 1)
        let b = art.layers[0].path.tightBounds()!
        // 20×10 user units at 0.5 mm each, at the top-left of a 50 mm tall page → Y up from 40 to 50.
        #expect(abs(b.min.x) < 1e-9 && abs(b.max.x - 10) < 1e-9)
        #expect(abs(b.min.y - 45) < 1e-9 && abs(b.max.y - 50) < 1e-9)
    }

    @Test func svgPixelsDefaultTo96dpi() throws {
        let art = try ArtworkImporter.importSVG(#"<svg width="96" height="96"><line x1="0" y1="0" x2="96" y2="0"/></svg>"#)
        let b = art.layers[0].path.tightBounds()!
        #expect(abs(b.size.x - 25.4) < 1e-9)
    }

    @Test func svgTransformsAndLayers() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
             width="100mm" height="100mm" viewBox="0 0 100 100">
          <g inkscape:label="Cuts" transform="translate(10,20)">
            <rect width="10" height="10" transform="scale(2)"/>
          </g>
          <g id="second"><circle cx="50" cy="50" r="10" transform="rotate(90 50 50)"/></g>
          <g id="third" transform="matrix(1 0 0 1 5 5)"><path d="M0 0 h10 v10 h-10 z"/></g>
        </svg>
        """
        let art = try ArtworkImporter.importSVG(svg)
        #expect(art.layers.map(\.name) == ["Cuts", "second", "third"])
        let r = art.layers[0].path.tightBounds()!
        #expect(abs(r.min.x - 10) < 1e-9 && abs(r.max.x - 30) < 1e-9)
        #expect(abs(r.max.y - 80) < 1e-9 && abs(r.min.y - 60) < 1e-9)  // y 20..40 down → 80..60 up
        let c = art.layers[1].path.tightBounds()!
        #expect(abs(c.center.x - 50) < 1e-6 && abs(c.size.x - 20) < 0.01)
        #expect(abs(PathOps.area(art.layers[2].path) - 100) < 1e-6)
    }

    @Test func svgPathCommandsAndArcs() throws {
        // A 10-radius circle from two relative arcs; smooth curves and implicit repeats.
        let p = SVGImporter.pathData("M0,0 a10,10 0 1,0 20,0 a10 10 0 1 0 -20 0z")
        #expect(p.subpaths.count == 1 && p.subpaths[0].closed)
        #expect(abs(abs(PathOps.area(p)) - Double.pi * 100) < 0.5)
        let q = SVGImporter.pathData("m10 10l5 0 0 5-5-5zM0 0C0 10 10 10 10 0S20-10 20 0Q25 5 30 0T40 0H50V10L60.5.5")
        #expect(q.subpaths.count == 2)
        #expect(q.subpaths[0].segments.count == 3)
        let end = ImportGeometry.endPoint(q.subpaths[1])
        #expect(abs(end.x - 60.5) < 1e-12 && abs(end.y - 0.5) < 1e-12)
        // Compact arc flags.
        let r = SVGImporter.pathData("M0 0a5 5 0 0010 0")
        #expect(abs(ImportGeometry.endPoint(r.subpaths[0]).x - 10) < 1e-12)
    }

    @Test func svgJoinsOpenSegments() throws {
        let svg = """
        <svg width="10mm" height="10mm" viewBox="0 0 10 10">
          <line x1="0" y1="0" x2="10" y2="0"/><line x1="10" y1="10" x2="10" y2="0"/>
          <path d="M10 10 L0 10"/><path d="M0 10.005 L0 0"/>
        </svg>
        """
        let art = try ArtworkImporter.importSVG(svg)
        let p = art.layers[0].path
        #expect(p.subpaths.count == 1)
        #expect(p.subpaths[0].closed)
        #expect(abs(abs(PathOps.area(p)) - 100) < 0.1)
    }

    @Test func dxfEntitiesBulgeAndUnits() throws {
        let dxf = dxfText([
            "0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "1", "0", "ENDSEC",
            "0", "SECTION", "2", "ENTITIES",
            // Closed LWPOLYLINE: a 2×1 slot with semicircular ends via bulge 1.
            "0", "LWPOLYLINE", "8", "Slots", "90", "4", "70", "1",
            "10", "0", "20", "0", "42", "0",
            "10", "2", "20", "0", "42", "1",
            "10", "2", "20", "1", "42", "0",
            "10", "0", "20", "1", "42", "1",
            "0", "CIRCLE", "8", "Holes", "10", "5", "20", "5", "40", "1",
            "0", "LINE", "8", "Lines", "10", "0", "20", "0", "11", "1", "21", "0",
            "0", "ARC", "8", "Lines", "10", "0", "20", "0", "40", "1", "50", "0", "51", "90",
            "0", "ENDSEC", "0", "EOF",
        ])
        let art = try ArtworkImporter.importDXF(dxf)
        #expect(art.layers.map(\.name) == ["Slots", "Holes", "Lines"])
        let slotArea = PathOps.area(art.layers[0].path) / (25.4 * 25.4)
        #expect(abs(slotArea - (2 + Double.pi * 0.25)) < 0.01)
        let hole = art.layers[1].path.tightBounds()!
        #expect(abs(hole.size.x - 50.8) < 0.01)
        // Line end meets arc start at (1,0): joined into one open path.
        #expect(art.layers[2].path.subpaths.count == 1)
    }

    @Test func dxfPolylineAndSpline() throws {
        let dxf = dxfText([
            "0", "SECTION", "2", "ENTITIES",
            "0", "POLYLINE", "8", "P", "66", "1", "70", "1",
            "0", "VERTEX", "8", "P", "10", "0", "20", "0",
            "0", "VERTEX", "8", "P", "10", "10", "20", "0",
            "0", "VERTEX", "8", "P", "10", "10", "20", "10",
            "0", "SEQEND", "8", "P",
            "0", "SPLINE", "8", "S", "70", "8", "71", "3", "72", "8", "73", "4",
            "40", "0", "40", "0", "40", "0", "40", "0", "40", "1", "40", "1", "40", "1", "40", "1",
            "10", "0", "20", "0", "10", "1", "20", "2", "10", "3", "20", "2", "10", "4", "20", "0",
            "0", "ENDSEC", "0", "EOF",
        ])
        let art = try ArtworkImporter.importDXF(dxf)
        #expect(abs(PathOps.area(art.layers[0].path) - 50) < 1e-6)
        let sb = art.layers[1].path.tightBounds()!
        #expect(abs(sb.max.x - 4) < 1e-6 && abs(sb.max.y - 1.5) < 0.01)
    }

    @Test func pdfPathsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swarf-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 288, height: 144)  // 4 × 2 in
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 72, y: 36)
        ctx.addRect(CGRect(x: 0, y: 0, width: 72, height: 36))
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: 100, y: 0, width: 72, height: 72))
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        let art = try ArtworkImporter.importVector(url: url)
        #expect(art.layers.count == 1)
        let p = art.layers[0].path
        #expect(p.subpaths.count == 2)
        let r = Path2D([p.subpaths[0]]).tightBounds()!
        #expect(abs(r.min.x - 25.4) < 1e-6 && abs(r.min.y - 12.7) < 1e-6 && abs(r.size.x - 25.4) < 1e-6)
        #expect(abs(abs(PathOps.area(Path2D([p.subpaths[1]]))) - Double.pi * 12.7 * 12.7) < 0.5)
    }

    @Test func unsupportedFormats() {
        let url = URL(fileURLWithPath: "/tmp/x.eps")
        #expect(throws: ImportError.self) { try ArtworkImporter.importVector(url: url) }
    }

    func dxfText(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }
}
