// The SwarfEngrave document: sheets of stock, each holding design objects with their own cut.
// This file is the contract between the editor, the importers and the toolpath code: change it with care and
// keep it Codable-compatible (new fields need defaults in `init(from:)`).

import CAMCore
import Foundation

public struct EngraveDocument: Codable, Sendable, Equatable {
    public var formatVersion: Int = 1
    public var sheets: [Sheet]
    public var machineID: String
    public var bits: BitSettings

    public init(sheets: [Sheet] = [Sheet()], machineID: String = MachineProfile.grbl.id, bits: BitSettings = BitSettings()) {
        self.sheets = sheets
        self.machineID = machineID
        self.bits = bits
    }

    public var machine: MachineProfile { EngraveDocument.machines.first { $0.id == machineID } ?? .grbl }

    /// Machine profiles offered in Machine & Bits (SwarfPath's list).
    public static var machines: [MachineProfile] {
        [.grbl, .foxalienXEProUltra, .shapeoko, .longmill, .xcarve, .genmitsu, .onefinity, .grblHAL, .workbeeRRF, .duetGeneric, .linuxcnc]
    }
}

public struct Sheet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var name: String = "Sheet 1"
    public var stock: Stock = Stock()
    public var workZero: WorkZero = WorkZero()
    /// Back to front in drawing order (last is on top).
    public var objects: [DesignObject] = []

    public init(id: UUID = UUID(), name: String = "Sheet 1", stock: Stock = Stock(), workZero: WorkZero = WorkZero(), objects: [DesignObject] = []) {
        self.id = id
        self.name = name
        self.stock = stock
        self.workZero = workZero
        self.objects = objects
    }

    public var stockRect: Rect2D { Rect2D(min: .zero, max: V2(stock.width, stock.height)) }
}

public struct Stock: Codable, Sendable, Equatable {
    public var width: Double = 200  // X, mm
    public var height: Double = 100  // Y, mm
    public var thickness: Double = 12  // Z, mm
    /// CAMCore `Material` id, which sets feeds and speeds (mdf, plywood, softwood, hardwood, acrylic, hdpe, foam, aluminium).
    public var materialID: String = "hardwood"
    /// Display colour for the 3D view, "#rrggbb".
    public var colorHex: String = "#b07a4a"
    public var showGrain: Bool = true

    public init(width: Double = 200, height: Double = 100, thickness: Double = 12, materialID: String = "hardwood", colorHex: String = "#b07a4a") {
        self.width = width
        self.height = height
        self.thickness = thickness
        self.materialID = materialID
        self.colorHex = colorHex
    }

    public var size: V3 { V3(width, height, thickness) }
    public var material: Material { Material.named(materialID) }

    /// Species presets for the Stock picker: name, CAMCore material id, colour.
    public static let species: [(name: String, materialID: String, colorHex: String)] = [
        ("Maple", "hardwood", "#e3c99a"), ("Oak", "hardwood", "#c49a62"), ("Walnut", "hardwood", "#6b4a33"),
        ("Cherry", "hardwood", "#b5683f"), ("Mahogany", "hardwood", "#8a4a32"), ("Ash", "hardwood", "#d9c4a0"),
        ("Pine", "softwood", "#e6c88f"), ("Plywood", "plywood", "#d8b98a"), ("MDF", "mdf", "#a88a66"),
        ("Acrylic", "acrylic", "#cfd8dc"), ("HDPE", "hdpe", "#eeeeee"), ("Aluminium", "aluminium", "#b8bcc2"),
    ]
}

public struct WorkZero: Codable, Sendable, Equatable {
    public enum Corner: String, Codable, Sendable, CaseIterable, Identifiable {
        case frontLeft, frontRight, backLeft, backRight, center
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .frontLeft: return "Front left"
            case .frontRight: return "Front right"
            case .backLeft: return "Back left"
            case .backRight: return "Back right"
            case .center: return "Centre"
            }
        }
    }
    public var corner: Corner = .frontLeft
    /// Z zero on the stock top (true) or on the spoilboard (false).
    public var zOnTop: Bool = true

    public init(corner: Corner = .frontLeft, zOnTop: Bool = true) {
        self.corner = corner
        self.zOnTop = zOnTop
    }

    /// Work zero in stock space (Z = 0 at the stock bottom).
    public func origin(for stock: Stock) -> V3 {
        let z = zOnTop ? stock.thickness : 0
        switch corner {
        case .frontLeft: return V3(0, 0, z)
        case .frontRight: return V3(stock.width, 0, z)
        case .backLeft: return V3(0, stock.height, z)
        case .backRight: return V3(stock.width, stock.height, z)
        case .center: return V3(stock.width / 2, stock.height / 2, z)
        }
    }
}

// MARK: Objects

public struct DesignObject: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var geometry: ObjectGeometry
    public var transform: Transform2D
    public var cut: CutSettings = CutSettings()
    public var hidden: Bool = false
    public var locked: Bool = false
    /// Objects with the same group id move and select together.
    public var groupID: UUID? = nil

    public init(id: UUID = UUID(), name: String, geometry: ObjectGeometry, transform: Transform2D = .identity, cut: CutSettings = CutSettings()) {
        self.id = id
        self.name = name
        self.geometry = geometry
        self.transform = transform
        self.cut = cut
    }

    /// Geometry in the object's own coordinates (centred on its origin for built-in shapes).
    public func localPath() -> Path2D { geometry.path() }

    /// Geometry placed in stock space.
    public func outline() -> Path2D { localPath().applying(transform) }

    /// Stock-space bounds of the placed geometry.
    public var bounds: Rect2D? { outline().tightBounds(tolerance: 0.05) }
}

public enum ObjectGeometry: Codable, Sendable, Equatable {
    case rectangle(width: Double, height: Double, cornerRadius: Double)
    case ellipse(width: Double, height: Double)
    case polygon(sides: Int, radius: Double)
    case star(points: Int, outerRadius: Double, innerRadius: Double)
    case line(length: Double)
    /// Free paths: drawn with the pen tool or imported (SVG, DXF, PDF, traced images). Centred on the origin on import.
    case path(Path2D)
    case text(TextSpec)

    public func path() -> Path2D {
        switch self {
        case .rectangle(let w, let h, let r): return .rect(width: w, height: h, cornerRadius: r)
        case .ellipse(let w, let h): return .ellipse(width: w, height: h)
        case .polygon(let n, let r): return .polygon(sides: n, radius: r)
        case .star(let n, let ro, let ri): return .star(points: n, outerRadius: ro, innerRadius: ri)
        case .line(let l): return .line(length: l)
        case .path(let p): return p
        case .text(let t): return TextOutliner.path(for: t)
        }
    }

    /// Whether the geometry is meant to enclose areas (pocket, profile, V-carve make sense).
    public var isClosed: Bool {
        switch self {
        case .line: return false
        case .path(let p): return p.subpaths.contains { $0.closed }
        default: return true
        }
    }

    public var kindName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .line: return "Line"
        case .path: return "Path"
        case .text: return "Text"
        }
    }
}

public struct TextSpec: Codable, Sendable, Equatable {
    public enum Alignment: String, Codable, Sendable, CaseIterable { case left, center, right }
    public enum SizeMode: String, Codable, Sendable, CaseIterable { case capHeight, em }
    public enum Layout: Codable, Sendable, Equatable {
        case straight
        /// Text around a circle of this radius (mm), reading along the top (clockwise) or the bottom.
        case arc(radius: Double, top: Bool)
        /// Text along a path in the object's local coordinates.
        case onPath(Path2D)
    }

    public var string: String
    /// PostScript name of any font installed on the Mac (e.g. "Helvetica-Bold", "SnellRoundhand").
    public var fontName: String
    /// Variable-font axis values, keyed by the four-character axis tag ("wght", "wdth", "slnt", …).
    public var variations: [String: Double] = [:]
    public var size: Double = 20  // mm
    public var sizeMode: SizeMode = .capHeight
    public var tracking: Double = 0  // mm added between letters
    public var lineSpacing: Double = 1.2  // multiple of size
    public var alignment: Alignment = .center
    public var layout: Layout = .straight

    public init(string: String, fontName: String = "Helvetica-Bold", size: Double = 20) {
        self.string = string
        self.fontName = fontName
        self.size = size
    }
}

// MARK: Cuts

public enum CutType: String, Codable, Sendable, CaseIterable, Identifiable {
    case none  // drawn only, not cut (guides, construction)
    case engrave  // bit on the line
    case profile  // inside or outside the line
    case pocket  // clear the area
    case vcarve  // V-bit, depth from width
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: return "Guide"
        case .engrave: return "Engrave"
        case .profile: return "Profile"
        case .pocket: return "Pocket"
        case .vcarve: return "V-carve"
        }
    }
    /// SF Symbol for sidebar rows and the segmented control.
    public var symbol: String {
        switch self {
        case .none: return "pencil.and.outline"
        case .engrave: return "scribble"
        case .profile: return "square.dashed"
        case .pocket: return "square.fill"
        case .vcarve: return "chevron.down"
        }
    }
}

public enum ProfileSide: String, Codable, Sendable, CaseIterable { case outside, inside, on }

public struct TabSettings: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var length: Double = 6
    public var height: Double = 2
    public var count: Int = 4
    /// Hand-placed tabs as fractions of the outline's length (0..<1); empty = spaced evenly by `count`.
    public var positions: [Double] = []
    public init() {}
}

public struct CutSettings: Codable, Sendable, Equatable {
    public var type: CutType = .pocket
    /// Depth below the stock top, mm. Ignored when `through` is set.
    public var depth: Double = 3
    public var through: Bool = false
    public var profileSide: ProfileSide = .outside
    public var tabs: TabSettings = TabSettings()
    /// V-carve: optional depth limit (flat bottom); nil = full depth to the medial axis.
    public var vcarveMaxDepth: Double? = nil

    public init(type: CutType = .pocket, depth: Double = 3) {
        self.type = type
        self.depth = depth
    }

    /// Depth actually cut for a stock of this thickness and the given overcut.
    public func effectiveDepth(thickness: Double, overcut: Double) -> Double {
        through ? thickness + overcut : min(depth, thickness + overcut)
    }
}

public struct BitSettings: Codable, Sendable, Equatable {
    /// Main bit: engraving, profiles and pocket finishing.
    public var main: Tool
    /// Optional larger bit to clear big pockets first.
    public var clearing: Tool?
    /// V-bit for V-carve objects.
    public var vBit: Tool
    /// Extra depth for through cuts, mm.
    public var overcut: Double = 0.3
    /// Safe height above the stock top, mm.
    public var safeHeight: Double = 5

    public init(main: Tool? = nil, clearing: Tool? = nil, vBit: Tool? = nil) {
        let lib = ToolLibrary.starter
        self.main = main ?? lib.tools.first { $0.kind == .flat && abs($0.diameter - 3.175) < 0.01 } ?? lib.tools[0]
        self.clearing = clearing
        self.vBit = vBit ?? lib.tools.first { $0.kind == .vBit && $0.vAngle == 60 } ?? lib.tools[0]
    }
}
