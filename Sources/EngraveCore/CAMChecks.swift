// Quick checks for the problems list: no toolpaths, just coarse rasters (milliseconds).

import CAMCore
import Foundation
import simd

enum CAMChecks {
    static func run(sheet: Sheet, bits: BitSettings) -> [PlanWarning] {
        var out: [PlanWarning] = []
        let T = sheet.stock.thickness
        let stock = sheet.stockRect
        let main = bits.main, vbit = bits.vBit
        for obj in sheet.objects where !obj.hidden && obj.cut.type != .none {
            let cut = obj.cut
            let name = obj.name.isEmpty ? obj.geometry.kindName : obj.name
            func warn(_ msg: String, _ sev: PlanWarning.Severity = .warning) {
                out.append(PlanWarning(objectID: obj.id, severity: sev, message: msg))
            }
            let polys = obj.outline().flattened(tolerance: 0.05).filter { !$0.points.isEmpty }
            if polys.isEmpty {
                if case .text(let t) = obj.geometry {
                    warn("Text “\(t.string)” has no outline, so nothing will be cut. Check that the font is installed.")
                } else {
                    warn("“\(name)” has no outline, so nothing will be cut.")
                }
                continue
            }
            guard let b = CAMPlanner.bounds(polys) else { continue }
            let grow = cut.type == .profile && cut.profileSide == .outside ? main.radius : 0
            let lo = b.min - V2(repeating: grow), hi = b.max + V2(repeating: grow)
            let eps = 0.01
            if hi.x < stock.min.x || hi.y < stock.min.y || lo.x > stock.max.x || lo.y > stock.max.y {
                warn("“\(name)” is off the stock, so it will not be cut.", .error)
                continue
            } else if lo.x < stock.min.x - eps || lo.y < stock.min.y - eps || hi.x > stock.max.x + eps || hi.y > stock.max.y + eps {
                warn("“\(name)” is partly off the stock; the bit will cut past the edge.")
            }
            if cut.type != .vcarve && !cut.through && cut.depth > T + 1e-6 {
                warn(String(format: "“%@” is %.1f mm deep but the stock is only %.1f mm thick. Turn on Through, or make it shallower.",
                            name, cut.depth, T))
            }
            let closed = Raster.fillable(polys)
            let hasOpen = polys.contains { !$0.closed } && closed.count < polys.count
            if (cut.type == .pocket || cut.type == .profile) && (closed.isEmpty || hasOpen) {
                let what = cut.type == .pocket ? "pocket" : "profile"
                warn(closed.isEmpty
                     ? "“\(name)” is an open path, so it cannot be a \(what). Use Engrave, or close the path."
                     : "“\(name)” has open parts that a \(what) cannot use; they are \(cut.type == .pocket ? "skipped" : "cut on the line").")
            }
            let depth = cut.effectiveDepth(thickness: T, overcut: bits.overcut)
            if cut.type != .vcarve && depth > main.fluteLength + 1e-6 {
                warn(String(format: "“%@” is %.1f mm deep, past the %.1f mm flute length of %@.", name, depth, main.fluteLength, main.name))
            }
            guard !closed.isEmpty, cut.type == .pocket || cut.type == .vcarve || (cut.type == .profile && cut.profileSide == .inside) else { continue }
            // Widest point of the shape, from a coarse distance transform.
            let size = b.size
            let res = max(0.05, min(0.5, max(size.x, size.y) / 300))
            let frame = RasterFrame(covering: b, margin: 2 * res, res: res, maxCells: 250_000)
            let mask = Raster.mask(closed, frame: frame)
            let d = DistanceTransform.distance(width: frame.width, height: frame.height, res: frame.res) { !mask[$0] }
            var maxD: Float = 0
            for i in 0..<frame.count where mask[i] { maxD = max(maxD, d[i]) }
            let widest = Double(maxD) * 2  // about the widest inscribed circle
            if cut.type == .vcarve {
                let tanH = tan(max(1, vbit.vAngle / 2) * .pi / 180)
                let natural = max(0, (Double(maxD) - vbit.tipDiameter / 2) / tanH)
                let planned = min(natural, cut.vcarveMaxDepth ?? .infinity, (vbit.radius - vbit.tipDiameter / 2) / tanH)
                if planned > vbit.fluteLength + 1e-6 {
                    warn(String(format: "“%@” would V-carve %.1f mm deep, past the %.1f mm flute length of the V-bit; it will be limited. Set a depth limit.",
                                name, planned, vbit.fluteLength))
                }
            } else {
                let bit = cut.type == .pocket ? (bits.clearing.map { min($0.diameter, main.diameter) } ?? main.diameter) : main.diameter
                if maxD > 0 && widest + frame.res < bit {
                    warn(String(format: "“%@” is narrower (%.1f mm) than the %.2f mm bit, so parts of it cannot be cut.", name, widest, bit))
                }
            }
        }
        return out
    }
}
