// ASCII DXF reader: LINE, LWPOLYLINE (with bulges), POLYLINE/VERTEX, CIRCLE, ARC, ELLIPSE and SPLINE from the
// ENTITIES section, one layer per DXF layer name, scaled to mm from $INSUNITS. DXF is already Y up.

import CAMCore
import Foundation
import simd

enum DXFImporter {
    struct Pair {
        var code: Int
        var value: String
        var double: Double { Double(value) ?? 0 }
        var int: Int { Int(value) ?? Int(Double(value) ?? 0) }
    }

    static func parse(_ text: String) throws -> ImportedArtwork {
        let pairs = readPairs(text)
        guard !pairs.isEmpty else { throw ImportError.unreadable("The DXF file is empty or isn't ASCII DXF.") }
        if text.hasPrefix("AutoCAD Binary DXF") { throw ImportError.unsupported("Binary DXF isn't supported; save as ASCII DXF.") }

        var unitScale = 1.0
        var warnings: [String] = []
        var warned = Set<String>()
        func warn(_ s: String) { if warned.insert(s).inserted { warnings.append(s) } }

        var layerOrder: [String] = []
        var layerPaths: [String: Path2D] = [:]
        func add(_ sp: SubPath, layer: String) {
            guard !sp.segments.isEmpty else { return }
            if layerPaths[layer] == nil { layerOrder.append(layer); layerPaths[layer] = Path2D() }
            layerPaths[layer]!.subpaths.append(sp)
        }

        // Split into sections.
        var i = 0
        var section = ""
        var sawEntities = false
        while i < pairs.count {
            let p = pairs[i]
            if p.code == 0 && p.value == "SECTION", i + 1 < pairs.count, pairs[i + 1].code == 2 {
                section = pairs[i + 1].value
                if section == "ENTITIES" { sawEntities = true }
                i += 2
                continue
            }
            if p.code == 0 && p.value == "ENDSEC" { section = ""; i += 1; continue }
            if section == "HEADER" {
                if p.code == 9 && p.value == "$INSUNITS", i + 1 < pairs.count {
                    unitScale = scale(forInsUnits: pairs[i + 1].int)
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if section == "ENTITIES", p.code == 0 {
                // Gather this entity's pairs.
                var j = i + 1
                while j < pairs.count && pairs[j].code != 0 { j += 1 }
                let ent = Array(pairs[(i + 1)..<j])
                let layer = ent.first { $0.code == 8 }?.value ?? "0"
                switch p.value {
                case "LINE":
                    let a = V2(value(ent, 10), value(ent, 20)), b = V2(value(ent, 11), value(ent, 21))
                    add(SubPath(start: a, segments: [.line(b)]), layer: layer)
                case "LWPOLYLINE":
                    var verts: [(V2, Double)] = []
                    for q in ent {
                        switch q.code {
                        case 10: verts.append((V2(q.double, 0), 0))
                        case 20: if !verts.isEmpty { verts[verts.count - 1].0.y = q.double }
                        case 42: if !verts.isEmpty { verts[verts.count - 1].1 = q.double }
                        default: break
                        }
                    }
                    let closed = (Int(ent.first { $0.code == 70 }?.int ?? 0) & 1) != 0
                    add(polyline(verts, closed: closed), layer: layer)
                case "POLYLINE":
                    let flags = ent.first { $0.code == 70 }?.int ?? 0
                    var verts: [(V2, Double)] = []
                    var k = j
                    while k < pairs.count, pairs[k].code == 0, pairs[k].value == "VERTEX" {
                        var m = k + 1
                        while m < pairs.count && pairs[m].code != 0 { m += 1 }
                        let v = Array(pairs[(k + 1)..<m])
                        let vflags = v.first { $0.code == 70 }?.int ?? 0
                        if vflags & 16 == 0 {  // skip spline frame control points
                            verts.append((V2(value(v, 10), value(v, 20)), value(v, 42)))
                        }
                        k = m
                    }
                    if k < pairs.count, pairs[k].value == "SEQEND" {
                        var m = k + 1
                        while m < pairs.count && pairs[m].code != 0 { m += 1 }
                        k = m
                    }
                    if flags & (16 | 64) != 0 {
                        warn("3D meshes in the DXF were skipped.")
                    } else {
                        add(polyline(verts, closed: flags & 1 != 0), layer: layer)
                    }
                    i = k
                    continue
                case "CIRCLE":
                    let r = value(ent, 40)
                    if r > 0 { add(ImportGeometry.circle(center: V2(value(ent, 10), value(ent, 20)), radius: r), layer: layer) }
                case "ARC":
                    let c = V2(value(ent, 10), value(ent, 20)), r = value(ent, 40)
                    let a0 = value(ent, 50) * .pi / 180, a1 = value(ent, 51) * .pi / 180
                    var sweep = a1 - a0
                    while sweep <= 0 { sweep += 2 * .pi }
                    while sweep > 2 * .pi + 1e-12 { sweep -= 2 * .pi }
                    if r > 0 {
                        add(SubPath(start: c + r * V2(cos(a0), sin(a0)),
                                    segments: ImportGeometry.arcSegments(center: c, rx: r, ry: r, phi: 0, start: a0, sweep: sweep)), layer: layer)
                    }
                case "ELLIPSE":
                    let c = V2(value(ent, 10), value(ent, 20)), major = V2(value(ent, 11), value(ent, 21))
                    let ratio = value(ent, 40, default: 1)
                    let t0 = value(ent, 41, default: 0), t1 = value(ent, 42, default: 2 * .pi)
                    let rx = simd_length(major), ry = rx * ratio, phi = atan2(major.y, major.x)
                    var sweep = t1 - t0
                    while sweep <= 0 { sweep += 2 * .pi }
                    if rx > 0 {
                        let segs = ImportGeometry.arcSegments(center: c, rx: rx, ry: ry, phi: phi, start: t0, sweep: sweep)
                        let start = c + V2(cos(phi) * rx * cos(t0) - sin(phi) * ry * sin(t0), sin(phi) * rx * cos(t0) + cos(phi) * ry * sin(t0))
                        add(SubPath(start: start, segments: segs, closed: abs(sweep - 2 * .pi) < 1e-9), layer: layer)
                    }
                case "SPLINE":
                    if let sp = spline(ent) { add(sp, layer: layer) }
                case "INSERT":
                    warn("Block references (INSERT) in the DXF were skipped: explode blocks before exporting.")
                case "TEXT", "MTEXT":
                    warn("Text in the DXF was skipped: convert it to outlines before exporting.")
                case "HATCH", "SOLID", "DIMENSION", "POINT", "VIEWPORT", "ATTDEF", "ATTRIB", "SEQEND", "VERTEX":
                    break
                default:
                    warn("Unsupported DXF entities (\(p.value)) were skipped.")
                }
                i = j
                continue
            }
            i += 1
        }
        if !sawEntities { throw ImportError.unreadable("The DXF file has no ENTITIES section.") }

        var layers: [(name: String, path: Path2D)] = []
        for name in layerOrder {
            var p = layerPaths[name]!
            if unitScale != 1 { p = p.mapped { $0 * unitScale } }
            p = ImportGeometry.join(p, tolerance: 0.01)
            if !p.isEmpty { layers.append((name: name, path: p)) }
        }
        if layers.isEmpty { warnings.append("No shapes were found in the DXF.") }
        return ImportedArtwork(layers: layers, warnings: warnings)
    }

    static func scale(forInsUnits u: Int) -> Double {
        switch u {
        case 1: return 25.4  // inches
        case 2: return 304.8  // feet
        case 4: return 1  // mm
        case 5: return 10  // cm
        case 6: return 1000  // m
        case 8: return 25.4e-6  // microinches
        case 9: return 0.0254  // mils
        case 10: return 914.4  // yards
        case 13: return 1e-3  // microns
        case 14: return 100  // decimetres
        default: return 1  // unitless: assume mm
        }
    }

    static func readPairs(_ text: String) -> [Pair] {
        var out: [Pair] = []
        var code: Int?
        text.enumerateLines { line, _ in
            if let c = code {
                out.append(Pair(code: c, value: line.trimmingCharacters(in: .whitespaces)))
                code = nil
            } else {
                code = Int(line.trimmingCharacters(in: .whitespaces))
                if code == nil { code = -1 }
            }
        }
        return out.filter { $0.code >= 0 }
    }

    static func value(_ ent: [Pair], _ code: Int, default d: Double = 0) -> Double {
        ent.first { $0.code == code }.map(\.double) ?? d
    }

    /// Polyline with bulges (bulge on vertex i shapes the segment i → i+1; tan of a quarter of the included angle).
    static func polyline(_ verts: [(V2, Double)], closed: Bool) -> SubPath {
        guard let first = verts.first else { return SubPath(start: .zero) }
        var sp = SubPath(start: first.0, closed: closed)
        let n = verts.count
        let count = closed ? n : n - 1
        guard count > 0 else { return sp }
        for k in 0..<count {
            let (p1, b) = verts[k]
            let p2 = verts[(k + 1) % n].0
            sp.segments += bulgeSegments(from: p1, to: p2, bulge: b)
        }
        if closed, case .line(let e)? = sp.segments.last, simd_distance(e, sp.start) < 1e-12, sp.segments.count > 2 {
            sp.segments.removeLast()
        }
        return sp
    }

    static func bulgeSegments(from p1: V2, to p2: V2, bulge b: Double) -> [Segment] {
        let chord = p2 - p1
        let d = simd_length(chord)
        if abs(b) < 1e-12 || d < 1e-12 { return d < 1e-12 ? [] : [.line(p2)] }
        let theta = 4 * atan(b)
        let mid = (p1 + p2) / 2
        let nL = V2(-chord.y, chord.x) / d
        let h = (d / 2) / tan(theta / 2)
        let c = mid + nL * h
        let r = simd_distance(p1, c)
        let a0 = atan2(p1.y - c.y, p1.x - c.x)
        var segs = ImportGeometry.arcSegments(center: c, rx: r, ry: r, phi: 0, start: a0, sweep: theta)
        if case .cubic(let x, let y, _)? = segs.last { segs[segs.count - 1] = .cubic(x, y, p2) }
        return segs
    }

    /// B-spline (optionally rational) sampled into line segments; falls back to fit points or the control polygon.
    static func spline(_ ent: [Pair]) -> SubPath? {
        let flags = ent.first { $0.code == 70 }?.int ?? 0
        let degree = ent.first { $0.code == 71 }?.int ?? 3
        var knots: [Double] = []
        var ctrl: [V2] = []
        var fit: [V2] = []
        var weights: [Double] = []
        for q in ent {
            switch q.code {
            case 40: knots.append(q.double)
            case 41: weights.append(q.double)
            case 10: ctrl.append(V2(q.double, 0))
            case 20: if !ctrl.isEmpty { ctrl[ctrl.count - 1].y = q.double }
            case 11: fit.append(V2(q.double, 0))
            case 21: if !fit.isEmpty { fit[fit.count - 1].y = q.double }
            default: break
            }
        }
        let closedFlag = flags & 1 != 0
        var pts: [V2] = []
        let n = ctrl.count
        let p = max(1, degree)
        if n > p, knots.count == n + p + 1 {
            let w = weights.count == n ? weights : [Double](repeating: 1, count: n)
            let lo = knots[p], hi = knots[n]
            let spans = max(1, n - p)
            let samples = spans * 12
            for s in 0...samples {
                let t = lo + (hi - lo) * Double(s) / Double(samples)
                pts.append(deBoor(t: min(t, hi - 1e-12 * max(1, abs(hi))), degree: p, knots: knots, ctrl: ctrl, weights: w))
            }
        } else if fit.count >= 2 {
            pts = fit
        } else if ctrl.count >= 2 {
            pts = ctrl
        } else {
            return nil
        }
        var sp = SubPath(start: pts[0])
        for q in pts.dropFirst() where simd_distance(q, ImportGeometry.endPoint(sp)) > 1e-9 { sp.segments.append(.line(q)) }
        if closedFlag || (pts.count > 2 && simd_distance(pts[0], pts[pts.count - 1]) < 1e-9) {
            sp.closed = true
            if case .line(let e)? = sp.segments.last, simd_distance(e, sp.start) < 1e-9 { sp.segments.removeLast() }
        }
        return sp
    }

    static func deBoor(t: Double, degree p: Int, knots: [Double], ctrl: [V2], weights: [Double]) -> V2 {
        let n = ctrl.count
        var k = p
        while k < n - 1 && t >= knots[k + 1] { k += 1 }
        var d: [SIMD3<Double>] = (0...p).map { j in
            let i = j + k - p
            return SIMD3(ctrl[i].x * weights[i], ctrl[i].y * weights[i], weights[i])
        }
        if p >= 1 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = j + k - p
                    let den = knots[i + p - r + 1] - knots[i]
                    let a = den == 0 ? 0 : (t - knots[i]) / den
                    d[j] = (1 - a) * d[j - 1] + a * d[j]
                }
            }
        }
        let h = d[p]
        return h.z == 0 ? V2(h.x, h.y) : V2(h.x / h.z, h.y / h.z)
    }
}
