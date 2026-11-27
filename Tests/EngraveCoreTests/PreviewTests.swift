import CAMCore
import Foundation
import Testing
import EngraveCore

@Suite("Preview")
struct PreviewTests {
    static func busySheet() -> Sheet {
        var objects: [DesignObject] = []
        func add(_ g: ObjectGeometry, _ p: V2, _ type: CutType, depth: Double = 3, configure: (inout CutSettings) -> Void = { _ in }) {
            var o = DesignObject(name: "o\(objects.count)", geometry: g, transform: Transform2D(position: p))
            o.cut = CutSettings(type: type, depth: depth)
            configure(&o.cut)
            objects.append(o)
        }
        add(.rectangle(width: 290, height: 190, cornerRadius: 10), V2(150, 100), .profile, depth: 12) { $0.through = true }
        add(.rectangle(width: 80, height: 60, cornerRadius: 5), V2(60, 140), .pocket, depth: 4)
        add(.ellipse(width: 30, height: 20), V2(60, 140), .pocket, depth: 2)
        add(.star(points: 5, outerRadius: 40, innerRadius: 18), V2(220, 110), .vcarve)
        add(.star(points: 7, outerRadius: 20, innerRadius: 10), V2(150, 150), .vcarve) { $0.vcarveMaxDepth = 1.5 }
        add(.line(length: 120), V2(150, 25), .engrave, depth: 1)
        for i in 0..<10 { add(.ellipse(width: 12, height: 12), V2(30 + Double(i) * 15, 60), .vcarve) }
        add(.polygon(sides: 6, radius: 25), V2(100, 90), .profile, depth: 3) { $0.profileSide = .inside }
        return Sheet(stock: Stock(width: 300, height: 200, thickness: 12), objects: objects)
    }

    @Test func surfaceIsFast() {
        let s = Self.busySheet()
        let bits = BitSettings()
        _ = CarvePreview.surface(sheet: s, bits: bits)  // warm up
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = Date()
            let g = CarvePreview.surface(sheet: s, bits: bits)
            best = min(best, Date().timeIntervalSince(t0) * 1000)
            #expect(g.res >= 0.25 && g.res <= 0.5)
        }
        print("preview 300×200 mm: \(String(format: "%.1f", best)) ms")
        #expect(best < 150)
    }

    @Test func surfaceShowsEachCut() {
        let s = Self.busySheet()
        let bits = BitSettings()
        let g = CarvePreview.surface(sheet: s, bits: bits, resolution: 0.25)
        #expect(g.data.count == g.width * g.height)
        #expect(abs(Double(g.sample(V2(30, 140))) - 8) < 0.01)  // pocket floor
        #expect(abs(Double(g.sample(V2(60, 140))) - 10) < 0.01)  // ellipse inside the deeper pocket: island
        #expect(Double(g.sample(V2(150, 25))) < 11.01)  // engraved line
        #expect(abs(Double(g.sample(V2(150, 24.9))) - 11) < 0.01)
        #expect(Double(g.sample(V2(150, 100 - 95 - bits.main.radius))) <= 0)  // through profile groove
        #expect(abs(Double(g.sample(V2(150, 150))) - 10.5) < 0.01)  // capped V-carve floor
        #expect(abs(Double(g.sample(V2(5, 5))) - 12) < 0.01)  // untouched stock outside the groove... (corner)
    }

    @Test func vGrooveForVBitEngraving() {
        var o = DesignObject(name: "L", geometry: .line(length: 40), transform: Transform2D(position: V2(50, 50)))
        o.cut = CutSettings(type: .engrave, depth: 2)
        let bits = BitSettings(main: BitSettings().vBit)
        let g = CarvePreview.surface(sheet: Sheet(stock: Stock(width: 100, height: 100, thickness: 10), objects: [o]), bits: bits, resolution: 0.1)
        #expect(abs(Double(g.sample(V2(50, 50))) - 8) < 0.01)
        let half = tan(30 * Double.pi / 180)
        #expect(abs(Double(g.sample(V2(50, 50.5))) - (8 + 0.5 / half)) < 0.05)
    }
}
