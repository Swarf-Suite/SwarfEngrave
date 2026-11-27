// Toolpaths from a sheet's objects, the carve preview and G-code export. The work is done in CAMPlanner,
// CAMChecks and PreviewSurface; this file is the public face.

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
    public static func plan(sheet: Sheet, bits: BitSettings, machine: MachineProfile) -> CarvePlan {
        var planner = CAMPlanner(sheet: sheet, bits: bits, machine: machine)
        var plan = planner.plan()
        var warnings = check(sheet: sheet, bits: bits)
        for w in plan.warnings where !warnings.contains(where: { $0.objectID == w.objectID && $0.message.contains("flute") }) {
            warnings.append(w)
        }
        plan.warnings = warnings
        return plan
    }

    /// Quick checks for the problems list, without making toolpaths (milliseconds).
    public static func check(sheet: Sheet, bits: BitSettings) -> [PlanWarning] { CAMChecks.run(sheet: sheet, bits: bits) }

    /// Safe height for rapids, in stock space.
    public static func safeZ(sheet: Sheet, bits: BitSettings) -> Double { sheet.stock.thickness + max(1, bits.safeHeight) }
}

public enum CarvePreview {
    /// The carved surface as a height field in stock space (Z per cell; stock top = thickness), computed directly
    /// from the objects' cuts and bits, fast enough to refresh while editing (aim < 150 ms on a 300 × 200 mm sheet
    /// at the default resolution).
    public static func surface(sheet: Sheet, bits: BitSettings, resolution: Double? = nil) -> Grid2D {
        PreviewSurface.surface(sheet: sheet, bits: bits, resolution: resolution)
    }

    /// The cell size `surface` uses when none is given.
    public static func defaultResolution(for stock: Stock) -> Double { PreviewSurface.defaultResolution(for: stock) }

    /// The surface left by real toolpaths (StockSimulator), for checking a plan.
    public static func simulate(sheet: Sheet, toolpaths: [Toolpath], resolution: Double? = nil) -> Grid2D {
        var sim = StockSimulator(stockSize: sheet.stock.size, resolution: resolution ?? StockSimulator.defaultResolution(for: sheet.stock.size))
        sim.run(toolpaths)
        return sim.stock
    }
}

public enum GCodeExport {
    /// Post-processed files, one per bit when the machine splits files per tool.
    public static func files(sheet: Sheet, plan: CarvePlan, machine: MachineProfile, bits: BitSettings, jobName: String) -> [GCodeHub.File] {
        GCodeWriter.files(sheet: sheet, toolpaths: plan.toolpaths, machine: machine, bits: bits, jobName: jobName)
    }
}
