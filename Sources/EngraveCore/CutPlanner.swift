// Toolpaths from a sheet's objects. STUB: owned by the toolpath agent, which replaces the bodies (keep the API).

import CAMCore
import Foundation

public struct PlanWarning: Sendable, Equatable {
    public enum Severity: Sendable { case warning, error }
    public var objectID: UUID?
    public var severity: Severity
    public var message: String
    public init(objectID: UUID?, severity: Severity, message: String) {
        self.objectID = objectID
        self.severity = severity
        self.message = message
    }
}

public struct CarvePlan: Sendable {
    /// In cutting order, fewest bit changes; one entry per bit and cut kind.
    public var toolpaths: [Toolpath]
    public var warnings: [PlanWarning]
    /// Estimated machine time per toolpath (same order) and in total, seconds.
    public var seconds: [Double]
    public var totalSeconds: Double { seconds.reduce(0, +) }
    public init(toolpaths: [Toolpath] = [], warnings: [PlanWarning] = [], seconds: [Double] = []) {
        self.toolpaths = toolpaths
        self.warnings = warnings
        self.seconds = seconds
    }
}

public enum CutPlanner {
    /// Full toolpaths for every visible, cut object on the sheet. Slow-ish (seconds): run off the main thread.
    public static func plan(sheet: Sheet, bits: BitSettings, machine: MachineProfile) -> CarvePlan { CarvePlan() }

    /// Quick checks for the problems list, without making toolpaths (milliseconds).
    public static func check(sheet: Sheet, bits: BitSettings) -> [PlanWarning] { [] }
}

public enum CarvePreview {
    /// The carved surface as a height field in stock space (Z per cell; stock top = thickness), computed directly
    /// from the objects' cuts and bits, fast enough to refresh while editing (aim < 150 ms on a 300 × 200 mm sheet
    /// at the default resolution).
    public static func surface(sheet: Sheet, bits: BitSettings, resolution: Double? = nil) -> Grid2D {
        Grid2D(covering: .zero, V2(sheet.stock.width, sheet.stock.height), res: resolution ?? 0.5, fill: Float(sheet.stock.thickness))
    }

    /// The surface left by real toolpaths (StockSimulator), for checking a plan.
    public static func simulate(sheet: Sheet, toolpaths: [Toolpath], resolution: Double? = nil) -> Grid2D {
        surface(sheet: sheet, bits: BitSettings(), resolution: resolution)
    }
}

public enum GCodeExport {
    /// Post-processed files, one per bit when the machine splits files per tool.
    public static func files(sheet: Sheet, plan: CarvePlan, machine: MachineProfile, bits: BitSettings, jobName: String) -> [GCodeHub.File] { [] }
}
