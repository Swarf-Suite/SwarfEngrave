import CAMCore
import Foundation
import simd
import Testing
import EngraveCore

@Suite("CAM")
struct CAMTests {
    static func object(_ name: String, _ g: ObjectGeometry, at p: V2, _ type: CutType, depth: Double = 3) -> DesignObject {
        var o = DesignObject(name: name, geometry: g, transform: Transform2D(position: p))
        o.cut = CutSettings(type: type, depth: depth)
        return o
    }

    static func sheet(_ objects: [DesignObject], w: Double = 100, h: Double = 100, t: Double = 10) -> Sheet {
        Sheet(stock: Stock(width: w, height: h, thickness: t, materialID: "mdf"), objects: objects)
    }

    static func cuttingPoints(_ plan: CarvePlan) -> [V3] {
        plan.toolpaths.flatMap { $0.moves.filter { $0.kind != .rapid }.map(\.to) }
    }

    @Test func pocketDepthAndAreaMatchInSimulation() {
        let s = Self.sheet([Self.object("P", .rectangle(width: 40, height: 30, cornerRadius: 0), at: V2(50, 50), .pocket, depth: 3)])
        let bits = BitSettings()
        let plan = CutPlanner.plan(sheet: s, bits: bits, machine: .grbl)
        #expect(plan.toolpaths.count == 1)
        #expect(plan.toolpaths.first?.kind == .pocket)
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        var cells = 0
        var minZ = Float.infinity
        for v in g.data {
            if v < 10 - 1.5 { cells += 1 }
            minZ = min(minZ, v)
        }
        let area = Double(cells) * 0.2 * 0.2
        #expect(abs(area - 1200) < 1200 * 0.03, "area \(area)")
        #expect(abs(Double(minZ) - 7) < 0.05, "floor \(minZ)")
        // The floor is flat: nothing left standing in the middle.
        #expect(abs(Double(g.sample(V2(50, 50))) - 7) < 0.05)
        #expect(abs(Double(g.sample(V2(31, 36))) - 7) < 0.1)
        #expect(Double(g.sample(V2(29, 50))) > 9.99)  // outside the wall
        #expect(plan.totalSeconds > 0)
    }

    @Test func islandStaysAtItsOwnDepth() {
        let s = Self.sheet([
            Self.object("Outer", .rectangle(width: 60, height: 60, cornerRadius: 0), at: V2(50, 50), .pocket, depth: 5),
            Self.object("Island", .rectangle(width: 20, height: 20, cornerRadius: 0), at: V2(50, 50), .pocket, depth: 2),
        ])
        let plan = CutPlanner.plan(sheet: s, bits: BitSettings(), machine: .grbl)
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        #expect(abs(Double(g.sample(V2(50, 50))) - 8) < 0.05)
        #expect(abs(Double(g.sample(V2(30, 30))) - 5) < 0.05)
        let p = CarvePreview.surface(sheet: s, bits: BitSettings(), resolution: 0.25)
        #expect(abs(Double(p.sample(V2(50, 50))) - 8) < 0.01)
        #expect(abs(Double(p.sample(V2(30, 30))) - 5) < 0.01)
    }

    @Test func clearingBitThenMainBit() {
        var bits = BitSettings()
        let lib = ToolLibrary.starter
        bits.clearing = lib.tools.first { $0.kind == .flat && $0.diameter > 5 }
        guard bits.clearing != nil else { return }
        let s = Self.sheet([Self.object("P", .rectangle(width: 50, height: 40, cornerRadius: 0), at: V2(50, 50), .pocket, depth: 3)])
        let plan = CutPlanner.plan(sheet: s, bits: bits, machine: .grbl)
        #expect(plan.toolpaths.map(\.tool.id) == [bits.clearing!.id, bits.main.id])
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        var cells = 0
        for v in g.data where v < 10 - 1.5 { cells += 1 }
        #expect(abs(Double(cells) * 0.04 - 2000) < 2000 * 0.03)
        #expect(abs(Double(g.sample(V2(25.8, 30.8))) - 7) < 0.1)  // corner reached by the small bit
    }

    @Test func outsideProfileOfSquareCutsSquarePlusDiameter() {
        var o = Self.object("Sq", .rectangle(width: 50, height: 50, cornerRadius: 0), at: V2(50, 50), .profile, depth: 6)
        o.cut.through = true
        o.cut.profileSide = .outside
        o.cut.tabs.enabled = false
        let s = Self.sheet([o], t: 6)
        let bits = BitSettings()
        let plan = CutPlanner.plan(sheet: s, bits: bits, machine: .grbl)
        #expect(plan.toolpaths.count == 1)
        #expect(plan.toolpaths[0].kind == .cutout)
        let pts = Self.cuttingPoints(plan)
        let bottom = pts.map(\.z).min()!
        #expect(abs(bottom - (-bits.overcut)) < 1e-6)
        let deep = pts.filter { $0.z < bottom + 1e-6 }
        let xs = deep.map(\.x), ys = deep.map(\.y)
        let D = bits.main.diameter
        #expect(abs((xs.max()! - xs.min()!) - (50 + D)) < 0.05)
        #expect(abs((ys.max()! - ys.min()!) - (50 + D)) < 0.05)
        // Climb with a clockwise spindle: clockwise around the part (negative signed area of the path).
        var area = 0.0
        for i in 1..<deep.count { area += deep[i - 1].x * deep[i].y - deep[i].x * deep[i - 1].y }
        #expect(area < 0)
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        #expect(Double(g.sample(V2(50, 50))) > 5.99)  // the part
        #expect(Double(g.sample(V2(50 + 25 + D / 2, 50))) <= 0)  // the groove, through
        #expect(Double(g.sample(V2(50 + 25 + D + 1, 50))) > 5.99)  // the waste beyond it
    }

    @Test func insideProfileStaysInside() {
        var o = Self.object("Sq", .rectangle(width: 50, height: 50, cornerRadius: 0), at: V2(50, 50), .profile, depth: 2)
        o.cut.profileSide = .inside
        let plan = CutPlanner.plan(sheet: Self.sheet([o]), bits: BitSettings(), machine: .grbl)
        let pts = Self.cuttingPoints(plan).filter { $0.z < 9.99 }
        let D = BitSettings().main.diameter
        #expect(abs((pts.map(\.x).max()! - pts.map(\.x).min()!) - (50 - D)) < 0.05)
    }

    @Test func tabsArePresent() {
        var o = Self.object("Sq", .rectangle(width: 50, height: 50, cornerRadius: 0), at: V2(50, 50), .profile, depth: 6)
        o.cut.through = true
        o.cut.tabs.enabled = true
        o.cut.tabs.count = 4
        o.cut.tabs.height = 2
        o.cut.tabs.length = 6
        let s = Self.sheet([o], t: 6)
        let plan = CutPlanner.plan(sheet: s, bits: BitSettings(), machine: .grbl)
        let pts = Self.cuttingPoints(plan)
        #expect(pts.contains { abs($0.z - 2) < 1e-6 })
        #expect(abs(pts.map(\.z).min()! + 0.3) < 1e-6)
        // Four bridges on the groove in the simulation, at the tab height; the rest cut through.
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        let R = BitSettings().main.radius
        let off = 25 + R
        var bridges = 0, inTab = false, through = 0
        let n = 2000
        for i in 0..<n {
            let t = Double(i) / Double(n) * 4
            let side = Int(t), f = t - Double(side)
            let p: V2
            switch side {
            case 0: p = V2(50 - 25 + 50 * f, 50 - off)
            case 1: p = V2(50 + off, 50 - 25 + 50 * f)
            case 2: p = V2(50 + 25 - 50 * f, 50 + off)
            default: p = V2(50 - off, 50 + 25 - 50 * f)
            }
            let z = Double(g.sample(p))
            if abs(z - 2) < 0.1 { if !inTab { bridges += 1 }; inTab = true } else { inTab = false }
            if z <= 0 { through += 1 }
        }
        #expect(bridges == 4)
        #expect(through > n / 2)
    }

    @Test func vcarveStripDepthFromWidth() {
        let w = 4.0
        let s = Self.sheet([Self.object("Strip", .rectangle(width: w, height: 60, cornerRadius: 0), at: V2(50, 50), .vcarve)])
        let bits = BitSettings()
        #expect(bits.vBit.vAngle == 60)
        let plan = CutPlanner.plan(sheet: s, bits: bits, machine: .grbl)
        #expect(plan.toolpaths.first?.kind == .vcarve)
        let deepest = 10 - Self.cuttingPoints(plan).map(\.z).min()!
        let expected = w / 2 / tan(30 * Double.pi / 180)
        #expect(abs(deepest - expected) < 0.03, "deepest \(deepest) expected \(expected)")
        let g = CarvePreview.surface(sheet: s, bits: bits, resolution: 0.1)
        #expect(abs((10 - Double(g.sample(V2(50, 50)))) - expected) < 0.1)
        // The V reaches into the corners.
        let corner = Self.cuttingPoints(plan).map { simd_distance(V2($0.x, $0.y), V2(48, 20)) }.min()!
        #expect(corner < 0.3, "corner \(corner)")
    }

    @Test func vcarveDepthLimitGivesFlatFloor() {
        var o = Self.object("Wide", .rectangle(width: 20, height: 30, cornerRadius: 0), at: V2(50, 50), .vcarve)
        o.cut.vcarveMaxDepth = 2
        let s = Self.sheet([o])
        let plan = CutPlanner.plan(sheet: s, bits: BitSettings(), machine: .grbl)
        #expect(plan.toolpaths.map(\.kind) == [.vcarve, .pocket])
        let vMin = plan.toolpaths[0].moves.filter { $0.kind != .rapid }.map(\.to.z).min()!
        #expect(abs(vMin - 8) < 1e-6)
        let g = CarvePreview.simulate(sheet: s, toolpaths: plan.toolpaths, resolution: 0.2)
        #expect(abs(Double(g.sample(V2(50, 50))) - 8) < 0.05)
    }

    @Test func engraveFollowsLineAtDepth() {
        let s = Self.sheet([Self.object("L", .line(length: 40), at: V2(50, 50), .engrave, depth: 1.5)])
        let plan = CutPlanner.plan(sheet: s, bits: BitSettings(), machine: .grbl)
        #expect(plan.toolpaths.first?.kind == .slot)
        let pts = Self.cuttingPoints(plan)
        #expect(abs(pts.map(\.z).min()! - 8.5) < 1e-6)
        #expect(abs(pts.map(\.x).max()! - pts.map(\.x).min()! - 40) < 1e-6)
    }

    @Test func ordersForFewestBitChanges() {
        let s = Self.sheet([
            Self.object("A", .rectangle(width: 20, height: 20, cornerRadius: 0), at: V2(25, 25), .profile, depth: 2),
            Self.object("B", .star(points: 5, outerRadius: 10, innerRadius: 5), at: V2(70, 70), .vcarve),
            Self.object("C", .rectangle(width: 20, height: 20, cornerRadius: 0), at: V2(25, 70), .pocket, depth: 2),
            Self.object("D", .line(length: 20), at: V2(70, 20), .engrave, depth: 1),
        ])
        let plan = CutPlanner.plan(sheet: s, bits: BitSettings(), machine: .grbl)
        #expect(plan.toolpaths.map(\.kind) == [.vcarve, .pocket, .slot, .cutout])
        var changes = 0
        for i in 1..<plan.toolpaths.count where plan.toolpaths[i].tool.id != plan.toolpaths[i - 1].tool.id { changes += 1 }
        #expect(changes == 1)
        #expect(plan.seconds.count == plan.toolpaths.count)
        // Rapids stay at or above the stock top unless they drop straight down onto the work.
        let safe = 10 + BitSettings().safeHeight
        #expect(plan.toolpaths.allSatisfy { abs($0.moves.last!.to.z - safe) < 1e-9 })
    }

    @Test func checkWarnings() {
        var bits = BitSettings()
        bits.vBit.fluteLength = 2
        var deep = Self.object("Deep", .rectangle(width: 20, height: 20, cornerRadius: 0), at: V2(30, 30), .pocket, depth: 15)
        deep.cut.through = false
        let objects = [
            Self.object("Off", .rectangle(width: 10, height: 10, cornerRadius: 0), at: V2(300, 300), .pocket),
            Self.object("Edge", .rectangle(width: 10, height: 10, cornerRadius: 0), at: V2(98, 50), .pocket),
            deep,
            Self.object("Narrow", .rectangle(width: 2, height: 30, cornerRadius: 0), at: V2(70, 30), .pocket),
            Self.object("Wide V", .rectangle(width: 20, height: 20, cornerRadius: 0), at: V2(70, 70), .vcarve),
            Self.object("Open", .line(length: 20), at: V2(30, 80), .pocket),
            Self.object("Text", .text(TextSpec(string: "")), at: V2(50, 50), .vcarve),
            Self.object("Fine", .rectangle(width: 10, height: 10, cornerRadius: 0), at: V2(50, 50), .pocket),
        ]
        let w = CutPlanner.check(sheet: Self.sheet(objects), bits: bits)
        func has(_ i: Int, _ text: String) -> Bool { w.contains { $0.objectID == objects[i].id && $0.message.contains(text) } }
        #expect(has(0, "off the stock"))
        #expect(w.first { $0.objectID == objects[0].id }?.severity == .error)
        #expect(has(1, "partly off"))
        #expect(has(2, "Through"))
        #expect(has(3, "narrower"))
        #expect(has(4, "flute"))
        #expect(has(5, "open path"))
        #expect(has(6, "no outline"))
        #expect(!w.contains { $0.objectID == objects[7].id })
    }
}
