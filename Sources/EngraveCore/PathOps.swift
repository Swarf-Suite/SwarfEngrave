// Boolean operations, offsets and simplification on flattened paths.
//
// The clipper works on an integer grid (10 nm) with exact orientation tests: every edge is split where it meets
// another (iterating until snapping makes no new crossings), coincident pieces are merged with their winding
// contributions summed (so collinear and overlapping edges are harmless), the winding numbers on both sides of each
// piece are found by exact ray casting, and the pieces that separate "inside" from "outside" for the operation are
// chained into loops. Results have outer boundaries counter-clockwise and holes clockwise, line segments only.

import CAMCore
import Foundation
import simd

public enum FillRule: String, Codable, Sendable, CaseIterable { case nonZero, evenOdd }

public enum PathOps {
    /// Curves are flattened to this many mm before clipping.
    public static let flatteningTolerance = 0.01

    /// Everything inside any of the paths (each filled with `fillRule`).
    public static func union(_ paths: [Path2D], fillRule: FillRule = .nonZero) -> Path2D {
        if paths.count == 1 { return resolve(paths[0], fillRule: fillRule) }
        let eng = ClipEngine()
        for p in paths {
            // Normalise each operand on its own so that orientations can't cancel between paths.
            eng.add(resolveLoops(p, fillRule: fillRule), operand: 0)
        }
        return path(eng.run { a, _ in a > 0 })
    }

    /// `a` with `b` cut away.
    public static func subtract(_ a: Path2D, _ b: Path2D, fillRule: FillRule = .nonZero) -> Path2D {
        binary(a, b, fillRule) { $0 && !$1 }
    }

    /// Only where `a` and `b` overlap.
    public static func intersect(_ a: Path2D, _ b: Path2D, fillRule: FillRule = .nonZero) -> Path2D {
        binary(a, b, fillRule) { $0 && $1 }
    }

    /// Where exactly one of `a` and `b` is (XOR).
    public static func exclude(_ a: Path2D, _ b: Path2D, fillRule: FillRule = .nonZero) -> Path2D {
        binary(a, b, fillRule) { $0 != $1 }
    }

    /// The filled area of one path as simple loops (self-overlaps merged, outer CCW, holes CW).
    public static func resolve(_ p: Path2D, fillRule: FillRule = .nonZero) -> Path2D {
        path(resolveLoops(p, fillRule: fillRule))
    }

    /// Grows (positive) or shrinks (negative) the filled area by `distance` mm, with round joins.
    /// Open subpaths are grown into round-ended bands when `distance` is positive and dropped otherwise.
    public static func offset(_ p: Path2D, by distance: Double, tolerance: Double = 0.01) -> Path2D {
        let d = abs(distance)
        let closedPart = Path2D(p.subpaths.filter { $0.closed })
        let openLines = p.subpaths.filter { !$0.closed }.isEmpty ? [] :
            Path2D(p.subpaths.filter { !$0.closed }).flattened(tolerance: flatteningTolerance).map(\.points)
        let base = resolveLoops(closedPart, fillRule: .nonZero)
        guard d > 1e-9 else { return path(base) }

        let tol = max(1e-4, min(tolerance, d / 2))
        let stepAngle = 2 * acos(max(-1, 1 - tol / d))
        let outward = distance > 0
        var band: [[V2]] = []

        func arc(_ v: V2, _ from: V2, _ sweep: Double) -> [V2] {
            let n = max(1, Int((abs(sweep) / stepAngle).rounded(.up)))
            let a0 = atan2(from.y, from.x)
            return (0...n).map { k in
                let a = a0 + sweep * Double(k) / Double(n)
                return v + d * V2(cos(a), sin(a))
            }
        }
        func addCCW(_ poly: [V2]) {
            guard poly.count >= 3 else { return }
            let a = Polyline2D(poly, closed: true).signedArea
            if abs(a) < 1e-12 { return }
            band.append(a > 0 ? poly : poly.reversed())
        }

        for loop in base {
            let n = loop.count
            guard n >= 3 else { continue }
            for i in 0..<n {
                let a = loop[i], b = loop[(i + 1) % n], c = loop[(i + 2) % n]
                let e1 = b - a, e2 = c - b
                let l1 = simd_length(e1), l2 = simd_length(e2)
                guard l1 > 1e-12, l2 > 1e-12 else { continue }
                // Interior is on the left; the offset side is the right (outward) or the left (inward).
                let s: Double = outward ? 1 : -1
                let n1 = s * V2(e1.y, -e1.x) / l1
                addCCW([a, b, b + d * n1, a + d * n1])
                // Wedge at b where the offset side opens up (convex corner as seen from that side).
                let cr = e1.x * e2.y - e1.y * e2.x
                let turn = atan2(cr, simd_dot(e1, e2))
                if outward ? turn > 1e-9 : turn < -1e-9 {
                    addCCW([b] + arc(b, n1, turn))
                }
            }
        }
        if outward {
            for pts in openLines where pts.count >= 2 {
                for i in 0..<(pts.count - 1) {
                    let a = pts[i], b = pts[i + 1]
                    let e = b - a
                    let l = simd_length(e)
                    guard l > 1e-12 else { continue }
                    let nr = V2(e.y, -e.x) / l
                    addCCW([a - d * nr, b - d * nr, b + d * nr, a + d * nr])
                }
                for v in pts { addCCW(Array(arc(v, V2(1, 0), 2 * .pi).dropLast())) }
            }
        }

        let eng = ClipEngine()
        eng.add(base, operand: 0)
        eng.add(band, operand: 1)
        if outward { return path(eng.run { a, b in a > 0 || b > 0 }) }
        return path(eng.run { a, b in a > 0 && b == 0 })
    }

    /// Fewer points: curves flattened, then Douglas–Peucker to `tolerance` mm. Keeps open subpaths open.
    public static func simplify(_ p: Path2D, tolerance: Double = 0.05) -> Path2D {
        var out = Path2D()
        for pl in p.flattened(tolerance: max(1e-4, tolerance / 4)) {
            let pts: [V2]
            if pl.closed {
                pts = pl.points.count > 3 ? TraceEngine.simplifyClosed(pl.points, tolerance: tolerance) : pl.points
                guard pts.count >= 3 else { continue }
            } else {
                pts = douglasPeucker(pl.points, tolerance)
                guard pts.count >= 2 else { continue }
            }
            out.subpaths.append(SubPath(start: pts[0], segments: pts.dropFirst().map { .line($0) }, closed: pl.closed))
        }
        return out
    }

    /// Filled area of a path under the fill rule (mm²).
    public static func area(_ p: Path2D, fillRule: FillRule = .nonZero) -> Double {
        resolveLoops(p, fillRule: fillRule).reduce(0) { $0 + Polyline2D($1, closed: true).signedArea }
    }

    // MARK: Internals

    static func binary(_ a: Path2D, _ b: Path2D, _ rule: FillRule, _ op: @escaping (Bool, Bool) -> Bool) -> Path2D {
        let eng = ClipEngine()
        eng.add(loops(a), operand: 0)
        eng.add(loops(b), operand: 1)
        let inside: (Int32) -> Bool = rule == .nonZero ? { $0 != 0 } : { $0 & 1 != 0 }
        return path(eng.run { op(inside($0), inside($1)) })
    }

    static func loops(_ p: Path2D) -> [[V2]] {
        p.flattened(tolerance: flatteningTolerance).map(\.points).filter { $0.count >= 3 }
    }

    static func resolveLoops(_ p: Path2D, fillRule: FillRule) -> [[V2]] {
        let eng = ClipEngine()
        eng.add(loops(p), operand: 0)
        if fillRule == .nonZero { return eng.run { a, _ in a != 0 } }
        return eng.run { a, _ in a & 1 != 0 }
    }

    static func path(_ loops: [[V2]]) -> Path2D {
        Path2D(loops.filter { $0.count >= 3 }.map { SubPath(start: $0[0], segments: $0.dropFirst().map { .line($0) }, closed: true) })
    }

    static func douglasPeucker(_ pts: [V2], _ eps: Double) -> [V2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let ab = pts[b] - pts[a]
            let len = simd_length(ab)
            var maxD = -1.0, idx = a
            for i in (a + 1)..<b {
                let ap = pts[i] - pts[a]
                let dd = len < 1e-12 ? simd_length(ap) : abs(ab.x * ap.y - ab.y * ap.x) / len
                if dd > maxD { maxD = dd; idx = i }
            }
            if maxD > eps {
                keep[idx] = true
                stack.append((a, idx)); stack.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}

// MARK: Clipping engine

struct ClipPoint: Hashable {
    var x: Int64
    var y: Int64
    @inline(__always) static func < (a: ClipPoint, b: ClipPoint) -> Bool { a.x < b.x || (a.x == b.x && a.y < b.y) }
}

@inline(__always) func clipOrient(_ a: ClipPoint, _ b: ClipPoint, _ c: ClipPoint) -> Int {
    let v = Int128(b.x - a.x) * Int128(c.y - a.y) - Int128(b.y - a.y) * Int128(c.x - a.x)
    return v > 0 ? 1 : (v < 0 ? -1 : 0)
}

struct ClipEdge {
    var a: ClipPoint
    var b: ClipPoint
    var w0: Int32
    var w1: Int32
}

final class ClipEngine {
    static let scale = 1e5  // grid units per mm
    var edges: [ClipEdge] = []

    func q(_ p: V2) -> ClipPoint {
        ClipPoint(x: Int64((p.x * Self.scale).rounded()), y: Int64((p.y * Self.scale).rounded()))
    }

    func add(_ loops: [[V2]], operand: Int) {
        for loop in loops {
            var pts: [ClipPoint] = []
            pts.reserveCapacity(loop.count)
            for v in loop {
                guard v.x.isFinite, v.y.isFinite else { continue }
                let p = q(v)
                if pts.last != p { pts.append(p) }
            }
            while pts.count > 1 && pts.first == pts.last { pts.removeLast() }
            guard pts.count >= 3 else { continue }
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                edges.append(ClipEdge(a: a, b: b, w0: operand == 0 ? 1 : 0, w1: operand == 0 ? 0 : 1))
            }
        }
    }

    /// Loops (in mm) bounding the region where `inside(winding0, winding1)` holds.
    func run(_ inside: (Int32, Int32) -> Bool) -> [[V2]] {
        guard !edges.isEmpty else { return [] }
        let pieces = Self.merge(Self.splitAll(edges))
        guard !pieces.isEmpty else { return [] }
        let (left, right) = Self.windings(pieces)
        var out: [(ClipPoint, ClipPoint)] = []
        for (i, e) in pieces.enumerated() {
            let li = inside(left[i].0, left[i].1), ri = inside(right[i].0, right[i].1)
            if li && !ri { out.append((e.a, e.b)) } else if ri && !li { out.append((e.b, e.a)) }
        }
        return Self.chain(out).map { loop in loop.map { V2(Double($0.x) / Self.scale, Double($0.y) / Self.scale) } }
    }

    // MARK: Splitting

    static func splitAll(_ input: [ClipEdge]) -> [ClipEdge] {
        var cur = input.filter { $0.a != $0.b }
        for _ in 0..<10 {
            let n = cur.count
            var splits = [[ClipPoint]](repeating: [], count: n)
            var any = false
            var minX = [Int64](repeating: 0, count: n), maxX = minX, minY = minX, maxY = minX
            for i in 0..<n {
                let e = cur[i]
                minX[i] = min(e.a.x, e.b.x); maxX[i] = max(e.a.x, e.b.x)
                minY[i] = min(e.a.y, e.b.y); maxY[i] = max(e.a.y, e.b.y)
            }
            let order = (0..<n).sorted { minX[$0] < minX[$1] }
            var active: [Int] = []
            for i in order {
                let x0 = minX[i]
                var k = 0
                while k < active.count {
                    if maxX[active[k]] < x0 { active[k] = active[active.count - 1]; active.removeLast() } else { k += 1 }
                }
                for j in active where !(minY[i] > maxY[j] || maxY[i] < minY[j]) {
                    if intersect(cur[i], cur[j], i, j, &splits) { any = true }
                }
                active.append(i)
            }
            if !any { return cur }
            var next: [ClipEdge] = []
            next.reserveCapacity(n + n / 4)
            for i in 0..<n {
                let e = cur[i]
                if splits[i].isEmpty { next.append(e); continue }
                let d = (Double(e.b.x - e.a.x), Double(e.b.y - e.a.y))
                var pts = splits[i].map { p -> (Double, ClipPoint) in
                    (Double(p.x - e.a.x) * d.0 + Double(p.y - e.a.y) * d.1, p)
                }
                pts.sort { $0.0 < $1.0 }
                var prev = e.a
                for (_, p) in pts where p != prev && p != e.b {
                    next.append(ClipEdge(a: prev, b: p, w0: e.w0, w1: e.w1))
                    prev = p
                }
                if prev != e.b { next.append(ClipEdge(a: prev, b: e.b, w0: e.w0, w1: e.w1)) }
            }
            cur = next
        }
        return cur
    }

    @inline(__always) static func strictlyInside(_ a: ClipPoint, _ b: ClipPoint, _ p: ClipPoint) -> Bool {
        p != a && p != b && p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
    }

    /// Records split points for edges i and j; returns whether any were added.
    static func intersect(_ e: ClipEdge, _ f: ClipEdge, _ i: Int, _ j: Int, _ splits: inout [[ClipPoint]]) -> Bool {
        let a1 = e.a, a2 = e.b, b1 = f.a, b2 = f.b
        if (a1 == b1 && a2 == b2) || (a1 == b2 && a2 == b1) { return false }
        let o1 = clipOrient(a1, a2, b1), o2 = clipOrient(a1, a2, b2)
        if o1 * o2 > 0 { return false }
        let o3 = clipOrient(b1, b2, a1), o4 = clipOrient(b1, b2, a2)
        if o3 * o4 > 0 { return false }
        var any = false
        if o1 == 0 && o2 == 0 {
            // Collinear: split each at the other's endpoints that lie inside it.
            if strictlyInside(a1, a2, b1) { splits[i].append(b1); any = true }
            if strictlyInside(a1, a2, b2) { splits[i].append(b2); any = true }
            if strictlyInside(b1, b2, a1) { splits[j].append(a1); any = true }
            if strictlyInside(b1, b2, a2) { splits[j].append(a2); any = true }
            return any
        }
        if o1 == 0 || o2 == 0 || o3 == 0 || o4 == 0 {
            if o1 == 0, strictlyInside(a1, a2, b1) { splits[i].append(b1); any = true }
            if o2 == 0, strictlyInside(a1, a2, b2) { splits[i].append(b2); any = true }
            if o3 == 0, strictlyInside(b1, b2, a1) { splits[j].append(a1); any = true }
            if o4 == 0, strictlyInside(b1, b2, a2) { splits[j].append(a2); any = true }
            return any
        }
        // Proper crossing.
        let rx = Int128(a2.x - a1.x), ry = Int128(a2.y - a1.y)
        let sx = Int128(b2.x - b1.x), sy = Int128(b2.y - b1.y)
        let den = rx * sy - ry * sx
        guard den != 0 else { return false }
        let num = Int128(b1.x - a1.x) * sy - Int128(b1.y - a1.y) * sx
        let t = Double(num) / Double(den)
        let p = ClipPoint(x: a1.x + Int64((Double(rx) * t).rounded()), y: a1.y + Int64((Double(ry) * t).rounded()))
        if p != a1 && p != a2 { splits[i].append(p); any = true }
        if p != b1 && p != b2 { splits[j].append(p); any = true }
        return any
    }

    // MARK: Merging

    struct Key: Hashable { var a: ClipPoint; var b: ClipPoint }

    /// Unique undirected pieces, directed from the lexicographically smaller end, with summed signed windings.
    static func merge(_ edges: [ClipEdge]) -> [ClipEdge] {
        var index: [Key: Int] = [:]
        index.reserveCapacity(edges.count)
        var out: [ClipEdge] = []
        out.reserveCapacity(edges.count)
        for e in edges where e.a != e.b {
            let fwd = e.a < e.b
            let k = fwd ? Key(a: e.a, b: e.b) : Key(a: e.b, b: e.a)
            let s: Int32 = fwd ? 1 : -1
            if let i = index[k] {
                out[i].w0 += s * e.w0
                out[i].w1 += s * e.w1
            } else {
                index[k] = out.count
                out.append(ClipEdge(a: k.a, b: k.b, w0: s * e.w0, w1: s * e.w1))
            }
        }
        return out.filter { $0.w0 != 0 || $0.w1 != 0 }
    }

    // MARK: Windings

    /// Winding numbers (operand 0, operand 1) just left and just right of each piece, by exact ray casting from
    /// its midpoint: a horizontal ray for non-horizontal pieces, a vertical one for horizontal pieces.
    static func windings(_ e: [ClipEdge]) -> ([(Int32, Int32)], [(Int32, Int32)]) {
        let n = e.count
        var left = [(Int32, Int32)](repeating: (0, 0), count: n)
        var right = left

        // Bands over y for the horizontal rays.
        var y0 = Int64.max, y1 = Int64.min, x0 = Int64.max, x1 = Int64.min
        for f in e {
            y0 = min(y0, f.a.y, f.b.y); y1 = max(y1, f.a.y, f.b.y)
            x0 = min(x0, f.a.x, f.b.x); x1 = max(x1, f.a.x, f.b.x)
        }
        let nb = max(1, min(4096, Int(Double(n).squareRoot() * 2)))
        func bands(lo: Int64, hi: Int64, key: (ClipEdge) -> (Int64, Int64), use: (ClipEdge) -> Bool) -> (Int64, [[Int32]]) {
            let h = max(1, (hi - lo) / Int64(nb) + 1)
            var b = [[Int32]](repeating: [], count: nb)
            for (i, f) in e.enumerated() where use(f) {
                let (u, v) = key(f)
                let s = Int((min(u, v) - lo) / h), t = Int((max(u, v) - lo) / h)
                for k in s...min(t, nb - 1) { b[k].append(Int32(i)) }
            }
            return (h, b)
        }
        let (hy, yb) = bands(lo: y0, hi: y1, key: { ($0.a.y, $0.b.y) }, use: { $0.a.y != $0.b.y })
        let hasHorizontal = e.contains { $0.a.y == $0.b.y }
        let (hx, xb) = hasHorizontal ? bands(lo: x0, hi: x1, key: { ($0.a.x, $0.b.x) }, use: { $0.a.x != $0.b.x }) : (1, [])

        for i in 0..<n {
            let g = e[i]
            let m = ClipPoint(x: g.a.x + g.b.x, y: g.a.y + g.b.y)  // doubled coordinates
            var w0: Int32 = 0, w1: Int32 = 0
            if g.a.y != g.b.y {
                let band = min(nb - 1, max(0, Int(((m.y >> 1) - y0) / hy)))
                for jj in yb[band] {
                    let j = Int(jj)
                    if j == i { continue }
                    let f = e[j]
                    let up = f.a.y < f.b.y
                    let p = up ? f.a : f.b, qq = up ? f.b : f.a
                    guard 2 * p.y <= m.y && m.y < 2 * qq.y else { continue }
                    let p2 = ClipPoint(x: 2 * p.x, y: 2 * p.y), q2 = ClipPoint(x: 2 * qq.x, y: 2 * qq.y)
                    if clipOrient(p2, q2, m) > 0 {  // crossing lies to the right of m
                        let s: Int32 = up ? 1 : -1
                        w0 += s * f.w0; w1 += s * f.w1
                    }
                }
                // (w0, w1) is the winding just right (+x) of m.
                if g.a.y < g.b.y {
                    left[i] = (w0 + g.w0, w1 + g.w1); right[i] = (w0, w1)
                } else {
                    left[i] = (w0, w1); right[i] = (w0 - g.w0, w1 - g.w1)
                }
            } else {
                let band = min(nb - 1, max(0, Int(((m.x >> 1) - x0) / hx)))
                for jj in xb[band] {
                    let j = Int(jj)
                    if j == i { continue }
                    let f = e[j]
                    // Non-vertical pieces always run in +x (merge directs them from the smaller x).
                    guard 2 * f.a.x <= m.x && m.x < 2 * f.b.x else { continue }
                    let p2 = ClipPoint(x: 2 * f.a.x, y: 2 * f.a.y), q2 = ClipPoint(x: 2 * f.b.x, y: 2 * f.b.y)
                    if clipOrient(p2, q2, m) < 0 {  // m is below f: the upward ray crosses it
                        w0 -= f.w0; w1 -= f.w1
                    }
                }
                // (w0, w1) is the winding just above m; g runs in +x so above is its left.
                left[i] = (w0, w1); right[i] = (w0 - g.w0, w1 - g.w1)
            }
        }
        return (left, right)
    }

    // MARK: Chaining

    static func chain(_ edges: [(ClipPoint, ClipPoint)]) -> [[ClipPoint]] {
        var outgoing: [ClipPoint: [Int]] = [:]
        outgoing.reserveCapacity(edges.count)
        for (i, e) in edges.enumerated() { outgoing[e.0, default: []].append(i) }
        var used = [Bool](repeating: false, count: edges.count)
        var loops: [[ClipPoint]] = []
        for s in edges.indices where !used[s] {
            var loop: [ClipPoint] = []
            var i = s
            let start = edges[s].0
            while true {
                used[i] = true
                let (a, b) = edges[i]
                loop.append(a)
                if b == start { break }
                guard let cands = outgoing[b] else { break }
                var best = -1
                var bestAngle = Double.infinity
                let rev = atan2(Double(a.y - b.y), Double(a.x - b.x))
                for c in cands where !used[c] {
                    let d = edges[c].1
                    let ang = atan2(Double(d.y - b.y), Double(d.x - b.x))
                    // Clockwise angle from the reversed incoming direction: the tightest left-hand face.
                    var cw = rev - ang
                    while cw <= 1e-12 { cw += 2 * .pi }
                    while cw > 2 * .pi { cw -= 2 * .pi }
                    if cw < bestAngle { bestAngle = cw; best = c }
                }
                if best < 0 { break }
                i = best
            }
            // Drop collinear vertices.
            var pts = loop
            var changed = true
            while changed && pts.count >= 3 {
                changed = false
                var cleaned: [ClipPoint] = []
                cleaned.reserveCapacity(pts.count)
                let m = pts.count
                for k in 0..<m {
                    let p = cleaned.last ?? pts[(k + m - 1) % m]
                    if clipOrient(p, pts[k], pts[(k + 1) % m]) == 0 { changed = true; continue }
                    cleaned.append(pts[k])
                }
                pts = cleaned
            }
            if pts.count >= 3 { loops.append(pts) }
        }
        return loops
    }
}
