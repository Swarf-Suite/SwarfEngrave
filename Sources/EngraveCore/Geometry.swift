// 2D vector geometry shared by the editor, importers and toolpath code.
// Units are millimetres. Stock space: X right, Y up (away from the operator), origin at the stock's front-left
// corner, as in SwarfPath.

import CAMCore
import Foundation
import simd

/// One drawing command after a start point.
public enum Segment: Codable, Sendable, Equatable {
    case line(V2)
    case quad(V2, V2)  // control, end
    case cubic(V2, V2, V2)  // control 1, control 2, end

    public var end: V2 {
        switch self {
        case .line(let p): return p
        case .quad(_, let p): return p
        case .cubic(_, _, let p): return p
        }
    }

    func mapped(_ f: (V2) -> V2) -> Segment {
        switch self {
        case .line(let p): return .line(f(p))
        case .quad(let c, let p): return .quad(f(c), f(p))
        case .cubic(let a, let b, let p): return .cubic(f(a), f(b), f(p))
        }
    }
}

public struct SubPath: Codable, Sendable, Equatable {
    public var start: V2
    public var segments: [Segment]
    public var closed: Bool

    public init(start: V2, segments: [Segment] = [], closed: Bool = false) {
        self.start = start
        self.segments = segments
        self.closed = closed
    }

    public var isEmpty: Bool { segments.isEmpty }
}

/// A flattened subpath: straight segments only.
public struct Polyline2D: Sendable, Equatable {
    public var points: [V2]
    public var closed: Bool
    public init(_ points: [V2], closed: Bool) {
        self.points = points
        self.closed = closed
    }

    /// Shoelace area, positive when counter-clockwise (Y up). Zero for open polylines.
    public var signedArea: Double {
        guard closed, points.count > 2 else { return 0 }
        var a = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    public var length: Double {
        guard points.count > 1 else { return 0 }
        var l = 0.0
        for i in 1..<points.count { l += simd_distance(points[i - 1], points[i]) }
        if closed { l += simd_distance(points[points.count - 1], points[0]) }
        return l
    }
}

/// A path made of subpaths, filled with the non-zero winding rule unless a caller says otherwise.
public struct Path2D: Codable, Sendable, Equatable {
    public var subpaths: [SubPath]

    public init(_ subpaths: [SubPath] = []) { self.subpaths = subpaths }

    public var isEmpty: Bool { subpaths.allSatisfy(\.isEmpty) }

    // MARK: Building

    public mutating func move(to p: V2) { subpaths.append(SubPath(start: p)) }
    public mutating func line(to p: V2) { appendSegment(.line(p)) }
    public mutating func quad(to p: V2, control c: V2) { appendSegment(.quad(c, p)) }
    public mutating func cubic(to p: V2, control1 a: V2, control2 b: V2) { appendSegment(.cubic(a, b, p)) }
    public mutating func close() {
        guard !subpaths.isEmpty else { return }
        subpaths[subpaths.count - 1].closed = true
    }

    private mutating func appendSegment(_ s: Segment) {
        if subpaths.isEmpty { subpaths.append(SubPath(start: .zero)) }
        subpaths[subpaths.count - 1].segments.append(s)
    }

    public mutating func append(_ other: Path2D) { subpaths += other.subpaths }

    // MARK: Transforming

    public func mapped(_ f: (V2) -> V2) -> Path2D {
        Path2D(subpaths.map { sp in
            SubPath(start: f(sp.start), segments: sp.segments.map { $0.mapped(f) }, closed: sp.closed)
        })
    }

    public func applying(_ t: Transform2D) -> Path2D { mapped { t.apply($0) } }

    /// Bounds of the control polygon (always contains the curve).
    public var bounds: Rect2D? {
        var r: Rect2D?
        for sp in subpaths {
            var pts = [sp.start]
            for s in sp.segments {
                switch s {
                case .line(let p): pts.append(p)
                case .quad(let c, let p): pts += [c, p]
                case .cubic(let a, let b, let p): pts += [a, b, p]
                }
            }
            for p in pts { r = r?.including(p) ?? Rect2D(min: p, max: p) }
        }
        return r
    }

    /// Exact-ish bounds from the flattened curve.
    public func tightBounds(tolerance: Double = 0.02) -> Rect2D? {
        var r: Rect2D?
        for pl in flattened(tolerance: tolerance) { for p in pl.points { r = r?.including(p) ?? Rect2D(min: p, max: p) } }
        return r
    }

    // MARK: Flattening

    /// Curves split into straight segments no further than `tolerance` mm from the true curve.
    public func flattened(tolerance: Double = 0.01) -> [Polyline2D] {
        var out: [Polyline2D] = []
        for sp in subpaths where !sp.segments.isEmpty {
            var pts = [sp.start]
            var cur = sp.start
            for s in sp.segments {
                switch s {
                case .line(let p):
                    pts.append(p)
                case .quad(let c, let p):
                    let n = Self.steps(chord: [cur, c, p], tolerance: tolerance)
                    for i in 1...n {
                        let t = Double(i) / Double(n), u = 1 - t
                        pts.append(u * u * cur + 2 * u * t * c + t * t * p)
                    }
                case .cubic(let a, let b, let p):
                    let n = Self.steps(chord: [cur, a, b, p], tolerance: tolerance)
                    for i in 1...n {
                        let t = Double(i) / Double(n), u = 1 - t
                        pts.append(u * u * u * cur + 3 * u * u * t * a + 3 * u * t * t * b + t * t * t * p)
                    }
                }
                cur = s.end
            }
            // Drop repeated points, and the closing duplicate of a closed path.
            var clean: [V2] = []
            for p in pts where clean.last.map({ simd_distance($0, p) > 1e-9 }) ?? true { clean.append(p) }
            if sp.closed, clean.count > 1, simd_distance(clean[0], clean[clean.count - 1]) < 1e-9 { clean.removeLast() }
            if clean.count >= 2 { out.append(Polyline2D(clean, closed: sp.closed)) }
        }
        return out
    }

    private static func steps(chord pts: [V2], tolerance: Double) -> Int {
        // Bound from the control polygon's second differences (Wang's formula).
        var m = 0.0
        if pts.count >= 3 {
            for i in 0..<(pts.count - 2) { m = max(m, simd_length(pts[i] - 2 * pts[i + 1] + pts[i + 2])) }
        }
        let deg = Double(pts.count - 1)
        let n = ((deg * (deg - 1) / 8) * m / max(1e-6, tolerance)).squareRoot()
        return max(1, min(512, Int(n.rounded(.up))))
    }

    // MARK: Shapes (centred on the origin)

    public static func rect(width w: Double, height h: Double, cornerRadius r0: Double = 0) -> Path2D {
        let hw = w / 2, hh = h / 2
        let r = max(0, min(r0, hw, hh))
        var p = Path2D()
        if r <= 0 {
            p.move(to: V2(-hw, -hh)); p.line(to: V2(hw, -hh)); p.line(to: V2(hw, hh)); p.line(to: V2(-hw, hh)); p.close()
            return p
        }
        let k = 0.5522847498 * r
        p.move(to: V2(-hw + r, -hh))
        p.line(to: V2(hw - r, -hh))
        p.cubic(to: V2(hw, -hh + r), control1: V2(hw - r + k, -hh), control2: V2(hw, -hh + r - k))
        p.line(to: V2(hw, hh - r))
        p.cubic(to: V2(hw - r, hh), control1: V2(hw, hh - r + k), control2: V2(hw - r + k, hh))
        p.line(to: V2(-hw + r, hh))
        p.cubic(to: V2(-hw, hh - r), control1: V2(-hw + r - k, hh), control2: V2(-hw, hh - r + k))
        p.line(to: V2(-hw, -hh + r))
        p.cubic(to: V2(-hw + r, -hh), control1: V2(-hw, -hh + r - k), control2: V2(-hw + r - k, -hh))
        p.close()
        return p
    }

    public static func ellipse(width w: Double, height h: Double) -> Path2D {
        let rx = w / 2, ry = h / 2, kx = 0.5522847498 * rx, ky = 0.5522847498 * ry
        var p = Path2D()
        p.move(to: V2(rx, 0))
        p.cubic(to: V2(0, ry), control1: V2(rx, ky), control2: V2(kx, ry))
        p.cubic(to: V2(-rx, 0), control1: V2(-kx, ry), control2: V2(-rx, ky))
        p.cubic(to: V2(0, -ry), control1: V2(-rx, -ky), control2: V2(-kx, -ry))
        p.cubic(to: V2(rx, 0), control1: V2(kx, -ry), control2: V2(rx, -ky))
        p.close()
        return p
    }

    /// Regular polygon with a vertex at the top; `radius` is the circumradius.
    public static func polygon(sides: Int, radius: Double) -> Path2D {
        let n = max(3, sides)
        var p = Path2D()
        for i in 0..<n {
            let a = Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            let v = V2(cos(a), sin(a)) * radius
            if i == 0 { p.move(to: v) } else { p.line(to: v) }
        }
        p.close()
        return p
    }

    public static func star(points: Int, outerRadius: Double, innerRadius: Double) -> Path2D {
        let n = max(3, points)
        var p = Path2D()
        for i in 0..<(2 * n) {
            let a = Double.pi / 2 + Double.pi * Double(i) / Double(n)
            let v = V2(cos(a), sin(a)) * (i % 2 == 0 ? outerRadius : innerRadius)
            if i == 0 { p.move(to: v) } else { p.line(to: v) }
        }
        p.close()
        return p
    }

    public static func line(length: Double) -> Path2D {
        var p = Path2D()
        p.move(to: V2(-length / 2, 0))
        p.line(to: V2(length / 2, 0))
        return p
    }
}

public struct Rect2D: Codable, Sendable, Equatable {
    public var min: V2
    public var max: V2
    public init(min: V2, max: V2) {
        self.min = min
        self.max = max
    }
    public var size: V2 { max - min }
    public var center: V2 { (min + max) / 2 }
    public func including(_ p: V2) -> Rect2D { Rect2D(min: simd_min(min, p), max: simd_max(max, p)) }
    public func union(_ o: Rect2D) -> Rect2D { Rect2D(min: simd_min(min, o.min), max: simd_max(max, o.max)) }
    public func contains(_ p: V2) -> Bool { p.x >= min.x && p.y >= min.y && p.x <= max.x && p.y <= max.y }
    public func intersects(_ o: Rect2D) -> Bool { !(o.min.x > max.x || o.max.x < min.x || o.min.y > max.y || o.max.y < min.y) }
}

/// Object placement: local geometry (centred on its own origin) → stock space.
/// Applied as scale (with mirror), then rotation about the local origin, then translation to `position`.
public struct Transform2D: Codable, Sendable, Equatable {
    public var position: V2
    public var rotation: Double  // degrees, counter-clockwise
    public var scale: V2
    public var mirrored: Bool  // flip horizontally before rotating

    public init(position: V2 = .zero, rotation: Double = 0, scale: V2 = V2(1, 1), mirrored: Bool = false) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.mirrored = mirrored
    }

    public static let identity = Transform2D()

    public func apply(_ p: V2) -> V2 {
        var q = p * scale
        if mirrored { q.x = -q.x }
        let a = rotation * .pi / 180
        let c = cos(a), s = sin(a)
        return V2(c * q.x - s * q.y, s * q.x + c * q.y) + position
    }

    /// Inverse mapping (stock → local).
    public func invert(_ p: V2) -> V2 {
        let a = -rotation * .pi / 180
        let c = cos(a), s = sin(a)
        let d = p - position
        var q = V2(c * d.x - s * d.y, s * d.x + c * d.y)
        if mirrored { q.x = -q.x }
        return q / V2(scale.x == 0 ? 1 : scale.x, scale.y == 0 ? 1 : scale.y)
    }
}
