// The fast preview: the intended carved surface as a height field, straight from the objects' cuts (no toolpaths).

import CAMCore
import Foundation
import simd

enum PreviewSurface {
    /// Default cell size for a stock: 0.25 mm or coarser, at most about 250 000 cells.
    static func defaultResolution(for stock: Stock) -> Double {
        max(0.25, (stock.width * stock.height / 250_000).squareRoot())
    }

    static func surface(sheet: Sheet, bits: BitSettings, resolution: Double?) -> Grid2D {
        let st = sheet.stock
        let T = st.thickness
        let res = max(0.02, resolution ?? defaultResolution(for: st))
        var g = Grid2D(covering: .zero, V2(st.width, st.height), res: res, fill: Float(T))
        let full = RasterFrame(origin: g.origin, res: g.res, width: g.width, height: g.height)
        var z = g.data
        let main = bits.main, vbit = bits.vBit

        struct Obj { var obj: DesignObject; var closed: [Polyline2D]; var all: [Polyline2D]; var bottom: Double }
        var objs: [Obj] = []
        for o in sheet.objects where !o.hidden && o.cut.type != .none {
            let polys = o.outline().flattened(tolerance: max(0.02, res / 4)).filter { !$0.points.isEmpty }
            guard !polys.isEmpty else { continue }
            let depth = o.cut.effectiveDepth(thickness: T, overcut: bits.overcut)
            objs.append(Obj(obj: o, closed: Raster.fillable(polys), all: polys, bottom: T - depth))
        }

        // Pockets: one floor field (deepest wins, enclosed shallower pockets stay as islands).
        let pockets = objs.filter { $0.obj.cut.type == .pocket && !$0.closed.isEmpty }
            .map { PocketItem(polys: $0.closed, bottomZ: $0.bottom, objectID: $0.obj.id) }
        if !pockets.isEmpty {
            let floor = CAMPlanner.floorField(pockets, frame: full, top: T)
            for i in 0..<z.count where floor[i] < z[i] { z[i] = floor[i] }
        }

        for o in objs {
            guard let b = CAMPlanner.bounds(o.all) else { continue }
            switch o.obj.cut.type {
            case .none, .pocket:
                continue
            case .profile:
                let R = main.radius
                let side = o.obj.cut.profileSide
                let sub = subframe(full, b, grow: main.diameter + 2 * res)
                guard let f = sub else { continue }
                let u = Raster.lineDistance(o.all, frame: f.frame, reach: main.diameter + res)
                let inside = Raster.mask(o.closed, frame: f.frame)
                let floorZ = Float(o.bottom)
                apply(&z, full, f) { k in
                    let d = Double(u[k])
                    let hit: Bool
                    if o.closed.isEmpty || side == .on { hit = d <= R }
                    else if side == .outside { hit = !inside[k] && d <= 2 * R }
                    else { hit = inside[k] && d <= 2 * R }
                    return hit ? floorZ : nil
                }
            case .engrave:
                groove(&z, full, o.all, bottom: o.bottom, tool: main, T: T, res: res, b: b)
            case .vcarve:
                let tanH = tan(max(1, vbit.vAngle / 2) * .pi / 180)
                let tip = vbit.tipDiameter / 2
                let cap = min(o.obj.cut.vcarveMaxDepth ?? .infinity, vbit.fluteLength, (vbit.radius - tip) / tanH, T + bits.overcut)
                let open = o.all.filter { !$0.closed }
                if !open.isEmpty { groove(&z, full, open, bottom: o.bottom, tool: vbit, T: T, res: res, b: b) }
                guard !o.closed.isEmpty, let f = subframe(full, b, grow: 2 * res) else { continue }
                let mask = Raster.mask(o.closed, frame: f.frame)
                let d = DistanceTransform.distance(width: f.frame.width, height: f.frame.height, res: f.frame.res) { !mask[$0] }
                let h = Float(f.frame.res * 0.5)
                apply(&z, full, f) { k in
                    guard mask[k] else { return nil }
                    let e = Double(max(0, min(d[k], 1e6) - h))
                    return Float(T - min(cap, max(0, (e - tip) / tanH)))
                }
            }
        }
        g.data = z
        return g
    }

    /// A groove along lines: flat-bottomed and bit-wide, or V-shaped for a V-bit.
    private static func groove(_ z: inout [Float], _ full: RasterFrame, _ lines: [Polyline2D], bottom: Double, tool: Tool, T: Double, res: Double, b: Rect2D) {
        let depth = T - bottom
        let r = max(res * 0.5, tool.cuttingRadius(depth: depth))
        guard let f = subframe(full, b, grow: r + 2 * res) else { return }
        let u = Raster.lineDistance(lines, frame: f.frame, reach: r + res)
        let isV = tool.kind == .vBit || tool.kind == .drill
        let tanH = tan(max(1, tool.vAngle / 2) * .pi / 180)
        let tip = tool.tipDiameter / 2
        apply(&z, full, f) { k in
            let d = Double(u[k])
            if isV {
                let zz = bottom + max(0, d - tip) / tanH
                return zz < T && d <= r + res * 0.5 ? Float(zz) : nil
            }
            return d <= r ? Float(bottom) : nil
        }
    }

    struct Sub { var frame: RasterFrame; var i0: Int; var j0: Int }

    /// The part of `full` covering `rect` grown by `grow`, aligned to its cells.
    private static func subframe(_ full: RasterFrame, _ rect: Rect2D, grow: Double) -> Sub? {
        let i0 = max(0, Int(((rect.min.x - grow - full.origin.x) / full.res).rounded(.down)))
        let j0 = max(0, Int(((rect.min.y - grow - full.origin.y) / full.res).rounded(.down)))
        let i1 = min(full.width - 1, Int(((rect.max.x + grow - full.origin.x) / full.res).rounded(.up)))
        let j1 = min(full.height - 1, Int(((rect.max.y + grow - full.origin.y) / full.res).rounded(.up)))
        guard i1 >= i0, j1 >= j0 else { return nil }
        let f = RasterFrame(origin: full.world(i0, j0), res: full.res, width: i1 - i0 + 1, height: j1 - j0 + 1)
        return Sub(frame: f, i0: i0, j0: j0)
    }

    /// Lowers the surface to `value(k)` (sub-frame cell index) wherever it is deeper.
    private static func apply(_ z: inout [Float], _ full: RasterFrame, _ s: Sub, _ value: (Int) -> Float?) {
        let W = s.frame.width
        for j in 0..<s.frame.height {
            let row = (s.j0 + j) * full.width + s.i0
            for i in 0..<W {
                if let v = value(j * W + i), v < z[row + i] { z[row + i] = v }
            }
        }
    }
}
