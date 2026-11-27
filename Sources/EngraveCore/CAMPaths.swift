// Move building for SwarfEngrave toolpaths: linking, ramps along closed loops, and tabs.

import CAMCore
import Foundation
import simd

/// A closed loop with cumulative arc lengths, for walking along it.
struct LoopPath {
    let pts: [V2]
    let cum: [Double]  // cum[i] = arc position of pts[i]; cum[n] = perimeter
    var perimeter: Double { cum[cum.count - 1] }

    init(_ points: [V2]) {
        pts = points
        var c = [0.0]
        c.reserveCapacity(points.count + 1)
        for i in 0..<points.count { c.append(c[i] + simd_distance(points[i], points[(i + 1) % points.count])) }
        cum = c
    }

    func wrap(_ u: Double) -> Double {
        let P = perimeter
        guard P > 0 else { return 0 }
        var v = u.truncatingRemainder(dividingBy: P)
        if v < 0 { v += P }
        return v
    }

    func point(at u0: Double) -> V2 {
        let u = wrap(u0)
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if cum[m] <= u { lo = m } else { hi = m - 1 }
        }
        let a = pts[lo], b = pts[(lo + 1) % pts.count]
        let seg = cum[lo + 1] - cum[lo]
        return seg > 1e-12 ? a + (b - a) * ((u - cum[lo]) / seg) : a
    }

    /// Arc position of the point on the loop nearest `p`.
    func position(nearest p: V2) -> Double {
        var best = Double.infinity, bu = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count], ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 1e-18 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
            let d = simd_distance_squared(p, a + ab * t)
            if d < best { best = d; bu = cum[i] + t * (cum[i + 1] - cum[i]) }
        }
        return bu
    }
}

/// A tab on a loop: centre arc position and half its length along the loop.
struct LoopTab {
    var center: Double
    var half: Double
}

/// Accumulates the moves of one toolpath.
struct MoveSink {
    var moves: [Move] = []
    var pos: V3
    let safeZ: Double
    let hopZ: Double
    let feed: Double
    let plunge: Double
    let rampAngle: Double

    init(start: V3, safeZ: Double, hopZ: Double, data: CuttingData) {
        pos = start
        self.safeZ = safeZ
        self.hopZ = min(hopZ, safeZ)
        feed = max(1, data.feed)
        plunge = max(1, min(data.plunge, data.feed))
        rampAngle = max(1, min(45, data.rampAngle))
    }

    mutating func rapid(_ p: V3) {
        if simd_distance(p, pos) < 1e-6 { return }
        moves.append(Move(.rapid, p))
        pos = p
    }

    mutating func cut(_ p: V3, feed f: Double? = nil) {
        if simd_distance(p, pos) < 1e-6 { return }
        let vertical = abs(p.x - pos.x) < 1e-9 && abs(p.y - pos.y) < 1e-9
        if vertical && p.z < pos.z {
            moves.append(Move(.plunge, p, feed: plunge))
        } else {
            // Moves that descend steeply are fed at the plunge rate.
            let dz = pos.z - p.z, dxy = simd_distance(cam2(p), cam2(pos))
            let rate = dz > 1e-9 && dz > dxy ? plunge : (f ?? feed)
            moves.append(Move(.feed, p, feed: rate))
        }
        pos = p
    }

    mutating func retract() { if pos.z < safeZ - 1e-9 { rapid(V3(pos.x, pos.y, safeZ)) } }

    /// Lifts clear (a short hop above the stock for nearby moves, safe height otherwise), crosses, and rapids down
    /// to `approachZ` over `p`.
    mutating func moveTo(_ p: V2, approachZ: Double) {
        let d = simd_distance(cam2(pos), p)
        if d < 1e-6 {
            if pos.z > approachZ { rapid(cam3(p, approachZ)) }
            return
        }
        let travelZ = d < 30 ? hopZ : safeZ
        if pos.z < travelZ - 1e-9 { rapid(V3(pos.x, pos.y, travelZ)) }
        rapid(cam3(p, max(pos.z, travelZ)))
        rapid(cam3(p, approachZ))
    }

    /// Cuts along a closed loop from arc position `s0` (where the tool is), ramping from `fromZ` down to `toZ` at
    /// the ramp angle, then one full lap at `toZ`. Inside tabs the cut never goes below `tabTop`.
    /// Returns the arc position it ends at.
    @discardableResult
    mutating func cutLoop(_ L: LoopPath, s0: Double, fromZ: Double, toZ: Double, tabs: [LoopTab] = [], tabTop: Double = -.infinity) -> Double {
        let P = L.perimeter
        guard P > 1e-6 else {
            cut(cam3(L.pts[0], toZ))
            return 0
        }
        func clamp(_ z: Double, _ u: Double) -> Double {
            guard z < tabTop, !tabs.isEmpty else { return z }
            let w = L.wrap(u)
            for t in tabs {
                var d = abs(w - t.center)
                d = min(d, P - d)
                if d < t.half { return tabTop }
            }
            return z
        }
        let dz = fromZ - toZ
        var rampLen = dz > 1e-6 ? dz / tan(rampAngle * .pi / 180) : 0
        if rampLen > 0 && (P < 1 || rampLen > 8 * P) {
            // Too small to ramp around: plunge.
            cut(cam3(cam2(pos), clamp(toZ, s0)))
            rampLen = 0
        }
        let total = rampLen + P
        var ss: [Double] = [total]
        if rampLen > 0 { ss.append(rampLen) }
        let laps = Int(total / P) + 2
        for k in 0...laps {
            let base = Double(k) * P - s0
            for c in L.cum.dropLast() {
                let s = c + base
                if s > 1e-9 && s < total - 1e-9 { ss.append(s) }
            }
            for t in tabs {
                for e in [t.center - t.half, t.center + t.half] {
                    var s = L.wrap(e) + base
                    if s <= 1e-9 { s += P }
                    if s > 1e-9 && s < total - 1e-9 { ss.append(s) }
                }
            }
        }
        ss.sort()
        var last = -1.0
        for s in ss where s - last > 1e-7 {
            last = s
            let u = s0 + s
            let pt = L.point(at: u)
            let zr = s < rampLen ? fromZ - dz * s / rampLen : toZ
            let zb = clamp(zr, u - 1e-6), za = clamp(zr, u + 1e-6)
            cut(cam3(pt, zb))
            if abs(za - zb) > 1e-9 { cut(cam3(pt, za)) }
        }
        return L.wrap(s0 + total)
    }

    /// Feeds along an open polyline at its points' Z.
    mutating func follow(_ pts: [V3]) { for p in pts { cut(p) } }
}

enum CAMGeometry {
    /// Point at a fraction (0..<1) of an outline's length.
    static func point(on pl: Polyline2D, fraction f: Double) -> V2 {
        let pts = pl.closed ? pl.points + [pl.points[0]] : pl.points
        let total = pl.length
        guard total > 0, pts.count > 1 else { return pts.first ?? .zero }
        var want = (f - floor(f)) * total
        for i in 1..<pts.count {
            let l = simd_distance(pts[i - 1], pts[i])
            if want <= l { return pts[i - 1] + (pts[i] - pts[i - 1]) * (l > 0 ? want / l : 0) }
            want -= l
        }
        return pts[pts.count - 1]
    }

    /// Non-zero winding test against closed polylines.
    static func inside(_ p: V2, _ polys: [Polyline2D]) -> Bool {
        var w = 0
        for pl in polys where pl.closed {
            let pts = pl.points
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                if a.y <= p.y {
                    if b.y > p.y && cross(a, b, p) > 0 { w += 1 }
                } else if b.y <= p.y && cross(a, b, p) < 0 { w -= 1 }
            }
        }
        return w != 0
    }

    @inline(__always) static func cross(_ a: V2, _ b: V2, _ p: V2) -> Double { (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) }

    /// Moving-average smoothing that keeps the end points (and every point of a closed chain's shape).
    static func smooth(_ pts: [V2], closed: Bool, passes: Int) -> [V2] {
        guard pts.count > 2 else { return pts }
        var p = pts
        for _ in 0..<passes {
            var q = p
            let n = p.count
            for i in 0..<n {
                if !closed && (i == 0 || i == n - 1) { continue }
                let a = p[(i - 1 + n) % n], b = p[(i + 1) % n]
                q[i] = (a + p[i] * 2 + b) / 4
            }
            p = q
        }
        return p
    }
}
