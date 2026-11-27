// Bitmap tracing: grayscale → threshold → speck removal → pixel-boundary contours (outer loops counter-clockwise,
// holes clockwise, Y up) → simplification → optional Bézier smoothing → millimetres.

import CAMCore
import CoreGraphics
import Foundation
import simd

enum TraceEngine {
    static func trace(cgImage: CGImage, options o: TraceOptions) -> Path2D {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return Path2D() }
        var mask = binaryMask(cgImage, threshold: o.threshold, invert: o.invert)
        let mmPerPx = max(1e-9, o.targetWidth) / Double(w)
        let minPx = max(0, o.minDetail) / mmPerPx
        let minArea = Int((Double.pi / 4 * minPx * minPx).rounded())
        if minArea > 1 { removeSpecks(&mask, w: w, h: h, minArea: minArea) }
        let loops = contours(mask, w: w, h: h)

        let smoothing = min(1, max(0, o.smoothing))
        let tol = 0.45 + 0.9 * smoothing  // px
        var out = Path2D()
        out.subpaths.reserveCapacity(loops.count)
        for loop in loops {
            var pts = simplifyClosed(loop, tolerance: tol)
            guard pts.count >= 3 else { continue }
            if abs(area(pts)) < Double(max(1, minArea)) * 0.5 { continue }
            // px (y down) → mm (y up)
            for i in pts.indices { pts[i] = V2(pts[i].x * mmPerPx, (Double(h) - pts[i].y) * mmPerPx) }
            out.subpaths.append(smoothing > 0.02 ? smooth(pts, amount: smoothing) : polygon(pts))
        }
        return out
    }

    // MARK: Pixels

    static func binaryMask(_ img: CGImage, threshold: Double, invert: Bool) -> [UInt8] {
        let w = img.width, h = img.height
        var gray = [UInt8](repeating: 255, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let t = UInt8(max(0, min(255, (threshold * 255).rounded())))
        var mask = [UInt8](repeating: 0, count: w * h)
        gray.withUnsafeBufferPointer { g in
            mask.withUnsafeMutableBufferPointer { m in
                for i in 0..<(w * h) {
                    let dark = g[i] < t
                    m[i] = (dark != invert) ? 1 : 0
                }
            }
        }
        return mask
    }

    /// Drops foreground blobs smaller than `minArea` pixels and fills enclosed holes smaller than that.
    static func removeSpecks(_ mask: inout [UInt8], w: Int, h: Int, minArea: Int) {
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var comp: [Int] = []
        mask.withUnsafeMutableBufferPointer { m in
            seen.withUnsafeMutableBufferPointer { s in
                for pass in 0..<2 {
                    let target: UInt8 = pass == 0 ? 1 : 0
                    for i in 0..<(w * h) { s[i] = false }
                    for start in 0..<(w * h) where !s[start] && m[start] == target {
                        comp.removeAll(keepingCapacity: true)
                        stack.append(start)
                        s[start] = true
                        var touchesBorder = false
                        var big = false
                        while let i = stack.popLast() {
                            if !big { comp.append(i); if comp.count >= minArea { big = true; comp.removeAll(keepingCapacity: true) } }
                            let x = i % w, y = i / w
                            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                            if x > 0, !s[i - 1], m[i - 1] == target { s[i - 1] = true; stack.append(i - 1) }
                            if x < w - 1, !s[i + 1], m[i + 1] == target { s[i + 1] = true; stack.append(i + 1) }
                            if y > 0, !s[i - w], m[i - w] == target { s[i - w] = true; stack.append(i - w) }
                            if y < h - 1, !s[i + w], m[i + w] == target { s[i + w] = true; stack.append(i + w) }
                        }
                        if !big && (pass == 0 || !touchesBorder) {
                            for i in comp { m[i] = 1 - target }
                        }
                    }
                }
            }
        }
    }

    /// Closed loops along pixel boundaries, as midpoints of the boundary edges (pixel units, y down).
    /// Directed so that, once Y is flipped up, the foreground is on the left.
    static func contours(_ mask: [UInt8], w: Int, h: Int) -> [[V2]] {
        let vw = w + 1
        let E: UInt8 = 1, S: UInt8 = 2, W: UInt8 = 4, N: UInt8 = 8
        var out = [UInt8](repeating: 0, count: vw * (h + 1))
        mask.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for x in 0..<w where m[y * w + x] != 0 {
                        let i = y * w + x
                        if y == 0 || m[i - w] == 0 { o[y * vw + x + 1] |= W }  // top: (x+1,y) → (x,y)
                        if y == h - 1 || m[i + w] == 0 { o[(y + 1) * vw + x] |= E }  // bottom: (x,y+1) → (x+1,y+1)
                        if x == 0 || m[i - 1] == 0 { o[y * vw + x] |= S }  // left: (x,y) → (x,y+1)
                        if x == w - 1 || m[i + 1] == 0 { o[(y + 1) * vw + x + 1] |= N }  // right: (x+1,y+1) → (x+1,y)
                    }
                }
            }
        }
        func step(_ d: UInt8) -> (Int, Int) {
            switch d {
            case E: return (1, 0)
            case S: return (0, 1)
            case W: return (-1, 0)
            default: return (0, -1)
            }
        }
        // Clockwise order on screen (y down): E → S → W → N.
        func right(_ d: UInt8) -> UInt8 { d == N ? E : d << 1 }
        func left(_ d: UInt8) -> UInt8 { d == E ? N : d >> 1 }

        var loops: [[V2]] = []
        out.withUnsafeMutableBufferPointer { o in
            for v0 in 0..<o.count where o[v0] != 0 {
                while o[v0] != 0 {
                    var v = v0
                    var d: UInt8 = o[v] & E != 0 ? E : (o[v] & S != 0 ? S : (o[v] & W != 0 ? W : N))
                    var pts: [V2] = []
                    while true {
                        o[v] &= ~d
                        let (dx, dy) = step(d)
                        let x = v % vw, y = v / vw
                        pts.append(V2(Double(x) + Double(dx) / 2, Double(y) + Double(dy) / 2))
                        v = (y + dy) * vw + (x + dx)
                        let bits = o[v]
                        if bits == 0 { break }
                        // At saddles keep diagonal pixels apart (4-connected foreground): prefer turning left on screen.
                        if bits & left(d) != 0 { d = left(d) } else if bits & d != 0 { } else if bits & right(d) != 0 { d = right(d) } else { break }
                    }
                    if pts.count >= 4 { loops.append(pts) }
                }
            }
        }
        return loops
    }

    // MARK: Curves

    static func area(_ p: [V2]) -> Double {
        var a = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count]
            a += p[i].x * q.y - q.x * p[i].y
        }
        return a / 2
    }

    /// Douglas–Peucker for a closed loop, split at the point farthest from the first.
    static func simplifyClosed(_ pts: [V2], tolerance: Double) -> [V2] {
        guard pts.count > 3 else { return pts }
        var far = 0
        var best = -1.0
        for i in pts.indices {
            let d = simd_distance_squared(pts[i], pts[0])
            if d > best { best = d; far = i }
        }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[far] = true
        var stack: [(Int, Int)] = [(0, far), (far, pts.count)]
        let tol2 = tolerance * tolerance
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let pa = pts[a], pb = pts[b % pts.count]
            let ab = pb - pa
            let len2 = simd_length_squared(ab)
            var maxD = -1.0, idx = a
            for i in (a + 1)..<b {
                let ap = pts[i] - pa
                let d: Double
                if len2 < 1e-18 { d = simd_length_squared(ap) } else {
                    let c = ab.x * ap.y - ab.y * ap.x
                    d = c * c / len2
                }
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tol2 {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        var out: [V2] = []
        for i in pts.indices where keep[i] { out.append(pts[i]) }
        return out
    }

    static func polygon(_ pts: [V2]) -> SubPath {
        SubPath(start: pts[0], segments: pts.dropFirst().map { .line($0) }, closed: true)
    }

    /// Smooth closed curve through the points with cubic Béziers (Catmull–Rom tangents), keeping sharp corners.
    /// More smoothing rounds off more corners.
    static func smooth(_ pts: [V2], amount: Double) -> SubPath {
        let n = pts.count
        let cornerCos = cos((35 + 75 * amount) * .pi / 180)  // corners sharper than this stay corners
        var corner = [Bool](repeating: false, count: n)
        var tangent = [V2](repeating: .zero, count: n)
        for i in 0..<n {
            let p = pts[(i + n - 1) % n], c = pts[i], q = pts[(i + 1) % n]
            let a = simd_normalize(c - p), b = simd_normalize(q - c)
            if !(a.x.isFinite && b.x.isFinite) { corner[i] = true; continue }
            corner[i] = simd_dot(a, b) < cornerCos
            let t = q - p
            let l = simd_length(t)
            tangent[i] = l > 1e-12 ? t / l : a
        }
        let k = 0.33 * min(1, 0.4 + amount)
        var sp = SubPath(start: pts[0], closed: true)
        sp.segments.reserveCapacity(n)
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let j = (i + 1) % n
            if corner[i] && corner[j] {
                sp.segments.append(.line(b))
                continue
            }
            let len = simd_distance(a, b)
            let c1 = corner[i] ? a + (b - a) / 3 : a + tangent[i] * len * k
            let c2 = corner[j] ? b - (b - a) / 3 : b - tangent[j] * len * k
            sp.segments.append(.cubic(c1, c2, b))
        }
        return sp
    }
}
