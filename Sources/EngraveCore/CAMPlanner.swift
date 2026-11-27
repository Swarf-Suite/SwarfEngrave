// The toolpath planner: pockets (terraced, with islands and an optional clearing bit), profiles (offset, ramps,
// tabs), engraving, and V-carving along the medial axis. Everything is in stock space (Z 0 = stock bottom).

import CAMCore
import Foundation
import simd

/// An area to clear to a floor height.
struct PocketItem {
    var polys: [Polyline2D]  // closed, non-zero winding
    var bottomZ: Double
    var objectID: UUID?
    var bounds: Rect2D { CAMPlanner.bounds(polys) ?? Rect2D(min: .zero, max: .zero) }
}

struct CAMPlanner {
    let sheet: Sheet
    let bits: BitSettings
    let machine: MachineProfile
    let T: Double
    let safeZ: Double
    let hopZ: Double
    let start: V3
    var warnings: [PlanWarning] = []

    init(sheet: Sheet, bits: BitSettings, machine: MachineProfile) {
        self.sheet = sheet
        self.bits = bits
        self.machine = machine
        T = sheet.stock.thickness
        safeZ = T + max(1, bits.safeHeight)
        hopZ = T + min(1, max(0.5, bits.safeHeight))
        let wz = sheet.workZero.origin(for: sheet.stock)
        start = V3(wz.x, wz.y, safeZ)
    }

    /// Feeds and speeds for a bit in this stock, with the feed held to the machine's limit.
    func data(_ tool: Tool) -> CuttingData {
        var d = sheet.stock.material.apply(tool.defaults)
        if machine.maxFeed > 0 { d.feed = min(d.feed, machine.maxFeed); d.plunge = min(d.plunge, machine.maxFeed) }
        d.stepdown = max(0.05, d.stepdown)
        return d
    }

    func sink(_ tool: Tool) -> MoveSink { MoveSink(start: start, safeZ: safeZ, hopZ: hopZ, data: data(tool)) }

    static func bounds(_ polys: [Polyline2D]) -> Rect2D? {
        var r: Rect2D?
        for pl in polys { for p in pl.points { r = r?.including(p) ?? Rect2D(min: p, max: p) } }
        return r
    }

    struct Item {
        let obj: DesignObject
        let closed: [Polyline2D]
        let open: [Polyline2D]
        let bottomZ: Double
    }

    func items() -> [Item] {
        sheet.objects.compactMap { obj in
            guard !obj.hidden, obj.cut.type != .none else { return nil }
            let polys = obj.outline().flattened(tolerance: 0.01).filter { !$0.points.isEmpty }
            guard !polys.isEmpty else { return nil }
            let closed = Raster.fillable(polys)
            let open = polys.filter { pl in
                !pl.closed && !(pl.points.count >= 4 && simd_distance(pl.points[0], pl.points[pl.points.count - 1]) < 0.01)
            }
            let depth = obj.cut.effectiveDepth(thickness: T, overcut: bits.overcut)
            guard depth > 1e-6 || obj.cut.type == .vcarve else { return nil }
            return Item(obj: obj, closed: closed, open: open, bottomZ: T - depth)
        }
    }

    // MARK: Plan

    mutating func plan() -> CarvePlan {
        let all = items()
        let main = bits.main, vbit = bits.vBit
        struct Group { var name: String; var kind: OperationKind; var tool: Tool; var moves: [Move] }
        var groups: [Group] = []

        // V-carve first: it may hand flat floors to the main bit.
        var floors: [PocketItem] = []
        var vEngrave: [(Polyline2D, Double)] = []
        var vs = sink(vbit)
        for it in all where it.obj.cut.type == .vcarve {
            if !it.closed.isEmpty { vcarve(it, vbit: vbit, sink: &vs, floors: &floors) }
            for pl in it.open where it.bottomZ < T - 1e-6 { vEngrave.append((pl, it.bottomZ)) }
        }
        vs.retract()

        var pockets: [PocketItem] = all.filter { $0.obj.cut.type == .pocket && !$0.closed.isEmpty }
            .map { PocketItem(polys: $0.closed, bottomZ: $0.bottomZ, objectID: $0.obj.id) }
        if main.kind != .vBit { pockets += floors }

        if let c = bits.clearing, !pockets.isEmpty {
            var s = sink(c)
            pocket(pockets, tool: c, restAfter: nil, sink: &s)
            s.retract()
            groups.append(Group(name: "Pocket clearing", kind: .pocket, tool: c, moves: s.moves))
        }
        if !vs.moves.isEmpty { groups.append(Group(name: "V-carve", kind: .vcarve, tool: vbit, moves: vs.moves)) }
        if !vEngrave.isEmpty {
            var s = sink(vbit)
            engrave(vEngrave, tool: vbit, sink: &s)
            s.retract()
            groups.append(Group(name: "V-bit engrave", kind: .slot, tool: vbit, moves: s.moves))
        }
        if !pockets.isEmpty {
            var s = sink(main)
            pocket(pockets, tool: main, restAfter: bits.clearing, sink: &s)
            s.retract()
            groups.append(Group(name: bits.clearing == nil ? "Pocket" : "Pocket finish", kind: .pocket, tool: main, moves: s.moves))
        }
        var lines: [(Polyline2D, Double)] = []
        for it in all where it.obj.cut.type == .engrave {
            for pl in it.closed { lines.append((pl, it.bottomZ)) }
            for pl in it.open { lines.append((pl, it.bottomZ)) }
        }
        if !lines.isEmpty {
            var s = sink(main)
            engrave(lines, tool: main, sink: &s)
            s.retract()
            groups.append(Group(name: "Engrave", kind: .slot, tool: main, moves: s.moves))
        }
        let profiles = all.filter { $0.obj.cut.type == .profile }
        if !profiles.isEmpty {
            var s = sink(main)
            profile(profiles, tool: main, sink: &s)
            s.retract()
            groups.append(Group(name: "Profile", kind: .cutout, tool: main, moves: s.moves))
        }

        // Fewest bit changes: keep groups that share a bit together, in order of first use.
        var order: [UUID] = []
        for g in groups where !order.contains(g.tool.id) { order.append(g.tool.id) }
        let sorted = order.flatMap { id in groups.filter { $0.tool.id == id } }.filter { !$0.moves.isEmpty }

        var plan = CarvePlan()
        for g in sorted {
            let d = data(g.tool)
            let tp = Toolpath(id: UUID(), name: g.name, kind: g.kind, tool: g.tool, rpm: d.rpm, start: start, moves: g.moves)
            plan.toolpaths.append(tp)
            plan.seconds.append(tp.stats(rapidRate: machine.rapidRate, acceleration: machine.acceleration).seconds)
        }
        plan.warnings = warnings
        return plan
    }

    // MARK: Pockets

    /// Clears the pockets with `tool`. With `restAfter` (a larger bit that already cleared them), cuts the walls at
    /// every level and only the inner rings that touch material the larger bit could not reach.
    func pocket(_ items: [PocketItem], tool: Tool, restAfter clearing: Tool?, sink: inout MoveSink) {
        let R = tool.radius
        let margin = 1.0
        // Clusters of pockets whose bounds touch are planned together (islands, overlaps).
        var clusters: [[PocketItem]] = []
        var cb: [Rect2D] = []
        for it in items {
            var b = it.bounds
            b = Rect2D(min: b.min - V2(repeating: margin), max: b.max + V2(repeating: margin))
            var members = [it]
            var i = 0
            while i < cb.count {
                if cb[i].intersects(b) {
                    b = b.union(cb[i]); members += clusters[i]
                    clusters.remove(at: i); cb.remove(at: i)
                    i = 0
                } else { i += 1 }
            }
            clusters.append(members); cb.append(b)
        }
        var remaining = Array(clusters.indices)
        while !remaining.isEmpty {
            let here = cam2(sink.pos)
            let k = remaining.min { simd_distance(cb[$0].center, here) < simd_distance(cb[$1].center, here) }!
            remaining.removeAll { $0 == k }
            pocketCluster(clusters[k], tool: tool, R: R, restAfter: clearing, sink: &sink)
        }
    }

    /// Floor height per cell for a set of pockets: the deepest pocket wins, except that a pocket lying entirely
    /// inside deeper ones stays as a raised island at its own depth. Cells with no pocket hold `top`.
    static func floorField(_ items: [PocketItem], frame: RasterFrame, top: Double) -> [Float] {
        let n = frame.count
        let masks = items.map { Raster.mask($0.polys, frame: frame) }
        var minB = [Float](repeating: Float(top), count: n)
        for (k, it) in items.enumerated() {
            let z = Float(it.bottomZ)
            masks[k].withUnsafeBufferPointer { m in for i in 0..<n where m[i] && z < minB[i] { minB[i] = z } }
        }
        var island = [Bool](repeating: false, count: items.count)
        for (k, it) in items.enumerated() {
            var cells = 0, covered = 0
            let z = Float(it.bottomZ) - 1e-4
            masks[k].withUnsafeBufferPointer { m in
                for i in 0..<n where m[i] { cells += 1; if minB[i] < z { covered += 1 } }
            }
            island[k] = cells > 0 && Double(covered) >= 0.99 * Double(cells)
        }
        var floor = [Float](repeating: Float(top), count: n)
        for (k, it) in items.enumerated() where !island[k] {
            let z = Float(it.bottomZ)
            masks[k].withUnsafeBufferPointer { m in for i in 0..<n where m[i] && z < floor[i] { floor[i] = z } }
        }
        // Islands: deepest first, so a shallower island inside a deeper one wins.
        for k in items.indices.filter({ island[$0] }).sorted(by: { items[$0].bottomZ < items[$1].bottomZ }) {
            let z = Float(items[k].bottomZ)
            masks[k].withUnsafeBufferPointer { m in for i in 0..<n where m[i] { floor[i] = z } }
        }
        return floor
    }

    /// Distance inside a mask to its edge (mm); outside: −res/2.
    static func insideDistance(_ mask: [Bool], frame f: RasterFrame) -> [Float] {
        let d = DistanceTransform.distance(width: f.width, height: f.height, res: f.res) { !mask[$0] }
        let h = Float(f.res * 0.5)
        var out = [Float](repeating: -h, count: f.count)
        for i in 0..<f.count where mask[i] { out[i] = min(d[i], 1e6) - h }
        return out
    }

    private func pocketCluster(_ items: [PocketItem], tool: Tool, R: Double, restAfter clearing: Tool?, sink: inout MoveSink) {
        let cd = data(tool)
        let D = tool.diameter
        let res = max(0.05, min(0.2, R / 4))
        guard var rect = items.first?.bounds else { return }
        for it in items { rect = rect.union(it.bounds) }
        let frame = RasterFrame(covering: rect, margin: 4 * res + 0.2, res: res, maxCells: 4_000_000)
        let fr = frame.res
        let floor = Self.floorField(items, frame: frame, top: T)
        let seg = SegmentIndex(items.flatMap(\.polys), cell: max(1, 4 * fr))

        var floorsDesc = Array(Set(items.map { ($0.bottomZ * 1e4).rounded() / 1e4 })).filter { $0 < T - 1e-6 }.sorted(by: >)
        floorsDesc = floorsDesc.filter { f in floor.contains { abs(Double($0) - f) < 1e-3 } }
        var levels: [Double] = []
        var prev = T
        for f in floorsDesc {
            levels += tool.passLevels(top: prev, bottom: f, stepdown: cd.stepdown)
            prev = f
        }
        let stepover = D * max(0.1, min(0.9, cd.stepoverPercent / 100))
        var prevZ = T
        for z in levels {
            defer { prevZ = z }
            var region = [Bool](repeating: false, count: frame.count)
            var any = false
            for i in 0..<frame.count where Double(floor[i]) <= z + 1e-3 { region[i] = true; any = true }
            guard any else { continue }
            let sd = Self.insideDistance(region, frame: frame)
            let maxSd = Double(sd.max() ?? 0)
            guard maxSd > R else { continue }
            var iso: [Double] = []
            var l = R
            while l < maxSd { iso.append(l); l += stepover }
            let grid = frame.grid(sd)
            let raw = Contours.isolines(grid, levels: iso.map { Float($0) })
            var rings: [(k: Int, loop: Loop)] = []
            for (k, loops) in raw.enumerated() {
                for lp in loops where lp.points.count >= 3 {
                    let refined = Polyline.simplify(loop: seg.refine(lp, level: iso[k], tolerance: 2 * fr), tolerance: 0.01)
                    if refined.points.count >= 3 { rings.append((k, refined)) }
                }
            }
            // Rest mode: which cells the clearing bit could not reach at this level.
            var restDist: Grid2D?
            if let c = clearing {
                let Rc = c.radius
                let reach = DistanceTransform.distance(width: frame.width, height: frame.height, res: fr) { sd[$0] >= Float(Rc) }
                var rest = [Bool](repeating: false, count: frame.count)
                var anyRest = false
                for i in 0..<frame.count where region[i] && reach[i] > Float(Rc + 0.5 * fr) { rest[i] = true; anyRest = true }
                if anyRest { restDist = frame.grid(Raster.distance(rest, frame: frame)) }
            }

            // Components: each outer wall with the rings and island walls inside it.
            let walls = rings.indices.filter { rings[$0].k == 0 && rings[$0].loop.signedArea > 0 }
            var owner = [Int](repeating: -1, count: rings.count)
            for (i, r) in rings.enumerated() {
                if rings[i].k == 0 && r.loop.signedArea > 0 { owner[i] = i; continue }
                let p = r.loop.points[0]
                var best = -1, bestA = Double.infinity
                for w in walls where rings[w].loop.contains(p) {
                    let a = abs(rings[w].loop.signedArea)
                    if a < bestA { bestA = a; best = w }
                }
                owner[i] = best >= 0 ? best : i
            }
            var comps: [Int: [Int]] = [:]
            for i in rings.indices { comps[owner[i], default: []].append(i) }
            var compKeys = Array(comps.keys)
            while !compKeys.isEmpty {
                let here = cam2(sink.pos)
                let ck = compKeys.min { simd_distance(rings[$0].loop.points[0], here) < simd_distance(rings[$1].loop.points[0], here) }!
                compKeys.removeAll { $0 == ck }
                var todo = comps[ck]!
                while !todo.isEmpty {
                    // Innermost rings first, then island walls, then the outer wall.
                    func rank(_ i: Int) -> Int { rings[i].k * 2 + (rings[i].k == 0 && rings[i].loop.signedArea > 0 ? 0 : 1) }
                    let top = todo.map(rank).max()!
                    let here2 = cam2(sink.pos)
                    let pick = todo.filter { rank($0) == top }.min { a, b in
                        Self.nearestDistance(rings[a].loop, here2) < Self.nearestDistance(rings[b].loop, here2)
                    }!
                    todo.removeAll { $0 == pick }
                    let ring = rings[pick]
                    if ring.k > 0, clearing != nil {
                        guard let rd = restDist else { continue }
                        cutRuns(ring.loop, keep: { Double(rd.sample($0)) <= R + fr }, z: z, prevZ: prevZ, sink: &sink)
                    } else {
                        cutRing(ring.loop, z: z, prevZ: prevZ, sd: grid, R: R, linkMax: D, sink: &sink)
                    }
                }
            }
        }
    }

    static func nearestDistance(_ loop: Loop, _ p: V2) -> Double {
        var best = Double.infinity
        for q in loop.points { best = min(best, simd_distance_squared(q, p)) }
        return best.squareRoot()
    }

    /// One closed ring at depth `z`: fed straight to from nearby when the link stays inside the pocket, otherwise
    /// approached from above and ramped in from `prevZ`.
    private func cutRing(_ loop: Loop, z: Double, prevZ: Double, sd: Grid2D, R: Double, linkMax: Double, sink: inout MoveSink) {
        let l = loop.starting(near: cam2(sink.pos))
        let L = LoopPath(l.points)
        let p0 = l.points[0]
        let here = cam2(sink.pos)
        let gap = simd_distance(here, p0)
        var direct = abs(sink.pos.z - z) < 1e-6 && gap <= linkMax
        if direct {
            let n = max(1, Int(gap / (sd.res * 0.5)))
            for s in 0...n where Double(sd.sample(here + (p0 - here) * (Double(s) / Double(n)))) < R - sd.res {
                direct = false
                break
            }
        }
        if direct {
            sink.cut(cam3(p0, z))
            sink.cutLoop(L, s0: 0, fromZ: z, toZ: z)
        } else {
            sink.moveTo(p0, approachZ: min(prevZ, T) + 0.5)
            sink.cut(cam3(p0, prevZ))
            sink.cutLoop(L, s0: 0, fromZ: prevZ, toZ: z)
        }
    }

    /// The parts of a ring that pass `keep`, as open runs, each entered from above.
    private func cutRuns(_ loop: Loop, keep: (V2) -> Bool, z: Double, prevZ: Double, sink: inout MoveSink) {
        let pts = loop.points
        let n = pts.count
        let flags = pts.map(keep)
        guard flags.contains(true) else { return }
        if !flags.contains(false) {
            sink.moveTo(pts[0], approachZ: min(prevZ, T) + 0.5)
            sink.cut(cam3(pts[0], z))
            sink.follow((pts + [pts[0]]).map { cam3($0, z) })
            return
        }
        let s = flags.firstIndex(of: false)!
        var run: [V2] = []
        func flush() {
            if run.count >= 2 {
                sink.moveTo(run[0], approachZ: min(prevZ, T) + 0.5)
                sink.cut(cam3(run[0], z))
                sink.follow(run.map { cam3($0, z) })
            }
            run.removeAll()
        }
        for k in 1...n {
            let i = (s + k) % n
            if flags[i] {
                if run.isEmpty { run.append(pts[(i - 1 + n) % n]) }
                run.append(pts[i])
            } else if !run.isEmpty {
                run.append(pts[i])
                flush()
            }
        }
        flush()
    }

    // MARK: Profiles

    private func profile(_ items: [Item], tool: Tool, sink: inout MoveSink) {
        let R = tool.radius, D = tool.diameter
        let cd = data(tool)
        var todo = Array(items.indices)
        while !todo.isEmpty {
            let here = cam2(sink.pos)
            let k = todo.min { a, b in
                let ca = Self.bounds(items[a].closed + items[a].open)?.center ?? .zero
                let cb = Self.bounds(items[b].closed + items[b].open)?.center ?? .zero
                return simd_distance(ca, here) < simd_distance(cb, here)
            }!
            todo.removeAll { $0 == k }
            let it = items[k]
            let cut = it.obj.cut
            var loops: [[V2]] = []
            if !it.closed.isEmpty {
                if cut.profileSide == .on {
                    loops = it.closed.map { $0.signedArea > 0 ? Array($0.points.reversed()) : $0.points }
                } else if let b = Self.bounds(it.closed) {
                    let res = max(0.05, min(0.1, R / 5))
                    let frame = RasterFrame(covering: b, margin: R + 4 * res + 0.5, res: res, maxCells: 4_000_000)
                    let mask = Raster.mask(it.closed, frame: frame)
                    let sd = Raster.signedDistance(mask, frame: frame)
                    let level = cut.profileSide == .outside ? -R : R
                    let seg = SegmentIndex(it.closed, cell: max(1, 4 * frame.res))
                    let raw = Contours.isolines(frame.grid(sd), levels: [Float(level)])[0]
                    for lp in raw where lp.points.count >= 3 {
                        var l = Polyline.simplify(loop: seg.refine(lp, level: level, tolerance: 2 * frame.res), tolerance: 0.005)
                        if l.points.count < 3 { continue }
                        if cut.profileSide == .outside { l = l.reversed() }  // climb: the part on the right
                        loops.append(l.points)
                    }
                }
            }
            loops.sort { abs(Loop($0).signedArea) < abs(Loop($1).signedArea) }  // holes before the outline
            let passes = tool.passLevels(top: T, bottom: it.bottomZ, stepdown: cd.stepdown)

            // Tabs hold through-cut parts.
            var tabTop = -Double.infinity
            var tabPoints: [V2] = []
            if cut.through && cut.tabs.enabled && cut.tabs.length > 0 && cut.tabs.height > 0 {
                tabTop = max(it.bottomZ, 0) + cut.tabs.height
                if tabTop < T - 1e-6 {
                    let fr: [Double] = cut.tabs.positions.isEmpty
                        ? (0..<max(0, cut.tabs.count)).map { (Double($0) + 0.5) / Double(max(1, cut.tabs.count)) }
                        : cut.tabs.positions
                    for pl in it.closed { for f in fr { tabPoints.append(CAMGeometry.point(on: pl, fraction: f)) } }
                } else { tabTop = -.infinity }
            }
            for pts in loops {
                let L = LoopPath(pts)
                guard L.perimeter > 1e-6 else { continue }
                var tabs: [LoopTab] = []
                for tp in tabPoints {
                    let u = L.position(nearest: tp)
                    if simd_distance(L.point(at: u), tp) <= R + 0.6 { tabs.append(LoopTab(center: u, half: (cut.tabs.length + D) / 2)) }
                }
                var s0 = L.position(nearest: cam2(sink.pos))
                for t in tabs {
                    var d = abs(s0 - t.center); d = min(d, L.perimeter - d)
                    if d < t.half { s0 = L.wrap(t.center + t.half + 0.5) }
                }
                let p0 = L.point(at: s0)
                sink.moveTo(p0, approachZ: T + 0.5)
                sink.cut(cam3(p0, T))
                var s = s0, zPrev = T
                for z in passes {
                    s = sink.cutLoop(L, s0: s, fromZ: zPrev, toZ: z, tabs: tabs, tabTop: tabTop)
                    zPrev = z
                }
            }
            // Open paths can only be cut on the line.
            if !it.open.isEmpty { engrave(it.open.map { ($0, it.bottomZ) }, tool: tool, sink: &sink) }
        }
    }

    // MARK: Engrave

    /// The bit centre along each line at its depth, in stepdown passes.
    private func engrave(_ lines: [(Polyline2D, Double)], tool: Tool, sink: inout MoveSink) {
        let cd = data(tool)
        var todo = Array(lines.indices)
        while !todo.isEmpty {
            let here = cam2(sink.pos)
            func dist(_ i: Int) -> Double {
                let pts = lines[i].0.points
                if lines[i].0.closed { return Self.nearestDistance(Loop(pts), here) }
                return min(simd_distance(pts[0], here), simd_distance(pts[pts.count - 1], here))
            }
            let k = todo.min { dist($0) < dist($1) }!
            todo.removeAll { $0 == k }
            let (pl, bottom) = lines[k]
            let passes = tool.passLevels(top: T, bottom: bottom, stepdown: cd.stepdown)
            if pl.closed && pl.points.count >= 3 {
                let L = LoopPath(pl.points)
                let s0 = L.position(nearest: here)
                let p0 = L.point(at: s0)
                sink.moveTo(p0, approachZ: T + 0.5)
                sink.cut(cam3(p0, T))
                var s = s0, zPrev = T
                for z in passes { s = sink.cutLoop(L, s0: s, fromZ: zPrev, toZ: z); zPrev = z }
            } else {
                var pts = pl.points
                if pts.count > 1 && simd_distance(pts[pts.count - 1], here) < simd_distance(pts[0], here) { pts.reverse() }
                sink.moveTo(pts[0], approachZ: T + 0.5)
                for (i, z) in passes.enumerated() {
                    let seq = i % 2 == 0 ? pts : pts.reversed()
                    sink.cut(cam3(seq[0], z))
                    sink.follow(seq.map { cam3($0, z) })
                }
            }
        }
    }

    // MARK: V-carve

    private mutating func vcarve(_ it: Item, vbit: Tool, sink: inout MoveSink, floors: inout [PocketItem]) {
        let cd = data(vbit)
        let tanH = tan(max(1, vbit.vAngle / 2) * .pi / 180)
        let tip = vbit.tipDiameter / 2
        guard let b = Self.bounds(it.closed) else { return }
        let minSide = min(b.size.x, b.size.y)
        let res = max(0.03, min(0.1, minSide / 150))
        let frame = RasterFrame(covering: b, margin: 4 * res + 0.2, res: res, maxCells: 3_000_000)
        let fr = frame.res
        let mask = Raster.mask(it.closed, frame: frame)
        let sdv = Self.insideDistance(mask, frame: frame)
        let grid = frame.grid(sdv)
        let seg = SegmentIndex(it.closed, cell: max(1, 4 * fr))
        let maxSd = Double(sdv.max() ?? 0)
        guard maxSd > 0 else { return }

        func edgeDistance(_ p: V2) -> Double {
            let g = Double(grid.sample(p))
            if let (d, _) = seg.nearest(p, within: max(0, g) + 2 * fr), abs(d - g) <= 1.5 * fr { return d }
            return max(0, g - 0.5 * fr)
        }
        func natural(_ d: Double) -> Double { max(0, (d - tip) / tanH) }

        let naturalMax = natural(maxSd)
        let capUser = it.obj.cut.vcarveMaxDepth.map { max(0.01, $0) } ?? .infinity
        let capWidth = max(0.01, (vbit.radius - tip) / tanH)
        let capFlute = max(0.01, vbit.fluteLength)
        let capStock = T + bits.overcut
        let cap = min(capUser, capWidth, capFlute, capStock)
        if naturalMax > capFlute + 1e-6 && capFlute <= min(capUser, capWidth, capStock) {
            warnings.append(PlanWarning(objectID: it.obj.id, severity: .warning, message: String(
                format: "“%@” would V-carve %.1f mm deep, past the V-bit's %.1f mm flute length; it is limited to the flute length.",
                it.obj.name, naturalMax, capFlute)))
        }
        let bottom = min(cap, naturalMax)

        // Medial axis chains, with free ends run out into the corners.
        let skel = Skeleton.thin(mask, width: frame.width, height: frame.height)
        let W = frame.width
        func skelDegree(_ i: Int) -> Int {
            let x = i % W, y = i / W
            guard x > 0, y > 0, x < W - 1, y < frame.height - 1 else { return 0 }
            var c = 0
            for o in [W, W + 1, 1, -W + 1, -W, -W - 1, -1, W - 1] where skel[i + o] { c += 1 }
            return c
        }
        var chains: [[V3]] = []
        for ch in Skeleton.trace(skel, width: W, height: frame.height) where ch.cells.count >= 2 {
            var pts = ch.cells.map { frame.world($0 % W, $0 / W) }
            pts = CAMGeometry.smooth(pts, closed: ch.closed, passes: 2)
            if !ch.closed {
                if skelDegree(ch.cells[ch.cells.count - 1]) <= 1 { pts += extend(pts, reversed: false, edge: edgeDistance, grid: grid, res: fr) }
                if skelDegree(ch.cells[0]) <= 1 { pts = extend(pts, reversed: true, edge: edgeDistance, grid: grid, res: fr).reversed() + pts }
            }
            var v = pts.map { cam3($0, T - min(cap, natural(edgeDistance($0)))) }
            if ch.closed, let f = v.first { v.append(f) }
            v = Polyline.simplify(v, tolerance: 0.01)
            if v.count >= 2 { chains.append(v) }
        }

        // Sharp convex corners: the medial axis runs along the bisector from the corner itself (thinning loses it).
        for pl in it.closed {
            let pts = pl.points, n = pts.count
            guard n >= 3 else { continue }
            for i in 0..<n {
                let v = pts[i], a = pts[(i - 1 + n) % n], c = pts[(i + 1) % n]
                let la = simd_distance(a, v), lc = simd_distance(c, v)
                guard la > 1e-6, lc > 1e-6 else { continue }
                let e1 = (a - v) / la, e2 = (c - v) / lc
                let cosT = max(-1, min(1, simd_dot(e1, e2)))
                let theta = acos(cosT)
                guard theta < 150 * .pi / 180, theta > 1e-3 else { continue }
                let bis = simd_normalize(e1 + e2)
                guard grid.sample(v + bis * (2 * fr)) > 0 else { continue }  // reflex corner
                let sinH = sin(theta / 2)
                var run: [V2] = [v]
                var t = fr * 0.5
                while t < maxSd / max(sinH, 1e-3) + fr {
                    let p = v + bis * t
                    let d = edgeDistance(p)
                    if d < t * sinH - 0.5 * fr { break }
                    run.append(p)
                    t += fr * 0.5
                }
                guard run.count >= 3 else { continue }
                let v3 = Polyline.simplify(run.map { cam3($0, T - min(cap, natural(min(edgeDistance($0), simd_distance($0, v) * sinH)))) }, tolerance: 0.01)
                if v3.count >= 2 { chains.append(v3) }
            }
        }

        // Where the depth is capped, the floor edge is traced at the cap and the main bit clears the floor.
        var capLoops: [LoopPath] = []
        if cap < naturalMax - 1e-6 {
            let rLim = cap * tanH + tip
            for lp in Contours.isolines(grid, levels: [Float(rLim)])[0] where lp.points.count >= 3 {
                let l = Polyline.simplify(loop: seg.refine(lp, level: rLim, tolerance: 2 * fr), tolerance: 0.01)
                if l.points.count >= 3 { capLoops.append(LoopPath(l.points)) }
            }
            if !capLoops.isEmpty {
                floors.append(PocketItem(polys: capLoops.map { Polyline2D($0.pts, closed: true) }, bottomZ: T - cap, objectID: it.obj.id))
            }
        }

        let passes = vbit.passLevels(top: T, bottom: T - bottom, stepdown: cd.stepdown)
        var zPrev = T
        for z in passes {
            // Runs of each chain deeper than the previous pass, with one neighbour either side.
            var runs: [[V3]] = []
            for c in chains {
                var run: [V3] = []
                for i in c.indices {
                    let deep = c[i].z < zPrev - 1e-6
                    let nearDeep = deep || (i > 0 && c[i - 1].z < zPrev - 1e-6) || (i + 1 < c.count && c[i + 1].z < zPrev - 1e-6)
                    if nearDeep { run.append(V3(c[i].x, c[i].y, max(c[i].z, z))) } else if !run.isEmpty {
                        if run.count >= 2 { runs.append(run) }
                        run = []
                    }
                }
                if run.count >= 2 { runs.append(run) }
            }
            var left = Array(runs.indices)
            while !left.isEmpty {
                let here = cam2(sink.pos)
                func d(_ i: Int) -> Double { min(simd_distance(cam2(runs[i][0]), here), simd_distance(cam2(runs[i][runs[i].count - 1]), here)) }
                let k = left.min { d($0) < d($1) }!
                left.removeAll { $0 == k }
                var r = runs[k]
                if simd_distance(cam2(r[r.count - 1]), here) < simd_distance(cam2(r[0]), here) { r.reverse() }
                sink.moveTo(cam2(r[0]), approachZ: min(max(zPrev, r[0].z), T) + 0.5)
                sink.cut(r[0])
                sink.follow(r)
            }
            let zc = max(T - cap, z)
            for L in capLoops where zc < zPrev - 1e-6 || z <= T - cap + 1e-6 {
                let s0 = L.position(nearest: cam2(sink.pos))
                let p0 = L.point(at: s0)
                sink.moveTo(p0, approachZ: min(zPrev, T) + 0.5)
                sink.cut(cam3(p0, zPrev))
                sink.cutLoop(L, s0: s0, fromZ: zPrev, toZ: zc)
            }
            zPrev = z
        }
    }

    /// Points continuing a chain end in its last direction while the edge distance keeps falling (into a corner).
    private func extend(_ pts: [V2], reversed: Bool, edge: (V2) -> Double, grid: Grid2D, res: Double) -> [V2] {
        let seq = reversed ? Array(pts.reversed()) : pts
        guard seq.count >= 2 else { return [] }
        let end = seq[seq.count - 1]
        let back = seq[max(0, seq.count - 4)]
        var dir = end - back
        let l = simd_length(dir)
        guard l > 1e-9 else { return [] }
        dir /= l
        var out: [V2] = []
        var p = end
        var dPrev = edge(end)
        for _ in 0..<400 {
            let q = p + dir * (res * 0.5)
            guard grid.sample(q) > -Float(res) else { break }
            let dq = edge(q)
            if dq >= dPrev - 1e-6 { break }
            out.append(q)
            p = q; dPrev = dq
            if dq < 0.01 { break }
        }
        return out
    }
}
