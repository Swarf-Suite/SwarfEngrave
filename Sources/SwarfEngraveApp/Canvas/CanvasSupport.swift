// Canvas helpers: Core Graphics conversions, the per-object path cache, colours, and the editing commands the canvas
// sends to the model. Owned by the canvas agent.

import AppKit
import CAMCore
import EngraveCore
import simd

// MARK: Conversions

extension Transform2D {
    /// The same mapping as `apply(_:)`, as an affine transform (local → stock).
    var canvasAffine: CGAffineTransform {
        let o = apply(.zero), ex = apply(V2(1, 0)) - o, ey = apply(V2(0, 1)) - o
        return CGAffineTransform(a: ex.x, b: ex.y, c: ey.x, d: ey.y, tx: o.x, ty: o.y)
    }
}

extension Path2D {
    func canvasCGPath() -> CGPath {
        let p = CGMutablePath()
        for sp in subpaths where !sp.segments.isEmpty {
            p.move(to: sp.start.cg)
            for s in sp.segments {
                switch s {
                case .line(let q): p.addLine(to: q.cg)
                case .quad(let c, let q): p.addQuadCurve(to: q.cg, control: c.cg)
                case .cubic(let a, let b, let q): p.addCurve(to: q.cg, control1: a.cg, control2: b.cg)
                }
            }
            if sp.closed { p.closeSubpath() }
        }
        return p
    }
}

extension SIMD2 where Scalar == Double {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension CGPoint {
    var v2: V2 { V2(Double(x), Double(y)) }
}

extension Rect2D {
    func canvasInset(_ d: Double) -> Rect2D { Rect2D(min: min - V2(d, d), max: max + V2(d, d)) }
}

// MARK: Colours

enum CanvasColor {
    static func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
    }
    static let obsidian = hex(0x121212)
    static let slate = hex(0x1e1e1e)
    static let slate2 = hex(0x262626)
    static let slate3 = hex(0x303030)
    static let line = hex(0x2e2e2e)
    static let lineStrong = hex(0x3a3a3a)
    static let accent = hex(0x7cc4a6)
    static let accentBright = hex(0x9bd6bd)
    static let offwhite = hex(0xe0e0e0)
    static let steel = hex(0x8e8e8e)
    static let warn = hex(0xe0a43a)
    static let danger = hex(0xd9534f)
    static let axisX = hex(0xd96b6b)
    static let axisY = hex(0x7fbf6a)
    static let throughFill = hex(0x1b3329)

    // Depth ramp: pale sage for shallow cuts, rich deep green for deep ones.
    static let pale = SIMD3<Double>(0.86, 0.95, 0.91)
    static let mid = SIMD3<Double>(0.486, 0.769, 0.651)
    static let rich = SIMD3<Double>(0.12, 0.42, 0.31)

    static func depthRGB(_ t0: Double) -> SIMD3<Double> {
        let t = Swift.max(0, Swift.min(1, t0))
        return t < 0.5 ? simd_mix(pale, mid, SIMD3(repeating: t * 2)) : simd_mix(mid, rich, SIMD3(repeating: (t - 0.5) * 2))
    }

    static func depth(_ t: Double, alpha: CGFloat = 0.92) -> NSColor {
        let c = depthRGB(t)
        return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: alpha)
    }
}

// MARK: Path cache

/// Local paths (keyed by geometry) and stock-space bounds (keyed by geometry + transform) per object, so text and
/// big imported artwork are outlined and flattened once rather than every frame.
@MainActor
final class CanvasShapeCache {
    struct Entry {
        var geometry: ObjectGeometry
        var path: CGPath
        var polys: [Polyline2D]  // local, flattened
        var transform: Transform2D
        var bounds: Rect2D?  // stock space
    }
    private var entries: [UUID: Entry] = [:]

    func entry(for o: DesignObject) -> Entry {
        if var e = entries[o.id] {
            if e.geometry == o.geometry {
                if e.transform != o.transform {
                    e.transform = o.transform
                    e.bounds = Self.bounds(e.polys, o.transform)
                    entries[o.id] = e
                }
                return e
            }
        }
        let local = o.geometry.path()
        let polys = local.flattened(tolerance: 0.05)
        let e = Entry(geometry: o.geometry, path: local.canvasCGPath(), polys: polys, transform: o.transform, bounds: Self.bounds(polys, o.transform))
        entries[o.id] = e
        return e
    }

    /// Stock-space flattened outline.
    func stockPolys(for o: DesignObject) -> [Polyline2D] {
        entry(for: o).polys.map { Polyline2D($0.points.map { o.transform.apply($0) }, closed: $0.closed) }
    }

    func prune(keeping ids: Set<UUID>) {
        if entries.count > ids.count + 32 { entries = entries.filter { ids.contains($0.key) } }
    }

    static func bounds(_ polys: [Polyline2D], _ t: Transform2D) -> Rect2D? {
        var r: Rect2D?
        for pl in polys {
            for p in pl.points {
                let q = t.apply(p)
                r = r?.including(q) ?? Rect2D(min: q, max: q)
            }
        }
        return r
    }
}

// MARK: Geometry helpers

enum CanvasGeom {
    /// Distance from `p` to the segment a–b.
    static func segmentDistance(_ p: V2, _ a: V2, _ b: V2) -> (dist: Double, t: Double) {
        let d = b - a
        let l2 = simd_length_squared(d)
        let t = l2 < 1e-18 ? 0 : max(0, min(1, simd_dot(p - a, d) / l2))
        return (simd_distance(p, a + d * t), t)
    }

    /// Nearest point on a set of polylines: distance and arc-length position from the start of the first polyline.
    static func nearest(_ p: V2, on polys: [Polyline2D]) -> (dist: Double, along: Double, total: Double) {
        var best = Double.infinity, bestAlong = 0.0, run = 0.0
        for pl in polys {
            let n = pl.points.count
            let segs = pl.closed ? n : n - 1
            guard segs > 0 else { continue }
            for i in 0..<segs {
                let a = pl.points[i], b = pl.points[(i + 1) % n]
                let (d, t) = segmentDistance(p, a, b)
                let len = simd_distance(a, b)
                if d < best { best = d; bestAlong = run + t * len }
                run += len
            }
        }
        return (best, bestAlong, run)
    }

    /// Point and unit tangent at an arc-length position along polylines.
    static func point(along s0: Double, on polys: [Polyline2D]) -> (V2, V2)? {
        var s = s0
        for pl in polys {
            let n = pl.points.count
            let segs = pl.closed ? n : n - 1
            guard segs > 0 else { continue }
            for i in 0..<segs {
                let a = pl.points[i], b = pl.points[(i + 1) % n]
                let len = simd_distance(a, b)
                if s <= len, len > 0 { return (a + (b - a) * (s / len), (b - a) / len) }
                s -= len
            }
        }
        return nil
    }

    static func grid(_ v: Double, _ step: Double) -> Double { step > 0 ? (v / step).rounded() * step : v }
}

// MARK: Editing helpers (adding, deleting, nudging and importing use the shell's EditorActions)

extension EditorModel {
    /// All objects that select together with `id` (its group), skipping locked and hidden ones.
    func canvasGroupIDs(of id: UUID) -> Set<UUID> {
        guard let o = sheet.objects.first(where: { $0.id == id }) else { return [] }
        guard let g = o.groupID else { return [id] }
        return Set(sheet.objects.filter { $0.groupID == g && !$0.locked && !$0.hidden }.map(\.id))
    }

    /// Apply a non-uniform scale about `anchor` (stock space) to an object: shapes change their dimensions, paths and
    /// text their transform's scale.
    static func canvasResized(_ o: DesignObject, sx: Double, sy: Double, anchor: V2) -> DesignObject {
        var r = o
        r.transform.position = anchor + (o.transform.position - anchor) * V2(sx, sy)
        // Map the stock-space factors onto the object's local axes.
        let rot = (o.transform.rotation.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180)
        var lx = sx, ly = sy
        if abs(rot - 90) < 0.01 { lx = sy; ly = sx }
        else if rot > 0.01 && rot < 179.99 { let k = (sx * sy).squareRoot(); lx = k; ly = k }
        switch o.geometry {
        case .rectangle(let w, let h, let cr): r.geometry = .rectangle(width: w * lx, height: h * ly, cornerRadius: cr)
        case .ellipse(let w, let h): r.geometry = .ellipse(width: w * lx, height: h * ly)
        case .line(let l): r.geometry = .line(length: l * lx)
        default: r.transform.scale = o.transform.scale * V2(lx, ly)
        }
        return r
    }
}
