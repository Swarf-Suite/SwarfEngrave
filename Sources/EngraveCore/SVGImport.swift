// SVG reader: shapes and paths to millimetres, Y up. Styling (fill, stroke) is ignored; only geometry is read.
// Layers are the top-level groups (named by inkscape:label, else id); loose shapes go into one default layer.

import CAMCore
import CoreGraphics
import Foundation
import simd

enum SVGImporter {
    static func parse(data: Data, defaultLayerName: String) throws -> ImportedArtwork {
        let parser = XMLParser(data: data)
        let d = SVGDocumentReader(defaultLayerName: defaultLayerName)
        parser.delegate = d
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if !d.sawRoot {
            throw ImportError.unreadable(ok ? "The file has no <svg> element." : "The SVG couldn't be read: \(parser.parserError?.localizedDescription ?? "malformed XML").")
        }
        var warnings = d.warnings
        if !ok { warnings.append("The SVG is malformed after some point; only the part before it was imported.") }
        let layers = d.layers.map { (name: $0.name, path: ImportGeometry.join($0.path, tolerance: 0.01)) }.filter { !$0.path.isEmpty }
        if layers.isEmpty { warnings.append("No shapes were found in the SVG.") }
        return ImportedArtwork(layers: layers, warnings: warnings)
    }

    // MARK: Lengths and transforms

    /// Millimetres per unit for an SVG length suffix (user units are CSS px at 96 dpi).
    static func mmPerUnit(_ unit: String) -> Double? {
        switch unit.lowercased() {
        case "", "px": return 25.4 / 96
        case "mm": return 1
        case "cm": return 10
        case "in": return 25.4
        case "pt": return 25.4 / 72
        case "pc": return 25.4 / 6
        case "q": return 0.25
        default: return nil  // %, em, ex: not resolvable here
        }
    }

    /// A length in mm, or nil if missing or relative.
    static func lengthMM(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var numEnd = s.endIndex
        for (i, ch) in zip(s.indices, s) where !(ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E") {
            numEnd = i
            break
        }
        guard let v = Double(s[s.startIndex..<numEnd]), let k = mmPerUnit(String(s[numEnd...]).trimmingCharacters(in: .whitespaces)) else { return nil }
        return v * k
    }

    /// A plain user-unit number attribute (units other than px are converted to px).
    static func number(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        if let mm = lengthMM(s) { return mm / (25.4 / 96) }
        return nil
    }

    static func numberList(_ s: String) -> [Double] {
        var sc = SVGNumberScanner(s)
        var out: [Double] = []
        while let v = sc.number() { out.append(v) }
        return out
    }

    static func transform(_ s: String) -> CGAffineTransform {
        var m = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[rest.startIndex..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let args = numberList(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where args.count >= 6:
                t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate" where args.count >= 1:
                t = CGAffineTransform(translationX: args[0], y: args.count > 1 ? args[1] : 0)
            case "scale" where args.count >= 1:
                t = CGAffineTransform(scaleX: args[0], y: args.count > 1 ? args[1] : args[0])
            case "rotate" where args.count >= 1:
                let a = args[0] * .pi / 180
                if args.count >= 3 {
                    t = CGAffineTransform(translationX: -args[1], y: -args[2])
                        .concatenating(CGAffineTransform(rotationAngle: a))
                        .concatenating(CGAffineTransform(translationX: args[1], y: args[2]))
                } else {
                    t = CGAffineTransform(rotationAngle: a)
                }
            case "skewx" where args.count >= 1:
                t = CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy" where args.count >= 1:
                t = CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                continue
            }
            // The list applies right to left: the last transform acts on the point first.
            m = t.concatenating(m)
        }
        return m
    }

    // MARK: Path data

    static func pathData(_ d: String) -> Path2D {
        var sc = SVGNumberScanner(d)
        var path = Path2D()
        var cur = V2.zero, start = V2.zero
        var lastCubicCtrl: V2? = nil, lastQuadCtrl: V2? = nil
        var cmd: UInt8 = 0
        var needsMove = true

        func ensureSubpath() {
            if needsMove || path.subpaths.isEmpty || path.subpaths[path.subpaths.count - 1].closed {
                path.move(to: cur)
                start = cur
                needsMove = false
            }
        }

        while true {
            sc.skipSeparators()
            guard let c = sc.peek() else { break }
            if SVGNumberScanner.isLetter(c) {
                cmd = c
                sc.advance()
                if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                    if let last = path.subpaths.indices.last, !path.subpaths[last].segments.isEmpty {
                        path.close()
                    }
                    cur = start
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                    continue
                }
            } else if cmd == 0 || cmd == UInt8(ascii: "Z") || cmd == UInt8(ascii: "z") {
                break  // numbers without a command
            }
            let rel = cmd >= UInt8(ascii: "a")
            let base = rel ? cur : V2.zero
            switch cmd | 0x20 {  // lower-case
            case UInt8(ascii: "m"):
                guard let x = sc.number(), let y = sc.number() else { return path }
                cur = base + V2(x, y)
                if let last = path.subpaths.last, last.segments.isEmpty { path.subpaths.removeLast() }
                path.move(to: cur)
                start = cur
                needsMove = false
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")  // further pairs are line-tos
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case UInt8(ascii: "l"):
                guard let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                cur = base + V2(x, y)
                path.line(to: cur)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case UInt8(ascii: "h"):
                guard let x = sc.number() else { return path }
                ensureSubpath()
                cur = V2(rel ? cur.x + x : x, cur.y)
                path.line(to: cur)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case UInt8(ascii: "v"):
                guard let y = sc.number() else { return path }
                ensureSubpath()
                cur = V2(cur.x, rel ? cur.y + y : y)
                path.line(to: cur)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case UInt8(ascii: "c"):
                guard let x1 = sc.number(), let y1 = sc.number(), let x2 = sc.number(), let y2 = sc.number(),
                      let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                let a = base + V2(x1, y1), b = base + V2(x2, y2), e = base + V2(x, y)
                path.cubic(to: e, control1: a, control2: b)
                cur = e
                lastCubicCtrl = b; lastQuadCtrl = nil
            case UInt8(ascii: "s"):
                guard let x2 = sc.number(), let y2 = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                let a = lastCubicCtrl.map { 2 * cur - $0 } ?? cur
                let b = base + V2(x2, y2), e = base + V2(x, y)
                path.cubic(to: e, control1: a, control2: b)
                cur = e
                lastCubicCtrl = b; lastQuadCtrl = nil
            case UInt8(ascii: "q"):
                guard let x1 = sc.number(), let y1 = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                let c1 = base + V2(x1, y1), e = base + V2(x, y)
                path.quad(to: e, control: c1)
                cur = e
                lastQuadCtrl = c1; lastCubicCtrl = nil
            case UInt8(ascii: "t"):
                guard let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                let c1 = lastQuadCtrl.map { 2 * cur - $0 } ?? cur
                let e = base + V2(x, y)
                path.quad(to: e, control: c1)
                cur = e
                lastQuadCtrl = c1; lastCubicCtrl = nil
            case UInt8(ascii: "a"):
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let large = sc.flag(), let sweep = sc.flag(), let x = sc.number(), let y = sc.number() else { return path }
                ensureSubpath()
                let e = base + V2(x, y)
                for s in arc(from: cur, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep, to: e) {
                    switch s {
                    case .line(let p): path.line(to: p)
                    case .quad(let c, let p): path.quad(to: p, control: c)
                    case .cubic(let a, let b, let p): path.cubic(to: p, control1: a, control2: b)
                    }
                }
                cur = e
                lastCubicCtrl = nil; lastQuadCtrl = nil
            default:
                return path  // unknown command
            }
        }
        path.subpaths.removeAll { $0.segments.isEmpty }
        return path
    }

    /// SVG endpoint arc (implementation notes F.6.5) as cubic segments ending exactly at `p1`.
    static func arc(from p0: V2, rx rx0: Double, ry ry0: Double, rotation: Double, largeArc: Bool, sweep: Bool, to p1: V2) -> [Segment] {
        if simd_distance(p0, p1) < 1e-12 { return [] }
        var rx = abs(rx0), ry = abs(ry0)
        if rx < 1e-12 || ry < 1e-12 { return [.line(p1)] }
        let phi = rotation * .pi / 180
        let cp = cos(phi), sp = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cp * dx2 + sp * dy2, y1p = -sp * dx2 + cp * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? max(0, num / den).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let c = V2(cp * cxp - sp * cyp + (p0.x + p1.x) / 2, sp * cxp + cp * cyp + (p0.y + p1.y) / 2)
        func ang(_ u: V2, _ v: V2) -> Double { atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y) }
        let u = V2((x1p - cxp) / rx, (y1p - cyp) / ry)
        let v = V2((-x1p - cxp) / rx, (-y1p - cyp) / ry)
        let t1 = ang(V2(1, 0), u)
        var dt = ang(u, v)
        if !sweep && dt > 0 { dt -= 2 * .pi }
        if sweep && dt < 0 { dt += 2 * .pi }
        var segs = ImportGeometry.arcSegments(center: c, rx: rx, ry: ry, phi: phi, start: t1, sweep: dt)
        if case .cubic(let a, let b, _)? = segs.last { segs[segs.count - 1] = .cubic(a, b, p1) }
        return segs
    }
}

/// Number tokenizer for SVG path data and lists ("1.5.5", "-1-2", "1e-3", flags written without separators).
struct SVGNumberScanner {
    let bytes: [UInt8]
    var i = 0
    init(_ s: String) { bytes = Array(s.utf8) }

    func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }
    mutating func advance() { i += 1 }

    static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90 || c >= 97 && c <= 122) && c != UInt8(ascii: "e") && c != UInt8(ascii: "E")
    }

    mutating func skipSeparators() {
        while i < bytes.count {
            let c = bytes[i]
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 44 || c == 12 { i += 1 } else { break }
        }
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        if c == UInt8(ascii: "0") { i += 1; return false }
        if c == UInt8(ascii: "1") { i += 1; return true }
        return nil
    }

    mutating func number() -> Double? {
        skipSeparators()
        let s = i
        var j = i
        if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
        var digits = false, dot = false
        while j < bytes.count {
            let c = bytes[j]
            if c >= 48 && c <= 57 { digits = true; j += 1 }
            else if c == UInt8(ascii: "."), !dot { dot = true; j += 1 }
            else { break }
        }
        guard digits else { return nil }
        if j < bytes.count, bytes[j] == UInt8(ascii: "e") || bytes[j] == UInt8(ascii: "E") {
            var k = j + 1
            if k < bytes.count, bytes[k] == UInt8(ascii: "+") || bytes[k] == UInt8(ascii: "-") { k += 1 }
            var expDigits = false
            while k < bytes.count, bytes[k] >= 48 && bytes[k] <= 57 { k += 1; expDigits = true }
            if expDigits { j = k }
        }
        i = j
        return bytes[s..<j].withUnsafeBufferPointer { buf -> Double? in
            Double(String(decoding: buf, as: UTF8.self))
        }
    }
}

// MARK: XML walk

final class SVGDocumentReader: NSObject, XMLParserDelegate {
    struct Frame {
        var name: String
        var ctm: CGAffineTransform
        var skip: Bool
        var layer: Int?
    }

    let defaultLayerName: String
    var layers: [(name: String, path: Path2D)] = []
    var warnings: [String] = []
    var warned = Set<String>()
    var sawRoot = false
    private var stack: [Frame] = []
    private var defaultLayer: Int?

    init(defaultLayerName: String) { self.defaultLayerName = defaultLayerName }

    private func warn(_ s: String) {
        if warned.insert(s).inserted { warnings.append(s) }
    }

    private static let skipped: Set<String> = [
        "defs", "clippath", "mask", "symbol", "marker", "pattern", "metadata", "title", "desc", "style", "script",
        "lineargradient", "radialgradient", "filter", "foreignobject", "namedview",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attr: [String: String] = [:]) {
        let local = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
        let parent = stack.last
        var skip = parent?.skip ?? false
        if Self.skipped.contains(local) { skip = true }
        if Self.isHidden(attr) { skip = true }

        var ctm = parent?.ctm ?? .identity
        if !sawRoot && local == "svg" {
            sawRoot = true
            ctm = rootTransform(attr)
        } else if local == "svg" {
            // Nested viewport: position only.
            let x = SVGImporter.number(attr["x"]) ?? 0, y = SVGImporter.number(attr["y"]) ?? 0
            ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctm)
        }
        if let t = attr["transform"] { ctm = SVGImporter.transform(t).concatenating(ctm) }

        var layer = parent?.layer
        if !skip && local == "g" && stack.count == 1 {
            let name = attr["inkscape:label"] ?? attr["id"] ?? "Layer \(layers.count + 1)"
            layers.append((name: name, path: Path2D()))
            layer = layers.count - 1
        }
        stack.append(Frame(name: local, ctm: ctm, skip: skip, layer: layer))
        guard !skip, sawRoot else { return }

        var shape: Path2D?
        switch local {
        case "path":
            shape = SVGImporter.pathData(attr["d"] ?? "")
        case "rect":
            shape = Self.rect(attr)
        case "circle":
            let r = SVGImporter.number(attr["r"]) ?? 0
            if r > 0 {
                shape = Path2D([ImportGeometry.circle(center: V2(SVGImporter.number(attr["cx"]) ?? 0, SVGImporter.number(attr["cy"]) ?? 0), radius: r)])
            }
        case "ellipse":
            let rx = SVGImporter.number(attr["rx"]) ?? 0, ry = SVGImporter.number(attr["ry"]) ?? 0
            if rx > 0, ry > 0 {
                shape = Path2D.ellipse(width: 2 * rx, height: 2 * ry)
                    .mapped { $0 + V2(SVGImporter.number(attr["cx"]) ?? 0, SVGImporter.number(attr["cy"]) ?? 0) }
            }
        case "line":
            var p = Path2D()
            p.move(to: V2(SVGImporter.number(attr["x1"]) ?? 0, SVGImporter.number(attr["y1"]) ?? 0))
            p.line(to: V2(SVGImporter.number(attr["x2"]) ?? 0, SVGImporter.number(attr["y2"]) ?? 0))
            shape = p
        case "polyline", "polygon":
            let v = SVGImporter.numberList(attr["points"] ?? "")
            if v.count >= 4 {
                var p = Path2D()
                p.move(to: V2(v[0], v[1]))
                var k = 2
                while k + 1 < v.count { p.line(to: V2(v[k], v[k + 1])); k += 2 }
                if local == "polygon" { p.close() }
                shape = p
            }
        case "text", "tspan":
            warn("Text in the SVG was skipped: convert text to paths (outlines) before exporting.")
        case "image":
            warn("Embedded bitmaps in the SVG were skipped: import the image on its own to trace it.")
        case "use":
            warn("Cloned elements (<use>) in the SVG were skipped: unlink clones before exporting.")
        default:
            break
        }
        guard let s = shape, !s.isEmpty else { return }
        let placed = s.mapped { ImportGeometry.apply(ctm, $0) }
        let li: Int
        if let l = layer {
            li = l
        } else if let d = defaultLayer {
            li = d
        } else {
            layers.append((name: defaultLayerName, path: Path2D()))
            defaultLayer = layers.count - 1
            li = layers.count - 1
        }
        layers[li].path.append(placed)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    private static func isHidden(_ attr: [String: String]) -> Bool {
        if attr["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return true }
        if let style = attr["style"]?.replacingOccurrences(of: " ", with: ""), style.contains("display:none") { return true }
        return false
    }

    /// User units → mm with Y flipped (the document's top edge at its height, so artwork lands at Y ≥ 0).
    private func rootTransform(_ attr: [String: String]) -> CGAffineTransform {
        let vb = attr["viewBox"].map(SVGImporter.numberList) ?? []
        let wmm = SVGImporter.lengthMM(attr["width"]), hmm = SVGImporter.lengthMM(attr["height"])
        let px = 25.4 / 96
        var sx = px, sy = px, tx = 0.0, ty = 0.0
        var heightMM: Double?
        if vb.count == 4, vb[2] > 0, vb[3] > 0 {
            let (vx, vy, vw, vh) = (vb[0], vb[1], vb[2], vb[3])
            let w = wmm ?? (hmm.map { $0 * vw / vh } ?? vw * px)
            let h = hmm ?? (wmm.map { $0 * vh / vw } ?? vh * px)
            sx = w / vw
            sy = h / vh
            if !(attr["preserveAspectRatio"]?.hasPrefix("none") ?? false) {
                let s = min(sx, sy)
                // xMidYMid: centre the viewBox in the viewport.
                tx = (w - vw * s) / 2
                ty = (h - vh * s) / 2
                sx = s; sy = s
            }
            tx -= vx * sx
            ty -= vy * sy
            heightMM = h
        } else {
            heightMM = hmm
        }
        // x_mm = sx*x + tx; y_mm(up) = H - (sy*y + ty)
        let H = heightMM ?? 0
        return CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: tx, ty: H - ty)
    }

    private static func rect(_ attr: [String: String]) -> Path2D? {
        let x = SVGImporter.number(attr["x"]) ?? 0, y = SVGImporter.number(attr["y"]) ?? 0
        let w = SVGImporter.number(attr["width"]) ?? 0, h = SVGImporter.number(attr["height"]) ?? 0
        guard w > 0, h > 0 else { return nil }
        var rx = SVGImporter.number(attr["rx"]), ry = SVGImporter.number(attr["ry"])
        if rx == nil { rx = ry }
        if ry == nil { ry = rx }
        let r1 = min(max(0, rx ?? 0), w / 2), r2 = min(max(0, ry ?? 0), h / 2)
        var p = Path2D()
        if r1 <= 0 || r2 <= 0 {
            p.move(to: V2(x, y)); p.line(to: V2(x + w, y)); p.line(to: V2(x + w, y + h)); p.line(to: V2(x, y + h)); p.close()
            return p
        }
        let k = 0.5522847498
        p.move(to: V2(x + r1, y))
        p.line(to: V2(x + w - r1, y))
        p.cubic(to: V2(x + w, y + r2), control1: V2(x + w - r1 + k * r1, y), control2: V2(x + w, y + r2 - k * r2))
        p.line(to: V2(x + w, y + h - r2))
        p.cubic(to: V2(x + w - r1, y + h), control1: V2(x + w, y + h - r2 + k * r2), control2: V2(x + w - r1 + k * r1, y + h))
        p.line(to: V2(x + r1, y + h))
        p.cubic(to: V2(x, y + h - r2), control1: V2(x + r1 - k * r1, y + h), control2: V2(x, y + h - r2 + k * r2))
        p.line(to: V2(x, y + r2))
        p.cubic(to: V2(x + r1, y), control1: V2(x, y + r2 - k * r2), control2: V2(x + r1 - k * r1, y))
        p.close()
        return p
    }
}
