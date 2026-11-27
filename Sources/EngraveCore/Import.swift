// Artwork import: vector files (SVG, DXF, PDF) to millimetre paths, and bitmap loading/tracing entry points.
// The format readers live in SVGImport.swift, DXFImport.swift, PDFImport.swift; tracing in TraceImage.swift.

import CAMCore
import CoreGraphics
import Foundation
import ImageIO
import simd

public struct ImportedArtwork: Sendable {
    /// One entry per layer/group in the file; paths in millimetres, Y up, NOT yet centred.
    public var layers: [(name: String, path: Path2D)]
    public var warnings: [String]
    public init(layers: [(name: String, path: Path2D)], warnings: [String] = []) {
        self.layers = layers
        self.warnings = warnings
    }

    /// All layers in one path.
    public var combined: Path2D {
        var p = Path2D()
        for l in layers { p.append(l.path) }
        return p
    }
}

public enum ImportError: Error, LocalizedError {
    case unreadable(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let s), .unsupported(let s): return s
        }
    }
}

public enum ArtworkImporter {
    /// File extensions `importVector` understands.
    public static let vectorExtensions = ["svg", "dxf", "pdf", "ai"]

    /// SVG, DXF, PDF (and PDF-compatible .ai), by file extension. EPS is not supported yet.
    public static func importVector(url: URL) throws -> ImportedArtwork {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "svg":
            guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable("Couldn't read \(url.lastPathComponent).") }
            return try SVGImporter.parse(data: data, defaultLayerName: url.deletingPathExtension().lastPathComponent)
        case "dxf":
            guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable("Couldn't read \(url.lastPathComponent).") }
            let text = String(decoding: data, as: UTF8.self)
            return try DXFImporter.parse(text)
        case "pdf", "ai":
            return try PDFImporter.parse(url: url)
        case "eps", "ps":
            throw ImportError.unsupported("EPS files aren't supported yet. Save the artwork as PDF or SVG and import that.")
        default:
            throw ImportError.unsupported("\(url.lastPathComponent) isn't a vector format SwarfEngrave reads (SVG, DXF, PDF).")
        }
    }

    /// Parses SVG text directly (tests, paste).
    public static func importSVG(_ string: String, layerName: String = "Layer 1") throws -> ImportedArtwork {
        try SVGImporter.parse(data: Data(string.utf8), defaultLayerName: layerName)
    }

    /// Parses ASCII DXF text directly.
    public static func importDXF(_ string: String) throws -> ImportedArtwork { try DXFImporter.parse(string) }

    /// Joins open subpaths whose ends meet within `tolerance` mm into longer (and where possible closed) subpaths.
    public static func joinOpenSubpaths(_ path: Path2D, tolerance: Double = 0.01) -> Path2D {
        ImportGeometry.join(path, tolerance: tolerance)
    }
}

public struct TraceOptions: Sendable, Equatable {
    public var threshold: Double = 0.5  // 0...1 brightness
    public var invert = false
    public var smoothing: Double = 0.5  // 0...1
    public var minDetail: Double = 0.5  // mm; specks smaller than this are dropped
    public var targetWidth: Double = 100  // mm, the traced artwork's width
    public init() {}
}

public enum ImageTracer {
    /// Traces dark areas (or light, with invert) of a bitmap (PNG, JPEG, HEIC, TIFF) to closed paths in mm, Y up.
    /// Outer boundaries run counter-clockwise and holes clockwise, so both fill rules give the same result.
    public static func trace(cgImage: CGImage, options: TraceOptions) -> Path2D {
        TraceEngine.trace(cgImage: cgImage, options: options)
    }

    public static func loadImage(url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ImportError.unreadable("Couldn't read \(url.lastPathComponent) as an image.")
        }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: true]
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            throw ImportError.unreadable("Couldn't decode \(url.lastPathComponent).")
        }
        return img
    }
}

// MARK: Shared helpers for the readers

enum ImportGeometry {
    /// Cubic Béziers for an elliptical arc: centre, radii, x-axis rotation `phi` (radians), start angle and sweep (radians,
    /// positive counter-clockwise in the ellipse's own frame).
    static func arcSegments(center c: V2, rx: Double, ry: Double, phi: Double, start t0: Double, sweep dt: Double) -> [Segment] {
        guard abs(dt) > 1e-12 else { return [] }
        let n = max(1, Int((abs(dt) / (Double.pi / 2) - 1e-9).rounded(.up)))
        let d = dt / Double(n)
        let k = 4.0 / 3.0 * tan(d / 4)
        let cp = cos(phi), sp = sin(phi)
        func pt(_ t: Double) -> V2 {
            let x = rx * cos(t), y = ry * sin(t)
            return c + V2(cp * x - sp * y, sp * x + cp * y)
        }
        func der(_ t: Double) -> V2 {
            let x = -rx * sin(t), y = ry * cos(t)
            return V2(cp * x - sp * y, sp * x + cp * y)
        }
        var out: [Segment] = []
        var t = t0
        for _ in 0..<n {
            let t1 = t + d
            let p0 = pt(t), p3 = pt(t1)
            out.append(.cubic(p0 + k * der(t), p3 - k * der(t1), p3))
            t = t1
        }
        return out
    }

    static func circle(center c: V2, radius r: Double) -> SubPath {
        let segs = arcSegments(center: c, rx: r, ry: r, phi: 0, start: 0, sweep: 2 * .pi)
        var sp = SubPath(start: c + V2(r, 0), segments: segs, closed: true)
        if case .cubic(let a, let b, _)? = sp.segments.last { sp.segments[sp.segments.count - 1] = .cubic(a, b, sp.start) }
        return sp
    }

    static func endPoint(_ sp: SubPath) -> V2 { sp.segments.last?.end ?? sp.start }

    static func reversed(_ sp: SubPath) -> SubPath {
        var pts = [sp.start]
        for s in sp.segments { pts.append(s.end) }
        var segs: [Segment] = []
        segs.reserveCapacity(sp.segments.count)
        for i in stride(from: sp.segments.count - 1, through: 0, by: -1) {
            let to = pts[i]
            switch sp.segments[i] {
            case .line: segs.append(.line(to))
            case .quad(let c, _): segs.append(.quad(c, to))
            case .cubic(let a, let b, _): segs.append(.cubic(b, a, to))
            }
        }
        return SubPath(start: pts[pts.count - 1], segments: segs, closed: sp.closed)
    }

    /// Joins open subpaths end-to-end where their ends are within `tolerance`; closes chains whose ends meet.
    static func join(_ path: Path2D, tolerance tol: Double) -> Path2D {
        var closed: [SubPath] = []
        var open: [SubPath] = []
        for sp in path.subpaths where !sp.segments.isEmpty {
            if sp.closed { closed.append(sp) } else { open.append(sp) }
        }
        guard !open.isEmpty else { return Path2D(closed) }

        // Spatial hash over endpoints: key → [(subpath index, isEnd)].
        let cell = max(tol * 2, 1e-6)
        struct Key: Hashable { var x: Int; var y: Int }
        func key(_ p: V2) -> Key { Key(x: Int((p.x / cell).rounded(.down)), y: Int((p.y / cell).rounded(.down))) }
        var grid: [Key: [Int]] = [:]  // value = index * 2 + (0 start, 1 end)
        for (i, sp) in open.enumerated() {
            grid[key(sp.start), default: []].append(i * 2)
            grid[key(endPoint(sp)), default: []].append(i * 2 + 1)
        }
        var used = [Bool](repeating: false, count: open.count)
        func findPartner(near p: V2, excluding: Int) -> Int? {
            let k = key(p)
            var best: Int?
            var bestD = tol
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let list = grid[Key(x: k.x + dx, y: k.y + dy)] else { continue }
                    for code in list {
                        let i = code / 2
                        if used[i] || i == excluding { continue }
                        let q = code % 2 == 0 ? open[i].start : endPoint(open[i])
                        let d = simd_distance(p, q)
                        if d <= bestD { bestD = d; best = code }
                    }
                }
            }
            return best
        }

        var result = closed
        for i in open.indices where !used[i] {
            used[i] = true
            var chain = open[i]
            // Extend forward from the end, then backward from the start.
            for forward in [true, false] {
                while true {
                    let p = forward ? endPoint(chain) : chain.start
                    if simd_distance(chain.start, endPoint(chain)) <= tol && chain.segments.count > 1 { break }
                    guard let code = findPartner(near: p, excluding: -1) else { break }
                    let j = code / 2
                    used[j] = true
                    var other = open[j]
                    if forward {
                        if code % 2 == 1 { other = reversed(other) }  // its end touches our end
                        chain.segments += other.segments
                    } else {
                        if code % 2 == 0 { other = reversed(other) }  // its start touches our start
                        other.segments += chain.segments
                        chain = SubPath(start: other.start, segments: other.segments)
                    }
                }
            }
            if chain.segments.count > 1 || chain.segments.contains(where: { if case .line = $0 { return false } else { return true } }),
               simd_distance(chain.start, endPoint(chain)) <= tol {
                // Snap the closing point exactly and close.
                let last = chain.segments.count - 1
                switch chain.segments[last] {
                case .line: chain.segments[last] = .line(chain.start)
                case .quad(let c, _): chain.segments[last] = .quad(c, chain.start)
                case .cubic(let a, let b, _): chain.segments[last] = .cubic(a, b, chain.start)
                }
                if case .line(let e) = chain.segments[last], e == chain.start, chain.segments.count > 2 {
                    chain.segments.removeLast()  // the implicit close covers it
                }
                chain.closed = true
            }
            result.append(chain)
        }
        return Path2D(result)
    }

    static func apply(_ t: CGAffineTransform, _ p: V2) -> V2 {
        V2(Double(t.a) * p.x + Double(t.c) * p.y + Double(t.tx), Double(t.b) * p.x + Double(t.d) * p.y + Double(t.ty))
    }
}
