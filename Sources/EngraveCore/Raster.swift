// Raster helpers shared by the toolpath planner and the fast preview: non-zero winding fill of vector outlines,
// signed distance fields, distance to lines, exact nearest-edge queries, thinning (medial axis) and chain tracing.

import CAMCore
import Foundation
import simd

@inline(__always) func cam3(_ p: V2, _ z: Double) -> V3 { V3(p.x, p.y, z) }
@inline(__always) func cam2(_ p: V3) -> V2 { V2(p.x, p.y) }

/// A grid window over stock space with the `Grid2D` convention: cell (i, j) centre at `origin + (i, j) * res`.
struct RasterFrame {
    var origin: V2
    var res: Double
    var width: Int
    var height: Int

    /// Frame covering `rect` grown by `margin`, at `res`, with the resolution coarsened so it holds at most `maxCells`.
    init(covering rect: Rect2D, margin: Double, res r0: Double, maxCells: Int = 6_000_000) {
        let lo = rect.min - V2(repeating: margin), hi = rect.max + V2(repeating: margin)
        let size = hi - lo
        var r = r0
        let need = (size.x / r + 1) * (size.y / r + 1)
        if need > Double(maxCells) { r *= (need / Double(maxCells)).squareRoot() }
        origin = lo
        res = r
        width = max(2, Int((size.x / r).rounded(.up)) + 1)
        height = max(2, Int((size.y / r).rounded(.up)) + 1)
    }

    init(origin: V2, res: Double, width: Int, height: Int) {
        self.origin = origin; self.res = res; self.width = width; self.height = height
    }

    var count: Int { width * height }
    @inline(__always) func world(_ x: Int, _ y: Int) -> V2 { V2(origin.x + Double(x) * res, origin.y + Double(y) * res) }
    func grid(_ data: [Float]) -> Grid2D {
        var g = Grid2D(origin: origin, res: res, width: width, height: height, fill: 0)
        g.data = data
        return g
    }
}

enum Raster {
    /// Closed polylines for filling. Open subpaths whose ends meet (within 0.01 mm) count as closed; others are dropped.
    static func fillable(_ polys: [Polyline2D]) -> [Polyline2D] {
        polys.compactMap { p in
            if p.closed { return p.points.count >= 3 ? p : nil }
            if p.points.count >= 4, simd_distance(p.points[0], p.points[p.points.count - 1]) < 0.01 {
                return Polyline2D(Array(p.points.dropLast()), closed: true)
            }
            return nil
        }
    }

    /// Marks cells whose centres are inside the polygons by the non-zero winding rule.
    static func fill(_ polys: [Polyline2D], frame f: RasterFrame, into mask: inout [Bool]) {
        let W = f.width, H = f.height, res = f.res, ox = f.origin.x, oy = f.origin.y
        var rows = [[(Double, Int8)]](repeating: [], count: H)
        for pl in polys where pl.closed && pl.points.count >= 3 {
            let pts = pl.points
            for i in pts.indices {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                if p.y == q.y { continue }
                let dir: Int8 = q.y > p.y ? 1 : -1
                let ylo = min(p.y, q.y), yhi = max(p.y, q.y)
                let j0 = max(0, Int(((ylo - oy) / res).rounded(.up)))
                let j1 = min(H - 1, Int(((yhi - oy) / res).rounded(.up)) - 1)
                if j0 > j1 { continue }
                let k = (q.x - p.x) / (q.y - p.y)
                for j in j0...j1 {
                    let y = oy + Double(j) * res
                    if y < ylo || y >= yhi { continue }
                    rows[j].append((p.x + (y - p.y) * k, dir))
                }
            }
        }
        mask.withUnsafeMutableBufferPointer { m in
            for j in 0..<H where rows[j].count >= 2 {
                let xs = rows[j].sorted { $0.0 < $1.0 }
                var wind = 0
                for k in 0..<(xs.count - 1) {
                    wind += Int(xs[k].1)
                    guard wind != 0 else { continue }
                    let a = max(0, Int(((xs[k].0 - ox) / res).rounded(.up)))
                    let b = min(W - 1, Int(((xs[k + 1].0 - ox) / res).rounded(.up)) - 1)
                    if a <= b { for i in a...b { m[j * W + i] = true } }
                }
            }
        }
    }

    static func mask(_ polys: [Polyline2D], frame f: RasterFrame) -> [Bool] {
        var m = [Bool](repeating: false, count: f.count)
        fill(polys, frame: f, into: &m)
        return m
    }

    /// Signed distance (mm) to the mask's edge: positive inside, negative outside, zero roughly on the true edge.
    static func signedDistance(_ mask: [Bool], frame f: RasterFrame) -> [Float] {
        let dIn = DistanceTransform.distance(width: f.width, height: f.height, res: f.res) { !mask[$0] }
        let dOut = DistanceTransform.distance(width: f.width, height: f.height, res: f.res) { mask[$0] }
        let h = Float(f.res * 0.5)
        var out = [Float](repeating: 0, count: f.count)
        for i in 0..<f.count { out[i] = mask[i] ? min(dIn[i], 1e6) - h : -(min(dOut[i], 1e6) - h) }
        return out
    }

    /// Distance from each cell to the nearest feature cell (mm).
    static func distance(_ feature: [Bool], frame f: RasterFrame) -> [Float] {
        DistanceTransform.distance(width: f.width, height: f.height, res: f.res) { feature[$0] }
    }

    /// Cells crossed by the polylines (sampled at a third of a cell), for a distance-to-line field.
    static func strokeCells(_ polys: [Polyline2D], frame f: RasterFrame) -> [Bool] {
        var m = [Bool](repeating: false, count: f.count)
        for pl in polys {
            let pts = pl.closed ? pl.points + [pl.points[0]] : pl.points
            for i in 1..<max(1, pts.count) {
                let a = pts[i - 1], b = pts[i]
                let n = max(1, Int((simd_distance(a, b) / (f.res / 3)).rounded(.up)))
                for s in 0...n {
                    let p = a + (b - a) * (Double(s) / Double(n))
                    let x = Int(((p.x - f.origin.x) / f.res).rounded()), y = Int(((p.y - f.origin.y) / f.res).rounded())
                    if x >= 0, y >= 0, x < f.width, y < f.height { m[y * f.width + x] = true }
                }
            }
        }
        return m
    }

    /// Exact distance from each cell centre to the polylines, within `reach` mm (beyond it: `reach`). For grooves.
    static func lineDistance(_ polys: [Polyline2D], frame f: RasterFrame, reach: Double) -> [Float] {
        var d = [Float](repeating: Float(reach), count: f.count)
        let W = f.width, H = f.height
        for pl in polys {
            let pts = pl.closed ? pl.points + [pl.points[0]] : pl.points
            if pts.count == 1 {
                stampSegment(pts[0], pts[0], f, reach, &d, W, H)
            }
            for i in 1..<max(1, pts.count) { stampSegment(pts[i - 1], pts[i], f, reach, &d, W, H) }
        }
        return d
    }

    @inline(__always) private static func stampSegment(_ a: V2, _ b: V2, _ f: RasterFrame, _ reach: Double, _ d: inout [Float], _ W: Int, _ H: Int) {
        let lo = simd_min(a, b) - V2(repeating: reach), hi = simd_max(a, b) + V2(repeating: reach)
        let x0 = max(0, Int(((lo.x - f.origin.x) / f.res).rounded(.up))), x1 = min(W - 1, Int(((hi.x - f.origin.x) / f.res).rounded(.down)))
        let y0 = max(0, Int(((lo.y - f.origin.y) / f.res).rounded(.up))), y1 = min(H - 1, Int(((hi.y - f.origin.y) / f.res).rounded(.down)))
        if x0 > x1 || y0 > y1 { return }
        let ab = b - a, l2 = simd_length_squared(ab)
        d.withUnsafeMutableBufferPointer { buf in
            for y in y0...y1 {
                let py = f.origin.y + Double(y) * f.res
                for x in x0...x1 {
                    let p = V2(f.origin.x + Double(x) * f.res, py)
                    let t = l2 > 1e-18 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
                    let dist = Float(simd_distance(p, a + ab * t))
                    if dist < buf[y * W + x] { buf[y * W + x] = dist }
                }
            }
        }
    }
}

/// Bucketed line segments for exact nearest-edge queries.
struct SegmentIndex {
    private var a: [V2] = []
    private var b: [V2] = []
    private var buckets: [[Int32]] = []
    private var origin = V2.zero
    private var cell = 2.0
    private var nx = 0, ny = 0

    init(_ polys: [Polyline2D], cell: Double = 2) {
        self.cell = cell
        var lo = V2(repeating: .infinity), hi = V2(repeating: -.infinity)
        for pl in polys {
            let pts = pl.points
            guard pts.count >= 2 else { continue }
            for i in 0..<(pl.closed ? pts.count : pts.count - 1) {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                a.append(p); b.append(q)
                lo = simd_min(lo, simd_min(p, q)); hi = simd_max(hi, simd_max(p, q))
            }
        }
        guard !a.isEmpty else { return }
        origin = lo
        nx = max(1, Int(((hi.x - lo.x) / cell).rounded(.down)) + 1)
        ny = max(1, Int(((hi.y - lo.y) / cell).rounded(.down)) + 1)
        buckets = [[Int32]](repeating: [], count: nx * ny)
        for i in a.indices {
            let l = simd_min(a[i], b[i]), h = simd_max(a[i], b[i])
            let i0 = Int((l.x - lo.x) / cell), i1 = min(nx - 1, Int((h.x - lo.x) / cell))
            let j0 = Int((l.y - lo.y) / cell), j1 = min(ny - 1, Int((h.y - lo.y) / cell))
            for j in j0...j1 { for k in i0...i1 { buckets[j * nx + k].append(Int32(i)) } }
        }
    }

    var isEmpty: Bool { a.isEmpty }

    /// Nearest point on any segment within `reach` of `p`.
    func nearest(_ p: V2, within reach: Double) -> (dist: Double, point: V2)? {
        guard !a.isEmpty else { return nil }
        let i0 = max(0, Int(((p.x - reach - origin.x) / cell).rounded(.down))), i1 = min(nx - 1, Int(((p.x + reach - origin.x) / cell).rounded(.down)))
        let j0 = max(0, Int(((p.y - reach - origin.y) / cell).rounded(.down))), j1 = min(ny - 1, Int(((p.y + reach - origin.y) / cell).rounded(.down)))
        if i0 > i1 || j0 > j1 { return nil }
        var best = reach * reach, bp: V2? = nil
        for j in j0...j1 {
            for k in i0...i1 {
                for s in buckets[j * nx + k] {
                    let sa = a[Int(s)], ab = b[Int(s)] - sa
                    let l2 = simd_length_squared(ab)
                    let t = l2 > 1e-18 ? max(0, min(1, simd_dot(p - sa, ab) / l2)) : 0
                    let q = sa + ab * t
                    let d2 = simd_distance_squared(p, q)
                    if d2 < best { best = d2; bp = q }
                }
            }
        }
        return bp.map { (best.squareRoot(), $0) }
    }

    /// Moves contour points (on the grid's offset at `level` mm from the edge; negative = outside) onto the exact
    /// offset of the true outline, where the grid and the exact distance agree to within `tolerance`.
    func refine(_ loop: Loop, level: Double, tolerance: Double) -> Loop {
        guard !a.isEmpty else { return loop }
        let r = abs(level)
        return Loop(loop.points.map { p in
            guard let (d, q) = nearest(p, within: r + tolerance), abs(d - r) < tolerance, d > 1e-9 else { return p }
            return q + (p - q) * (r / d)
        })
    }
}

enum Skeleton {
    /// Zhang–Suen thinning of a mask to a one-cell-wide, 8-connected medial axis.
    static func thin(_ mask: [Bool], width W: Int, height H: Int) -> [Bool] {
        var img = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) where mask[i] { img[i] = 1 }
        // Grid edges count as background.
        for x in 0..<W { img[x] = 0; img[(H - 1) * W + x] = 0 }
        for y in 0..<H { img[y * W] = 0; img[y * W + W - 1] = 0 }
        var candidates = [Int]()
        for i in 0..<(W * H) where img[i] == 1 { candidates.append(i) }
        var changed = true
        var remove = [Int]()
        while changed {
            changed = false
            for step in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for i in candidates where img[i] == 1 {
                    // Neighbours P2..P9 clockwise from north (north = +y).
                    let n = img[i + W], ne = img[i + W + 1], e = img[i + 1], se = img[i - W + 1]
                    let s = img[i - W], sw = img[i - W - 1], w = img[i - 1], nw = img[i + W - 1]
                    let nb = [n, ne, e, se, s, sw, w, nw]
                    var bCount = 0
                    for v in nb { bCount += Int(v) }
                    if bCount < 2 || bCount > 6 { continue }
                    var aCount = 0
                    for k in 0..<8 where nb[k] == 0 && nb[(k + 1) % 8] == 1 { aCount += 1 }
                    if aCount != 1 { continue }
                    if step == 0 {
                        if n * e * s != 0 || e * s * w != 0 { continue }
                    } else {
                        if n * e * w != 0 || n * s * w != 0 { continue }
                    }
                    remove.append(i)
                }
                if !remove.isEmpty {
                    changed = true
                    for i in remove { img[i] = 0 }
                }
            }
            candidates = candidates.filter { img[$0] == 1 }
        }
        return img.map { $0 == 1 }
    }

    /// Chains of skeleton cells between end points and junctions, plus closed cycles.
    static func trace(_ skel: [Bool], width W: Int, height H: Int) -> [(cells: [Int], closed: Bool)] {
        let offs = [W, W + 1, 1, -W + 1, -W, -W - 1, -1, W - 1]
        func neighbours(_ i: Int) -> [Int] {
            let x = i % W, y = i / W
            guard x > 0, y > 0, x < W - 1, y < H - 1 else { return [] }
            return offs.compactMap { skel[i + $0] ? i + $0 : nil }
        }
        var deg = [UInt8](repeating: 0, count: W * H)
        var cells = [Int]()
        for i in 0..<(W * H) where skel[i] { cells.append(i); deg[i] = UInt8(neighbours(i).count) }
        func isNode(_ i: Int) -> Bool { deg[i] != 2 }
        var visited = Set<Int>()  // visited non-node cells
        var usedPair = Set<Int64>()
        var out: [(cells: [Int], closed: Bool)] = []
        for start in cells where isNode(start) {
            if deg[start] == 0 { out.append(([start], false)); continue }
            for nb in neighbours(start) {
                if isNode(nb) {
                    let key = Int64(min(start, nb)) << 32 | Int64(max(start, nb))
                    if usedPair.insert(key).inserted { out.append(([start, nb], false)) }
                    continue
                }
                if visited.contains(nb) { continue }
                var chain = [start, nb]
                visited.insert(nb)
                var prev = start, cur = nb
                while true {
                    guard let nxt = neighbours(cur).first(where: { $0 != prev && !visited.contains($0) && !(isNode($0) && $0 == start && chain.count < 3) }) else { break }
                    chain.append(nxt)
                    if isNode(nxt) { break }
                    visited.insert(nxt)
                    prev = cur; cur = nxt
                }
                out.append((chain, false))
            }
        }
        // Cycles with no nodes.
        for start in cells where !isNode(start) && !visited.contains(start) {
            var chain = [start]
            visited.insert(start)
            var cur = start
            while let nxt = neighbours(cur).first(where: { !visited.contains($0) }) {
                chain.append(nxt); visited.insert(nxt); cur = nxt
            }
            if chain.count >= 3 { out.append((chain, true)) } else { out.append((chain, false)) }
        }
        return out
    }
}
