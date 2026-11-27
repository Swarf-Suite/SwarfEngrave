// Text → outlines with Core Text: any installed font by PostScript name (variable-font axes applied), laid out by
// CTLine so kerning, ligatures and font fallback are as Core Text sets them, then placed straight, around a circle
// or along a path. Results are in mm, Y up, centred on the origin, and cached.

import CAMCore
import CoreGraphics
import CoreText
import Foundation
import simd

public enum TextOutliner {
    /// Used when the requested font isn't installed.
    public static let fallbackFontName = "Helvetica"

    /// Outline of the text in local coordinates (mm, Y up), centred on the origin.
    public static func path(for spec: TextSpec) -> Path2D {
        if let hit = TextCache.shared.result(for: spec) { return hit }
        let p = build(spec)
        TextCache.shared.store(p, for: spec)
        return p
    }

    /// Whether a font with exactly this PostScript name is available (system, user-installed or activated).
    public static func isInstalled(_ postScriptName: String) -> Bool {
        TextCache.shared.installed(postScriptName) {
            let f = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            return (CTFontCopyPostScriptName(f) as String) == postScriptName
        }
    }

    /// The PostScript name actually used for a spec (the fallback when its font is missing).
    public static func resolvedFontName(for spec: TextSpec) -> String {
        isInstalled(spec.fontName) ? spec.fontName : fallbackFontName
    }

    /// Four-character variation tag ("wght") ↔ its numeric identifier.
    public static func tagNumber(_ tag: String) -> UInt32? {
        let b = Array(tag.utf8)
        guard b.count == 4 else { return nil }
        return b.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func tagString(_ n: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(n)
    }

    // MARK: Building

    static let refSize: CGFloat = 100  // layout point size; outlines are scaled from it

    static func font(for spec: TextSpec) -> CTFont {
        let name = resolvedFontName(for: spec)
        var attrs: [CFString: Any] = [kCTFontNameAttribute: name]
        if !spec.variations.isEmpty, name == spec.fontName {
            var v: [NSNumber: NSNumber] = [:]
            for (tag, value) in spec.variations {
                if let n = tagNumber(tag) { v[NSNumber(value: n)] = NSNumber(value: value) }
            }
            attrs[kCTFontVariationAttribute] = v
        }
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, refSize, nil)
    }

    struct PlacedGlyph {
        var outline: Path2D  // pt at refSize, glyph origin at (0, 0)
        var x: Double  // origin x after alignment and tracking, pt
        var advance: Double  // pt
        var line: Int
    }

    static func build(_ spec: TextSpec) -> Path2D {
        let lines = spec.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return Path2D() }
        let font = font(for: spec)
        let cap = Double(CTFontGetCapHeight(font))
        // mm per pt at the layout size.
        let k: Double
        switch spec.sizeMode {
        case .capHeight: k = spec.size / (cap > 1e-6 ? cap : 0.7 * Double(refSize))
        case .em: k = spec.size / Double(refSize)
        }
        guard k.isFinite, k > 0 else { return Path2D() }
        let trackPt = spec.tracking / k
        let lineStepMM = spec.lineSpacing * spec.size

        var glyphs: [PlacedGlyph] = []
        for (li, text) in lines.enumerated() where !text.isEmpty {
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
            var lineGlyphs: [PlacedGlyph] = []
            var idx = 0
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var gl = [CGGlyph](repeating: 0, count: count)
                var pos = [CGPoint](repeating: .zero, count: count)
                var adv = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &gl)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &pos)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &adv)
                let runAttrs = CTRunGetAttributes(run) as NSDictionary
                let runFontRef = runAttrs[kCTFontAttributeName as String]
                let runFont = runFontRef.map { $0 as! CTFont } ?? font
                let fontKey = fontCacheKey(runFont)
                for g in 0..<count {
                    let outline = TextCache.shared.glyph(fontKey, gl[g]) { glyphOutline(runFont, gl[g]) }
                    lineGlyphs.append(PlacedGlyph(outline: outline, x: Double(pos[g].x) + Double(idx) * trackPt,
                                                  advance: Double(adv[g].width), line: li))
                    idx += 1
                }
            }
            let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil)) + Double(max(0, idx - 1)) * trackPt
            let shift: Double
            switch spec.alignment {
            case .left: shift = 0
            case .center: shift = -width / 2
            case .right: shift = -width
            }
            for var g in lineGlyphs {
                g.x += shift
                glyphs.append(g)
            }
        }

        var out = Path2D()
        for g in glyphs where !g.outline.isEmpty {
            let baseline = -Double(g.line) * lineStepMM  // mm
            let cx = (g.x + g.advance / 2) * k  // glyph centre along the line, mm
            switch spec.layout {
            case .straight:
                out.append(g.outline.mapped { V2(($0.x + g.x) * k, $0.y * k + baseline) })
            case .arc(let radius, let top):
                let R = max(radius, 0.1)
                let r = top ? R + baseline : R - baseline
                let theta = top ? Double.pi / 2 - cx / max(r, 0.1) : -Double.pi / 2 + cx / max(r, 0.1)
                let rot = top ? theta - .pi / 2 : theta + .pi / 2
                let c = cos(rot), s = sin(rot)
                let anchor = r * V2(cos(theta), sin(theta))
                let x0 = g.advance / 2
                out.append(g.outline.mapped { p in
                    let u = (p.x - x0) * k, v = p.y * k
                    return anchor + V2(c * u - s * v, s * u + c * v)
                })
            case .onPath(let guide):
                let frame = PathFrame(guide)
                let base: Double
                switch spec.alignment {
                case .left: base = 0
                case .center: base = frame.length / 2
                case .right: base = frame.length
                }
                let (pt, t) = frame.point(at: base + cx)
                let nrm = V2(-t.y, t.x)
                let x0 = g.advance / 2
                out.append(g.outline.mapped { p in
                    let u = (p.x - x0) * k, v = p.y * k + baseline
                    return pt + t * u + nrm * v
                })
            }
        }
        guard let b = out.tightBounds(tolerance: 0.05) else { return out }
        let c = b.center
        return out.mapped { $0 - c }
    }

    static func fontCacheKey(_ f: CTFont) -> String {
        var key = CTFontCopyPostScriptName(f) as String
        if let v = CTFontCopyVariation(f) as? [NSNumber: NSNumber], !v.isEmpty {
            key += "|" + v.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        }
        return key
    }

    static func glyphOutline(_ f: CTFont, _ g: CGGlyph) -> Path2D {
        guard let cg = CTFontCreatePathForGlyph(f, g, nil) else { return Path2D() }
        var out = Path2D()
        func v(_ p: CGPoint) -> V2 { V2(Double(p.x), Double(p.y)) }
        cg.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: out.move(to: v(el.points[0]))
            case .addLineToPoint: out.line(to: v(el.points[0]))
            case .addQuadCurveToPoint: out.quad(to: v(el.points[1]), control: v(el.points[0]))
            case .addCurveToPoint: out.cubic(to: v(el.points[2]), control1: v(el.points[0]), control2: v(el.points[1]))
            case .closeSubpath: out.close()
            @unknown default: break
            }
        }
        out.subpaths.removeAll { $0.segments.isEmpty }
        return out
    }
}

/// Arc-length lookup along the first subpath of a guide path (extended straight past either end).
struct PathFrame {
    var pts: [V2]
    var cum: [Double]
    var length: Double { cum.last ?? 0 }

    init(_ p: Path2D) {
        var pts: [V2] = []
        if let pl = p.flattened(tolerance: 0.02).first {
            pts = pl.points
            if pl.closed, let f = pts.first { pts.append(f) }
        }
        if pts.count < 2 { pts = [V2(0, 0), V2(1, 0)] }
        self.pts = pts
        var c = [0.0]
        for i in 1..<pts.count { c.append(c[i - 1] + simd_distance(pts[i - 1], pts[i])) }
        cum = c
    }

    func point(at s: Double) -> (V2, V2) {
        let n = pts.count
        func dir(_ i: Int) -> V2 {
            let d = pts[i + 1] - pts[i]
            let l = simd_length(d)
            return l > 1e-12 ? d / l : V2(1, 0)
        }
        if s <= 0 { let t = dir(0); return (pts[0] + t * s, t) }
        if s >= length { let t = dir(n - 2); return (pts[n - 1] + t * (s - length), t) }
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= s { lo = mid } else { hi = mid }
        }
        let seg = cum[lo + 1] - cum[lo]
        let f = seg > 1e-12 ? (s - cum[lo]) / seg : 0
        let p = pts[lo] + (pts[lo + 1] - pts[lo]) * f
        return (p, dir(lo))
    }
}

/// Thread-safe caches: glyph outlines, finished layouts (small LRU), and font-installed lookups.
final class TextCache: @unchecked Sendable {
    static let shared = TextCache()
    private let lock = NSLock()
    private var glyphs: [String: [CGGlyph: Path2D]] = [:]
    private var results: [(TextSpec, Path2D)] = []
    private var installedNames: [String: Bool] = [:]
    private let maxResults = 96

    func result(for spec: TextSpec) -> Path2D? {
        lock.lock(); defer { lock.unlock() }
        guard let i = results.firstIndex(where: { $0.0 == spec }) else { return nil }
        let hit = results.remove(at: i)
        results.append(hit)
        return hit.1
    }

    func store(_ p: Path2D, for spec: TextSpec) {
        lock.lock(); defer { lock.unlock() }
        results.append((spec, p))
        if results.count > maxResults { results.removeFirst(results.count - maxResults) }
    }

    func glyph(_ font: String, _ g: CGGlyph, make: () -> Path2D) -> Path2D {
        lock.lock()
        if let p = glyphs[font]?[g] { lock.unlock(); return p }
        lock.unlock()
        let p = make()
        lock.lock()
        glyphs[font, default: [:]][g] = p
        lock.unlock()
        return p
    }

    func installed(_ name: String, check: () -> Bool) -> Bool {
        lock.lock()
        if let v = installedNames[name] { lock.unlock(); return v }
        lock.unlock()
        let v = check()
        lock.lock()
        installedNames[name] = v
        lock.unlock()
        return v
    }

    /// Forget cached lookups (after fonts are installed or removed).
    func reset() {
        lock.lock()
        installedNames = [:]
        results = []
        glyphs = [:]
        lock.unlock()
    }
}
