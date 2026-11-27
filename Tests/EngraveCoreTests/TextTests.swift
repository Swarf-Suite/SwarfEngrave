import CAMCore
import Foundation
import Testing
@testable import EngraveCore

@Suite struct TextTests {
    @Test func helveticaOutlineIsNonEmptyAndCentred() {
        let p = TextOutliner.path(for: TextSpec(string: "Hello", fontName: "Helvetica", size: 20))
        #expect(!p.isEmpty)
        let b = p.tightBounds()!
        #expect(abs(b.center.x) < 1e-6 && abs(b.center.y) < 1e-6)
        #expect(p.subpaths.contains { $0.segments.contains { if case .line = $0 { return false } else { return true } } })
    }

    @Test func capHeightScaling() {
        // "H" is exactly cap height tall in Helvetica.
        for size in [10.0, 25.0] {
            let p = TextOutliner.path(for: TextSpec(string: "H", fontName: "Helvetica", size: size))
            let h = p.tightBounds()!.size.y
            #expect(abs(h - size) < 0.02 * size)
        }
        var em = TextSpec(string: "H", fontName: "Helvetica", size: 20)
        em.sizeMode = .em
        let h = TextOutliner.path(for: em).tightBounds()!.size.y
        #expect(h < 20 && h > 12)  // cap height ≈ 0.717 em
    }

    @Test func trackingWidensAndLinesStack() {
        var a = TextSpec(string: "ABC", fontName: "Helvetica", size: 10)
        let w0 = TextOutliner.path(for: a).tightBounds()!.size.x
        a.tracking = 2
        let w1 = TextOutliner.path(for: a).tightBounds()!.size.x
        #expect(abs((w1 - w0) - 4) < 0.05)
        let two = TextOutliner.path(for: TextSpec(string: "H\nH", fontName: "Helvetica", size: 10))
        #expect(abs(two.tightBounds()!.size.y - (10 + 12)) < 0.3)
    }

    @Test func missingFontFallsBack() {
        #expect(TextOutliner.isInstalled("Helvetica"))
        #expect(!TextOutliner.isInstalled("NoSuchFont-Regular-XYZ"))
        let p = TextOutliner.path(for: TextSpec(string: "A", fontName: "NoSuchFont-Regular-XYZ", size: 10))
        #expect(!p.isEmpty)
        #expect(TextOutliner.resolvedFontName(for: TextSpec(string: "A", fontName: "NoSuchFont-Regular-XYZ")) == "Helvetica")
    }

    @Test func arcLayoutBendsText() {
        var s = TextSpec(string: "ABCDEFGH", fontName: "Helvetica", size: 10)
        s.layout = .arc(radius: 30, top: true)
        let b = TextOutliner.path(for: s).tightBounds()!
        let straight = TextOutliner.path(for: TextSpec(string: "ABCDEFGH", fontName: "Helvetica", size: 10)).tightBounds()!
        #expect(b.size.y > straight.size.y + 3)
        #expect(b.size.x < straight.size.x)
        s.layout = .arc(radius: 30, top: false)
        #expect(!TextOutliner.path(for: s).isEmpty)
    }

    @Test func onPathFollowsAPath() {
        var s = TextSpec(string: "WAVE", fontName: "Helvetica", size: 8)
        var guide = Path2D()
        guide.move(to: V2(0, 0)); guide.line(to: V2(0, 100))  // vertical guide: text runs upward
        s.layout = .onPath(guide)
        let b = TextOutliner.path(for: s).tightBounds()!
        #expect(b.size.y > b.size.x)
    }

    @Test func variableFontAxes() {
        // SF Pro (system font) is variable on recent macOS; skip quietly if not.
        let families = FontCatalog.families()
        #expect(families.contains("Helvetica"))
        #expect(families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let faces = FontCatalog.faces(family: "Helvetica")
        #expect(faces.contains { $0.postScriptName == "Helvetica-Bold" })
        if let face = FontCatalog.families().lazy.flatMap({ FontCatalog.faces(family: $0) })
            .first(where: { f in FontCatalog.axes(postScriptName: f.postScriptName).contains { $0.tag == "wght" } }) {
            let axis = FontCatalog.axes(postScriptName: face.postScriptName).first { $0.tag == "wght" }!
            var thin = TextSpec(string: "O", fontName: face.postScriptName, size: 20)
            thin.variations = ["wght": axis.min]
            var bold = thin
            bold.variations = ["wght": axis.max]
            let at = PathOps.area(TextOutliner.path(for: thin)), ab = PathOps.area(TextOutliner.path(for: bold))
            #expect(ab > at)
        }
    }

    @Test func cachedCallIsFast() {
        let s = TextSpec(string: "Cache me", fontName: "Helvetica-Bold", size: 12)
        _ = TextOutliner.path(for: s)
        let t0 = Date()
        for _ in 0..<1000 { _ = TextOutliner.path(for: s) }
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }
}
