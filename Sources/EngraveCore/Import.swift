// Artwork import. STUB: owned by the text/import agent, which replaces this file (keep the API).

import CAMCore
import CoreGraphics
import Foundation

public struct ImportedArtwork: Sendable {
    /// One entry per layer/group in the file; paths in millimetres, Y up, NOT yet centred.
    public var layers: [(name: String, path: Path2D)]
    public var warnings: [String]
    public init(layers: [(name: String, path: Path2D)], warnings: [String] = []) {
        self.layers = layers
        self.warnings = warnings
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
    /// SVG, DXF, PDF/EPS (vector), by file extension.
    public static func importVector(url: URL) throws -> ImportedArtwork { throw ImportError.unsupported("Not implemented yet") }
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
    public static func trace(cgImage: CGImage, options: TraceOptions) -> Path2D { Path2D() }
    public static func loadImage(url: URL) throws -> CGImage { throw ImportError.unsupported("Not implemented yet") }
}
