// The design canvas: an AppKit view drawn with Core Graphics. Stock space (mm, Y up) maps to view points as
// `view = stock * zoom + pan`; NSView's default Y-up coordinates match stock space, so no flip is needed.

import AppKit
import CAMCore
import EngraveCore
import simd

/// View-only state shared with the SwiftUI overlays (zoom readout, commands).
@MainActor
final class CanvasViewState: ObservableObject {
    @Published var zoomPercent: Double = 100
    weak var view: CanvasNSView?
}

/// Cursor position for the coordinates readout (kept apart so only the readout redraws on mouse moves).
@MainActor
final class CanvasCursor: ObservableObject {
    @Published var stock: V2?
    @Published var measure: String?
}

@MainActor
final class CanvasNSView: NSView {
    var model: EditorModel!
    weak var state: CanvasViewState?
    weak var cursor: CanvasCursor?

    let cache = CanvasShapeCache()
    private(set) var zoom: CGFloat = 2
    private var pan = CGPoint(x: 40, y: 40)
    private var needsFit = true
    private var sheetKey = ""

    static let rulerSize: CGFloat = 20
    /// Points per mm at 100 %.
    static let actualSize: CGFloat = 72 / 25.4

    // MARK: Interaction state

    private enum PointRef: Equatable {
        case start(Int)  // subpath
        case end(Int, Int)  // subpath, segment
        case c1(Int, Int)
        case c2(Int, Int)
    }

    private enum Drag {
        case none
        case pan(last: CGPoint)
        case marquee(start: V2, end: V2, base: Set<UUID>)
        case move(start: V2, originals: [DesignObject], bounds: Rect2D)
        case resize(handle: Int, originals: [DesignObject], bounds: Rect2D)
        case rotate(start: V2, centre: V2, originals: [DesignObject])
        case point(object: DesignObject, path: Path2D, ref: PointRef)
        case pen(index: Int, start: V2)
        case measure(start: V2)
    }

    private struct PenPoint {
        var anchor: V2
        var out: V2?
        var inHandle: V2? { out.map { 2 * anchor - $0 } }
    }

    private enum Guide { case x(Double), y(Double) }

    private var drag: Drag = .none
    private var didDrag = false
    private var preview: [UUID: DesignObject] = [:]
    private var guides: [Guide] = []
    private var measureLine: (V2, V2)?
    private var pen: [PenPoint] = []
    private var hover: V2?
    private var spaceDown = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Model sync

    func modelChanged() {
        guard let model else { return }
        let s = model.sheet
        let key = "\(s.id)|\(s.stock.width)|\(s.stock.height)"
        if key != sheetKey {
            sheetKey = key
            needsFit = true
        }
        if model.tool != .pen, !pen.isEmpty { pen = []; }
        if model.tool != .measure { measureLine = nil; cursor?.measure = nil }
        needsDisplay = true
    }

    // MARK: Coordinates

    func toView(_ p: V2) -> CGPoint { CGPoint(x: CGFloat(p.x) * zoom + pan.x, y: CGFloat(p.y) * zoom + pan.y) }
    func toStock(_ q: CGPoint) -> V2 { V2(Double((q.x - pan.x) / zoom), Double((q.y - pan.y) / zoom)) }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    /// Tolerance in mm for a distance in points.
    private func mm(_ pts: CGFloat) -> Double { Double(pts / zoom) }

    func zoomToFit() {
        guard let model, bounds.width > 100, bounds.height > 100 else { needsFit = true; return }
        let st = model.sheet.stock
        let left: CGFloat = Self.rulerSize + 64, right: CGFloat = 40, top: CGFloat = Self.rulerSize + 30, bottom: CGFloat = 60
        let aw = bounds.width - left - right, ah = bounds.height - top - bottom
        zoom = max(0.05, min(200, min(aw / CGFloat(max(1, st.width)), ah / CGFloat(max(1, st.height)))))
        pan = CGPoint(x: left + (aw - CGFloat(st.width) * zoom) / 2, y: bottom + (ah - CGFloat(st.height) * zoom) / 2)
        needsFit = false
        publishZoom()
        needsDisplay = true
    }

    func zoom(by f: CGFloat, around p: CGPoint? = nil) {
        let c = p ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let s = toStock(c)
        zoom = max(0.05, min(400, zoom * f))
        pan = CGPoint(x: c.x - CGFloat(s.x) * zoom, y: c.y - CGFloat(s.y) * zoom)
        publishZoom()
        needsDisplay = true
    }

    private func publishZoom() {
        let pct = Double(zoom / Self.actualSize * 100)
        if abs((state?.zoomPercent ?? 0) - pct) > 0.01 { state?.zoomPercent = pct }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if needsFit { zoomToFit() }
    }

    // MARK: Object queries

    private func displayed(_ o: DesignObject) -> DesignObject { preview[o.id] ?? o }

    private var visibleObjects: [DesignObject] { model.sheet.objects.filter { !$0.hidden }.map(displayed) }

    private func bounds(of o: DesignObject) -> Rect2D? { cache.entry(for: o).bounds }

    private func selectionBounds() -> Rect2D? {
        var r: Rect2D?
        for o in model.sheet.objects where model.selection.contains(o.id) && !o.hidden {
            if let b = bounds(of: displayed(o)) { r = r?.union(b) ?? b }
        }
        return r
    }

    private func isFilled(_ o: DesignObject) -> Bool {
        o.geometry.isClosed && [.pocket, .profile, .vcarve].contains(o.cut.type)
    }

    /// Topmost selectable object under a stock point.
    private func hitObject(_ s: V2) -> DesignObject? {
        let tol = mm(5)
        for o0 in model.sheet.objects.reversed() where !o0.hidden && !o0.locked {
            let o = displayed(o0)
            let e = cache.entry(for: o)
            guard let b = e.bounds, b.canvasInset(tol + (o.cut.type == .engrave ? model.doc.bits.main.diameter : 0)).contains(s) else { continue }
            if isFilled(o) || o.geometry.isClosed && o.cut.type != .none && o.cut.type != .engrave {
                if e.path.contains(o.transform.invert(s).cg, using: .winding) { return o }
            }
            let strokeTol = tol + (o.cut.type == .engrave ? model.doc.bits.main.diameter / 2 : 0)
            if CanvasGeom.nearest(s, on: cache.stockPolys(for: o)).dist <= strokeTol { return o }
        }
        return nil
    }

    // Handles: 0 BL, 1 B, 2 BR, 3 R, 4 TR, 5 T, 6 TL, 7 L.
    private func handlePoints(_ b: Rect2D) -> [V2] {
        let c = b.center
        return [b.min, V2(c.x, b.min.y), V2(b.max.x, b.min.y), V2(b.max.x, c.y), b.max, V2(c.x, b.max.y), V2(b.min.x, b.max.y), V2(b.min.x, c.y)]
    }

    private func rotateHandle(_ b: Rect2D) -> CGPoint {
        let t = toView(V2(b.center.x, b.max.y))
        return CGPoint(x: t.x, y: t.y + 24)
    }

    private var selectionEditable: Bool {
        !model.selection.isEmpty && model.selectedObjects.allSatisfy { !$0.locked }
    }

    /// Objects whose points can be edited directly.
    private func pointEditable(_ o: DesignObject) -> Bool {
        if case .text = o.geometry { return false }
        return !o.locked && !o.hidden
    }

    private func editablePath(_ o: DesignObject) -> Path2D {
        if case .path(let p) = o.geometry { return p }
        return o.geometry.path()
    }

    private func pointValue(_ p: Path2D, _ r: PointRef) -> V2? {
        switch r {
        case .start(let i): return i < p.subpaths.count ? p.subpaths[i].start : nil
        case .end(let i, let j): return p.subpaths[i].segments[j].end
        case .c1(let i, let j):
            switch p.subpaths[i].segments[j] {
            case .quad(let c, _): return c
            case .cubic(let a, _, _): return a
            default: return nil
            }
        case .c2(let i, let j):
            if case .cubic(_, let b, _) = p.subpaths[i].segments[j] { return b }
            return nil
        }
    }

    private func pointRefs(_ p: Path2D) -> (anchors: [PointRef], controls: [PointRef]) {
        var a: [PointRef] = [], c: [PointRef] = []
        for (i, sp) in p.subpaths.enumerated() {
            a.append(.start(i))
            for (j, s) in sp.segments.enumerated() {
                // A closed subpath's last point usually repeats the start; skip the duplicate anchor.
                let dup = sp.closed && j == sp.segments.count - 1 && simd_distance(s.end, sp.start) < 1e-6
                if !dup { a.append(.end(i, j)) }
                switch s {
                case .quad: c.append(.c1(i, j))
                case .cubic: c.append(.c1(i, j)); c.append(.c2(i, j))
                case .line: break
                }
            }
        }
        return (a, c)
    }

    private func hitPoint(_ q: CGPoint) -> (DesignObject, PointRef)? {
        for o in model.sheet.objects.reversed() where model.selection.contains(o.id) && pointEditable(o) {
            let d = displayed(o)
            let p = editablePath(d)
            let refs = pointRefs(p)
            for r in refs.anchors + refs.controls {
                guard let v = pointValue(p, r) else { continue }
                let vq = toView(d.transform.apply(v))
                if hypot(vq.x - q.x, vq.y - q.y) <= 6 { return (o, r) }
            }
        }
        return nil
    }

    private func moved(_ p0: Path2D, _ r: PointRef, to v: V2) -> Path2D {
        var p = p0
        guard let old = pointValue(p0, r) else { return p0 }
        let d = v - old
        func shift(_ i: Int, _ j: Int, c1: Bool, c2: Bool, end: Bool) {
            guard i < p.subpaths.count, j >= 0, j < p.subpaths[i].segments.count else { return }
            switch p.subpaths[i].segments[j] {
            case .line(let e): p.subpaths[i].segments[j] = .line(end ? e + d : e)
            case .quad(let c, let e): p.subpaths[i].segments[j] = .quad(c1 ? c + d : c, end ? e + d : e)
            case .cubic(let a, let b, let e): p.subpaths[i].segments[j] = .cubic(c1 ? a + d : a, c2 ? b + d : b, end ? e + d : e)
            }
        }
        switch r {
        case .start(let i):
            let sp = p.subpaths[i]
            p.subpaths[i].start = v
            shift(i, 0, c1: true, c2: false, end: false)
            if sp.closed, let last = sp.segments.last, simd_distance(last.end, sp.start) < 1e-6 {
                shift(i, sp.segments.count - 1, c1: false, c2: true, end: true)
            }
        case .end(let i, let j):
            shift(i, j, c1: false, c2: true, end: true)
            let sp = p.subpaths[i]
            if j + 1 < sp.segments.count { shift(i, j + 1, c1: true, c2: false, end: false) }
            else if sp.closed { shift(i, 0, c1: true, c2: false, end: false) }
        case .c1(let i, let j): shift(i, j, c1: true, c2: false, end: false)
        case .c2(let i, let j): shift(i, j, c1: false, c2: true, end: false)
        }
        return p
    }

    // MARK: Snapping

    private var gridSteps: (major: Double, minor: Double) {
        if model.useInches { return (25.4, 25.4 / 4) }
        let g = max(0.1, model.gridSpacing)
        return (g, g / 5)
    }

    private func snapGrid(_ v: Double) -> Double { CanvasGeom.grid(v, gridSteps.minor) }

    private func snapMove(_ raw: V2, bounds b: Rect2D, excluding ids: Set<UUID>, free: Bool) -> V2 {
        guides = []
        guard !free else { return raw }
        let tol = mm(6)
        let st = model.sheet.stock
        var xs: [Double] = [0, st.width / 2, st.width], ys: [Double] = [0, st.height / 2, st.height]
        for o in model.sheet.objects where !o.hidden && !ids.contains(o.id) {
            if let ob = bounds(of: o) {
                xs += [ob.min.x, ob.center.x, ob.max.x]
                ys += [ob.min.y, ob.center.y, ob.max.y]
            }
        }
        var d = raw
        func axis(_ mine: [Double], _ targets: [Double]) -> (Double, Double)? {
            var best: (Double, Double)?  // correction, target
            for m in mine {
                for t in targets {
                    let c = t - m
                    if abs(c) <= tol, best == nil || abs(c) < abs(best!.0) { best = (c, t) }
                }
            }
            return best
        }
        let mx = [b.min.x + raw.x, b.center.x + raw.x, b.max.x + raw.x]
        let my = [b.min.y + raw.y, b.center.y + raw.y, b.max.y + raw.y]
        if let (c, t) = axis(mx, xs) { d.x += c; guides.append(.x(t)) }
        else if model.snapToGrid { d.x = snapGrid(b.min.x + raw.x) - b.min.x }
        if let (c, t) = axis(my, ys) { d.y += c; guides.append(.y(t)) }
        else if model.snapToGrid { d.y = snapGrid(b.min.y + raw.y) - b.min.y }
        return d
    }

    private func snapPoint(_ s: V2, free: Bool) -> V2 {
        guard !free, model.snapToGrid else { return s }
        return V2(snapGrid(s.x), snapGrid(s.y))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let q = point(e), s = toStock(q)
        didDrag = false
        guard let model else { return }
        if spaceDown { drag = .pan(last: q); NSCursor.closedHand.set(); return }
        let shift = e.modifierFlags.contains(.shift)
        switch model.tool {
        case .select:
            if selectionEditable, let b = selectionBounds() {
                let rh = rotateHandle(b)
                if hypot(rh.x - q.x, rh.y - q.y) <= 7 {
                    drag = .rotate(start: s, centre: b.center, originals: model.selectedObjects)
                    return
                }
                for (i, h) in handlePoints(b).enumerated() {
                    let hv = toView(h)
                    if abs(hv.x - q.x) <= 6 && abs(hv.y - q.y) <= 6 {
                        drag = .resize(handle: i, originals: model.selectedObjects, bounds: b)
                        return
                    }
                }
            }
            if let o = hitObject(s) {
                let ids = model.canvasGroupIDs(of: o.id)
                if e.clickCount == 2, case .text = o.geometry {
                    model.selection = ids
                    model.showInspector = true
                    drag = .none
                    return
                }
                if shift {
                    if model.selection.isSuperset(of: ids) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
                    drag = .none
                } else {
                    if !model.selection.contains(o.id) { model.selection = ids }
                    let objs = model.selectedObjects.filter { !$0.locked }
                    drag = .move(start: s, originals: objs, bounds: selectionBounds() ?? Rect2D(min: s, max: s))
                }
            } else {
                let base = shift ? model.selection : []
                if !shift && !model.selection.isEmpty { model.selection = [] }
                drag = .marquee(start: s, end: s, base: base)
            }
        case .directSelect:
            if let (o, r) = hitPoint(q) {
                drag = .point(object: o, path: editablePath(o), ref: r)
            } else if let o = hitObject(s) {
                model.selection = [o.id]
                drag = .none
            } else {
                model.selection = []
                drag = .none
            }
        case .pen:
            if pen.count >= 2, hypot(toView(pen[0].anchor).x - q.x, toView(pen[0].anchor).y - q.y) <= 7 {
                finishPen(closed: true)
                drag = .none
                return
            }
            let p = snapPoint(s, free: e.modifierFlags.contains(.command))
            pen.append(PenPoint(anchor: p))
            drag = .pen(index: pen.count - 1, start: p)
        case .measure:
            let p = snapPoint(s, free: e.modifierFlags.contains(.command))
            measureLine = (p, p)
            drag = .measure(start: p)
            updateMeasureText()
        case .placeTabs:
            toggleTab(at: s)
            drag = .none
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let q = point(e), s = toStock(q)
        didDrag = true
        cursor?.stock = s
        let free = e.modifierFlags.contains(.command)
        switch drag {
        case .none: return
        case .pan(let last):
            pan.x += q.x - last.x; pan.y += q.y - last.y
            drag = .pan(last: q)
        case .marquee(let a, _, let base):
            drag = .marquee(start: a, end: s, base: base)
            let r = Rect2D(min: simd_min(a, s), max: simd_max(a, s))
            var sel = base
            for o in model.sheet.objects where !o.hidden && !o.locked {
                if let b = bounds(of: o), r.intersects(b) { sel.formUnion(model.canvasGroupIDs(of: o.id)) }
            }
            if sel != model.selection { model.selection = sel }
        case .move(let start, let originals, let b):
            let ids = Set(originals.map(\.id))
            let d = snapMove(s - start, bounds: b, excluding: ids, free: free)
            preview = [:]
            for o in originals {
                var m = o
                m.transform.position += d
                preview[o.id] = m
            }
        case .resize(let h, let originals, let b):
            resizePreview(handle: h, originals: originals, bounds: b, to: snapPoint(s, free: free), uniform: e.modifierFlags.contains(.shift))
        case .rotate(let start, let c, let originals):
            var delta = (atan2(s.y - c.y, s.x - c.x) - atan2(start.y - c.y, start.x - c.x)) * 180 / .pi
            if e.modifierFlags.contains(.shift) { delta = (delta / 15).rounded() * 15 }
            let a = delta * .pi / 180, ca = cos(a), sa = sin(a)
            preview = [:]
            for o in originals {
                var m = o
                let r = o.transform.position - c
                m.transform.position = c + V2(ca * r.x - sa * r.y, sa * r.x + ca * r.y)
                var rot = o.transform.rotation + delta
                rot = (rot + 180).truncatingRemainder(dividingBy: 360)
                if rot < 0 { rot += 360 }
                m.transform.rotation = rot - 180
                preview[o.id] = m
            }
        case .point(let o, let path, let ref):
            var m = o
            let target = o.transform.invert(snapPoint(s, free: free))
            m.geometry = .path(moved(path, ref, to: target))
            preview = [o.id: m]
        case .pen(let i, let start):
            if i < pen.count {
                let off = s - start
                pen[i].out = simd_length(off) * Double(zoom) > 3 ? s : nil
            }
        case .measure(let start):
            measureLine = (start, snapPoint(s, free: free))
            updateMeasureText()
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; guides = []; needsDisplay = true }
        guard let model else { return }
        switch drag {
        case .pan:
            NSCursor.arrow.set()
            if spaceDown { NSCursor.openHand.set() }
        case .move(_, let originals, _), .resize(_, let originals, _), .rotate(_, _, let originals):
            let name: String = {
                switch drag {
                case .move: return originals.count == 1 ? "Move Object" : "Move Objects"
                case .resize: return "Resize"
                default: return "Rotate"
                }
            }()
            let changes = preview
            preview = [:]
            guard didDrag, !changes.isEmpty else { return }
            model.editSheet(name) { s in
                for i in s.objects.indices { if let m = changes[s.objects[i].id] { s.objects[i] = m } }
            }
        case .point(let o, _, _):
            let m = preview[o.id]
            preview = [:]
            if didDrag, let m { model.editObject(o.id, "Edit Points") { $0.geometry = m.geometry } }
        case .pen:
            break
        default:
            break
        }
    }

    private func resizePreview(handle h: Int, originals: [DesignObject], bounds b: Rect2D, to s: V2, uniform: Bool) {
        let hp = handlePoints(b)
        let anchor = hp[(h + 4) % 8]
        let from = hp[h]
        let movesX = h != 1 && h != 5, movesY = h != 3 && h != 7
        var sx = 1.0, sy = 1.0
        if movesX, abs(from.x - anchor.x) > 1e-9 { sx = (s.x - anchor.x) / (from.x - anchor.x) }
        if movesY, abs(from.y - anchor.y) > 1e-9 { sy = (s.y - anchor.y) / (from.y - anchor.y) }
        sx = max(0.01, sx); sy = max(0.01, sy)
        if uniform {
            let k: Double = movesX && movesY ? max(sx, sy) : (movesX ? sx : sy)
            sx = k; sy = k
        }
        preview = [:]
        for o in originals { preview[o.id] = EditorModel.canvasResized(o, sx: sx, sy: sy, anchor: anchor) }
    }

    override func mouseMoved(with e: NSEvent) {
        let q = point(e)
        let s = toStock(q)
        cursor?.stock = s
        setNeedsDisplay(NSRect(x: 0, y: bounds.maxY - Self.rulerSize, width: bounds.width, height: Self.rulerSize))
        setNeedsDisplay(NSRect(x: 0, y: 0, width: Self.rulerSize, height: bounds.height))
        if model?.tool == .pen, !pen.isEmpty { hover = snapPoint(s, free: e.modifierFlags.contains(.command)); needsDisplay = true }
        updateCursor(q)
    }

    override func mouseExited(with e: NSEvent) {
        cursor?.stock = nil
        hover = nil
        needsDisplay = true
    }

    private func updateCursor(_ q: CGPoint) {
        if spaceDown { NSCursor.openHand.set(); return }
        switch model?.tool {
        case .pen, .measure, .placeTabs: NSCursor.crosshair.set()
        default: NSCursor.arrow.set()
        }
    }

    override func rightMouseDown(with e: NSEvent) { drag = .pan(last: point(e)) }
    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func rightMouseUp(with e: NSEvent) { drag = .none }
    override func otherMouseDown(with e: NSEvent) { drag = .pan(last: point(e)) }
    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { drag = .none }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            pan.x += e.scrollingDeltaX
            pan.y -= e.scrollingDeltaY
            needsDisplay = true
        } else {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.08
            zoom(by: max(0.5, min(1.5, 1 + dy)), around: point(e))
        }
    }

    override func magnify(with e: NSEvent) { zoom(by: max(0.5, min(1.5, 1 + e.magnification)), around: point(e)) }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard let model else { return }
        switch e.keyCode {
        case 49:  // space: pan while held
            if !spaceDown { spaceDown = true; NSCursor.openHand.set() }
            return
        case 51, 117:  // delete, forward delete
            if !model.selection.isEmpty { model.deleteSelection(); return }
        case 123, 124, 125, 126:  // arrows
            if !model.selection.isEmpty {
                let step = e.modifierFlags.contains(.shift) ? 10.0 : e.modifierFlags.contains(.option) ? 0.1 : 1.0
                let d: V2 = e.keyCode == 123 ? V2(-step, 0) : e.keyCode == 124 ? V2(step, 0) : e.keyCode == 125 ? V2(0, -step) : V2(0, step)
                model.nudge(by: d)
                return
            }
        case 53:  // Esc
            if model.tool == .pen, !pen.isEmpty { finishPen(closed: false); return }
            if model.tool == .measure, measureLine != nil { measureLine = nil; cursor?.measure = nil; needsDisplay = true; return }
            model.selection = []
            return
        case 36, 76:  // Return
            if model.tool == .pen, !pen.isEmpty { finishPen(closed: true); return }
        default: break
        }
        super.keyDown(with: e)
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = false; NSCursor.arrow.set(); return }
        super.keyUp(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "=", "+": zoom(by: 1.25); return true
        case "-": zoom(by: 0.8); return true
        case "0": zoomToFit(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    // MARK: Pen

    private func finishPen(closed: Bool) {
        defer { pen = []; hover = nil; needsDisplay = true }
        guard pen.count >= 2 || (closed && pen.count >= 3) else { return }
        var p = Path2D()
        p.move(to: pen[0].anchor)
        func seg(_ a: PenPoint, _ b: PenPoint) {
            if a.out == nil && b.inHandle == nil { p.line(to: b.anchor) }
            else { p.cubic(to: b.anchor, control1: a.out ?? a.anchor, control2: b.inHandle ?? b.anchor) }
        }
        for i in 1..<pen.count { seg(pen[i - 1], pen[i]) }
        if closed {
            seg(pen[pen.count - 1], pen[0])
            p.close()
        }
        let c = p.tightBounds(tolerance: 0.05)?.center ?? pen[0].anchor
        var o = DesignObject(name: "Path", geometry: .path(p.mapped { $0 - c }), transform: Transform2D(position: c))
        if !closed { o.cut.type = .engrave; o.cut.depth = 0.5 }
        model.add(o)
    }

    // MARK: Measure

    private func updateMeasureText() {
        guard let (a, b) = measureLine else { cursor?.measure = nil; return }
        let d = b - a
        let len = simd_length(d)
        let ang = atan2(d.y, d.x) * 180 / .pi
        let txt = model.useInches ? String(format: "%.3f in", len / 25.4) : String(format: "%.2f mm", len)
        cursor?.measure = "\(txt)  ·  \(String(format: "%.1f°", ang))  ·  ΔX \(fmt(d.x))  ΔY \(fmt(d.y))"
    }

    private func fmt(_ v: Double) -> String { model.useInches ? String(format: "%.3f", v / 25.4) : String(format: "%.2f", v) }

    // MARK: Tabs

    private func tabCandidates() -> [DesignObject] {
        visibleObjects.filter { $0.cut.type == .profile && $0.cut.through && $0.geometry.isClosed }
    }

    private func closedPolys(_ o: DesignObject) -> [Polyline2D] { cache.stockPolys(for: o).filter(\.closed) }

    /// Tab positions as drawn: hand-placed ones, or evenly spaced by count.
    static func tabPositions(_ t: EngraveCore.TabSettings) -> [Double] {
        if !t.positions.isEmpty { return t.positions }
        let n = max(0, t.count)
        return (0..<n).map { (Double($0) + 0.5) / Double(n) }
    }

    private func toggleTab(at s: V2) {
        var best: (DesignObject, Double, Double)?  // object, along, total
        var bestDist = mm(8)
        for o in tabCandidates() where !o.locked {
            let r = CanvasGeom.nearest(s, on: closedPolys(o))
            if r.dist < bestDist, r.total > 0 { bestDist = r.dist; best = (o, r.along, r.total) }
        }
        guard let (o, along, total) = best else { return }
        let f = along / total
        var pos = Self.tabPositions(o.cut.tabs)
        let near = max(0.01, o.cut.tabs.length / total * 0.75)
        if let i = pos.firstIndex(where: { let d = abs($0 - f); return min(d, 1 - d) <= near }) {
            pos.remove(at: i)
            model.editObject(o.id, "Remove Tab") { $0.cut.tabs.positions = pos; $0.cut.tabs.count = pos.count; $0.cut.tabs.enabled = true }
        } else {
            pos.append(f)
            pos.sort()
            model.editObject(o.id, "Add Tab") { $0.cut.tabs.positions = pos; $0.cut.tabs.count = pos.count; $0.cut.tabs.enabled = true }
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let at = toStock(convert(sender.draggingLocation, from: nil))
        for (i, u) in urls.enumerated() { model.importArtwork(url: u, at: at + V2(Double(i) * 10, Double(-i) * 10)) }
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model else { return }
        if needsFit { zoomToFit() }
        let sheet = model.sheet
        let st = sheet.stock
        ctx.setFillColor(CanvasColor.obsidian.cgColor)
        ctx.fill(bounds)

        let stockRectV = CGRect(origin: toView(.zero), size: CGSize(width: CGFloat(st.width) * zoom, height: CGFloat(st.height) * zoom))
        // Sheet with a soft shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(CanvasColor.slate2.cgColor)
        ctx.fill(stockRectV)
        ctx.restoreGState()
        drawGrid(ctx, stockRectV)
        ctx.setStrokeColor(CanvasColor.steel.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(stockRectV.insetBy(dx: 0.5, dy: 0.5))

        // Objects, in stock space
        let visibleStock = Rect2D(min: toStock(bounds.origin), max: toStock(CGPoint(x: bounds.maxX, y: bounds.maxY)))
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        let px = 1 / zoom
        let objs = visibleObjects
        cache.prune(keeping: Set(sheet.objects.map(\.id)))
        for o in objs {
            let e = cache.entry(for: o)
            guard let b = e.bounds, b.canvasInset(model.doc.bits.main.diameter).intersects(visibleStock) else { continue }
            drawObject(ctx, o, e, px: px, thickness: st.thickness)
        }
        // Tabs on through profiles
        for o in tabCandidates() where o.cut.tabs.enabled && (model.tool == .placeTabs || model.selection.contains(o.id)) {
            drawTabs(ctx, o, px: px)
        }
        // Selection outlines
        ctx.setStrokeColor(CanvasColor.accentBright.cgColor)
        ctx.setLineWidth(1.5 * px)
        ctx.setLineDash(phase: 0, lengths: [])
        for o in objs where model.selection.contains(o.id) {
            addPath(ctx, o, cache.entry(for: o))
            ctx.strokePath()
        }
        ctx.restoreGState()

        drawSelectionChrome(ctx)
        drawBadges(ctx)
        drawOverlays(ctx)
        drawWorkZero(ctx, sheet)
        drawRulers(ctx)
    }

    private func addPath(_ ctx: CGContext, _ o: DesignObject, _ e: CanvasShapeCache.Entry) {
        ctx.saveGState()
        ctx.concatenate(o.transform.canvasAffine)
        ctx.addPath(e.path)
        ctx.restoreGState()
    }

    private func drawObject(_ ctx: CGContext, _ o: DesignObject, _ e: CanvasShapeCache.Entry, px: CGFloat, thickness: Double) {
        let depth = o.cut.effectiveDepth(thickness: thickness, overcut: model.doc.bits.overcut)
        let t = thickness > 0 ? depth / thickness : 0
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch o.cut.type {
        case .none:
            addPath(ctx, o, e)
            ctx.setStrokeColor(CanvasColor.steel.cgColor)
            ctx.setLineWidth(1 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.strokePath()
        case .engrave:
            addPath(ctx, o, e)
            ctx.setStrokeColor(CanvasColor.depth(t).cgColor)
            ctx.setLineWidth(max(px, CGFloat(model.doc.bits.main.diameter)))
            ctx.strokePath()
        case .pocket, .profile, .vcarve:
            if !o.geometry.isClosed {
                addPath(ctx, o, e)
                ctx.setStrokeColor(CanvasColor.depth(t).cgColor)
                ctx.setLineWidth(max(px, CGFloat(model.doc.bits.main.diameter)))
                ctx.strokePath()
            } else if o.cut.through {
                addPath(ctx, o, e)
                ctx.setFillColor(CanvasColor.throughFill.cgColor)
                ctx.fillPath(using: .winding)
                addPath(ctx, o, e)
                ctx.setStrokeColor(CanvasColor.accent.cgColor)
                ctx.setLineWidth(1.25 * px)
                ctx.setLineCap(.butt)
                ctx.setLineDash(phase: 0, lengths: [6 * px, 4 * px])
                ctx.strokePath()
            } else {
                addPath(ctx, o, e)
                ctx.setFillColor(CanvasColor.depth(t).cgColor)
                ctx.setStrokeColor(CanvasColor.depth(min(1, t + 0.35), alpha: 1).cgColor)
                ctx.setLineWidth(0.75 * px)
                ctx.drawPath(using: .fillStroke)
            }
        }
    }

    private func drawTabs(_ ctx: CGContext, _ o: DesignObject, px: CGFloat) {
        let polys = closedPolys(o)
        let total = polys.reduce(0) { $0 + $1.length }
        guard total > 0 else { return }
        let explicit = !o.cut.tabs.positions.isEmpty
        let halfLen = o.cut.tabs.length / 2
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.butt)
        for f in Self.tabPositions(o.cut.tabs) {
            guard let (p, tan) = CanvasGeom.point(along: f * total, on: polys) else { continue }
            let a = p - tan * halfLen, b = p + tan * halfLen
            ctx.move(to: a.cg)
            ctx.addLine(to: b.cg)
            ctx.setStrokeColor((explicit ? CanvasColor.warn : CanvasColor.warn.withAlphaComponent(0.55)).cgColor)
            ctx.setLineWidth(5 * px)
            ctx.strokePath()
        }
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        guard let model, !model.selection.isEmpty else { return }
        if model.tool == .select, let b = selectionBounds() {
            let r = CGRect(x: toView(b.min).x, y: toView(b.min).y, width: CGFloat(b.size.x) * zoom, height: CGFloat(b.size.y) * zoom)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.setStrokeColor(CanvasColor.accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
            ctx.setLineDash(phase: 0, lengths: [])
            guard selectionEditable else { return }
            let rh = rotateHandle(b)
            ctx.move(to: CGPoint(x: r.midX, y: r.maxY))
            ctx.addLine(to: rh)
            ctx.strokePath()
            ctx.setFillColor(CanvasColor.slate3.cgColor)
            ctx.setStrokeColor(CanvasColor.accent.cgColor)
            ctx.addEllipse(in: CGRect(x: rh.x - 5, y: rh.y - 5, width: 10, height: 10))
            ctx.drawPath(using: .fillStroke)
            for h in handlePoints(b) {
                let v = toView(h)
                let hr = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                ctx.setFillColor(CanvasColor.offwhite.cgColor)
                ctx.fill(hr)
                ctx.setStrokeColor(CanvasColor.accent.cgColor)
                ctx.stroke(hr)
            }
        } else if model.tool == .directSelect {
            for o0 in model.sheet.objects where model.selection.contains(o0.id) && pointEditable(o0) {
                let o = displayed(o0)
                let p = editablePath(o)
                let t = o.transform
                // Control handles
                ctx.setStrokeColor(CanvasColor.steel.cgColor)
                ctx.setLineWidth(1)
                for (i, sp) in p.subpaths.enumerated() {
                    var prev = sp.start
                    for (j, s) in sp.segments.enumerated() {
                        switch s {
                        case .quad(let c, let e):
                            ctx.move(to: toView(t.apply(prev))); ctx.addLine(to: toView(t.apply(c))); ctx.addLine(to: toView(t.apply(e)))
                        case .cubic(let a, let b, let e):
                            ctx.move(to: toView(t.apply(prev))); ctx.addLine(to: toView(t.apply(a)))
                            ctx.move(to: toView(t.apply(e))); ctx.addLine(to: toView(t.apply(b)))
                        case .line: break
                        }
                        _ = (i, j)
                        prev = s.end
                    }
                }
                ctx.strokePath()
                let refs = pointRefs(p)
                for r in refs.controls {
                    guard let v = pointValue(p, r) else { continue }
                    let q = toView(t.apply(v))
                    ctx.setFillColor(CanvasColor.steel.cgColor)
                    ctx.fillEllipse(in: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6))
                }
                for r in refs.anchors {
                    guard let v = pointValue(p, r) else { continue }
                    let q = toView(t.apply(v))
                    let hr = CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)
                    ctx.setFillColor(CanvasColor.offwhite.cgColor)
                    ctx.fill(hr)
                    ctx.setStrokeColor(CanvasColor.accent.cgColor)
                    ctx.stroke(hr)
                }
            }
        }
    }

    private func drawBadges(_ ctx: CGContext) {
        guard let model else { return }
        var done = Set<UUID>()
        let byID = Dictionary(model.sheet.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Errors first so they win when an object has both.
        for p in model.problems.sorted(by: { ($0.severity == .error ? 0 : 1) < ($1.severity == .error ? 0 : 1) }) {
            guard p.severity != .ok, let id = p.objectID, !done.contains(id), let o = byID[id], !o.hidden,
                  let b = bounds(of: displayed(o)) else { continue }
            done.insert(id)
            let v = toView(b.max)
            let err = p.severity == .error
            let name = err ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black, err ? CanvasColor.danger : CanvasColor.warn]))
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: p.message)?.withSymbolConfiguration(cfg) else { continue }
            let sz = img.size
            let r = CGRect(x: v.x - sz.width / 2 + 4, y: v.y - sz.height / 2 + 4, width: sz.width, height: sz.height)
            ctx.setFillColor(CanvasColor.obsidian.withAlphaComponent(0.8).cgColor)
            ctx.fillEllipse(in: r.insetBy(dx: -2, dy: -2))
            img.draw(in: r)
        }
    }

    private func drawOverlays(_ ctx: CGContext) {
        ctx.setLineDash(phase: 0, lengths: [])
        // Smart guides
        if !guides.isEmpty {
            ctx.setStrokeColor(CanvasColor.accentBright.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            for g in guides {
                switch g {
                case .x(let x): let v = toView(V2(x, 0)).x; ctx.move(to: CGPoint(x: v, y: 0)); ctx.addLine(to: CGPoint(x: v, y: bounds.maxY))
                case .y(let y): let v = toView(V2(0, y)).y; ctx.move(to: CGPoint(x: 0, y: v)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: v))
                }
            }
            ctx.strokePath()
        }
        // Marquee
        if case .marquee(let a, let b, _) = drag {
            let va = toView(a), vb = toView(b)
            let r = CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y), width: abs(va.x - vb.x), height: abs(va.y - vb.y))
            ctx.setFillColor(CanvasColor.accent.withAlphaComponent(0.10).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(CanvasColor.accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }
        // Measure
        if let (a, b) = measureLine {
            let va = toView(a), vb = toView(b)
            ctx.setStrokeColor(CanvasColor.warn.cgColor)
            ctx.setLineWidth(1.25)
            ctx.move(to: va); ctx.addLine(to: vb)
            ctx.strokePath()
            for v in [va, vb] { ctx.setFillColor(CanvasColor.warn.cgColor); ctx.fillEllipse(in: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)) }
            let d = b - a
            let len = simd_length(d)
            let label = (model.useInches ? String(format: "%.3f in", len / 25.4) : String(format: "%.2f mm", len)) + String(format: "  %.1f°", atan2(d.y, d.x) * 180 / .pi)
            drawLabel(label, at: CGPoint(x: (va.x + vb.x) / 2 + 8, y: (va.y + vb.y) / 2 + 8), color: CanvasColor.warn, boxed: true)
        }
        // Pen
        if !pen.isEmpty {
            let path = CGMutablePath()
            path.move(to: toView(pen[0].anchor))
            for i in 1..<max(1, pen.count) {
                let a = pen[i - 1], b = pen[i]
                if a.out == nil && b.inHandle == nil { path.addLine(to: toView(b.anchor)) }
                else { path.addCurve(to: toView(b.anchor), control1: toView(a.out ?? a.anchor), control2: toView(b.inHandle ?? b.anchor)) }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(CanvasColor.accentBright.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            if let h = hover, case .none = drag {
                let last = pen[pen.count - 1]
                ctx.move(to: toView(last.anchor))
                if let o = last.out { ctx.addQuadCurve(to: toView(h), control: toView(o)) } else { ctx.addLine(to: toView(h)) }
                ctx.setStrokeColor(CanvasColor.accent.withAlphaComponent(0.6).cgColor)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.setLineWidth(1)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
            for (i, p) in pen.enumerated() {
                let v = toView(p.anchor)
                if let o = p.out, let ih = p.inHandle {
                    ctx.setStrokeColor(CanvasColor.steel.cgColor)
                    ctx.setLineWidth(1)
                    ctx.move(to: toView(ih)); ctx.addLine(to: toView(o)); ctx.strokePath()
                    for c in [o, ih] { let q = toView(c); ctx.setFillColor(CanvasColor.steel.cgColor); ctx.fillEllipse(in: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)) }
                }
                let r = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                ctx.setFillColor((i == 0 && pen.count >= 2 ? CanvasColor.accent : CanvasColor.offwhite).cgColor)
                ctx.fill(r)
            }
        }
    }

    private func drawWorkZero(_ ctx: CGContext, _ sheet: Sheet) {
        let o3 = sheet.workZero.origin(for: sheet.stock)
        let v = toView(V2(o3.x, o3.y))
        let L: CGFloat = 22
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CanvasColor.axisX.cgColor)
        ctx.move(to: v); ctx.addLine(to: CGPoint(x: v.x + L, y: v.y)); ctx.strokePath()
        ctx.setStrokeColor(CanvasColor.axisY.cgColor)
        ctx.move(to: v); ctx.addLine(to: CGPoint(x: v.x, y: v.y + L)); ctx.strokePath()
        // Quartered target
        let r = CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)
        ctx.setFillColor(CanvasColor.offwhite.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setFillColor(CanvasColor.obsidian.cgColor)
        ctx.move(to: v); ctx.addArc(center: v, radius: 6, startAngle: 0, endAngle: .pi / 2, clockwise: false); ctx.closePath()
        ctx.move(to: v); ctx.addArc(center: v, radius: 6, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false); ctx.closePath()
        ctx.fillPath()
        ctx.setStrokeColor(CanvasColor.offwhite.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: r)
    }

    private func gridStep(_ base: Double, minPx: Double) -> Double {
        var s = base
        let mults = [2.0, 2.5, 2.0]
        var i = 0
        while s * Double(zoom) < minPx { s *= mults[i % 3]; i += 1 }
        return s
    }

    private func drawGrid(_ ctx: CGContext, _ r: CGRect) {
        let (major0, minor) = gridSteps
        let major = gridStep(major0, minPx: 10)
        let st = model.sheet.stock
        ctx.saveGState()
        ctx.clip(to: r)
        func lines(step: Double, color: NSColor) {
            let p = CGMutablePath()
            var x = 0.0
            while x <= st.width + 1e-6 { let v = toView(V2(x, 0)).x.rounded() + 0.5; p.move(to: CGPoint(x: v, y: r.minY)); p.addLine(to: CGPoint(x: v, y: r.maxY)); x += step }
            var y = 0.0
            while y <= st.height + 1e-6 { let v = toView(V2(0, y)).y.rounded() + 0.5; p.move(to: CGPoint(x: r.minX, y: v)); p.addLine(to: CGPoint(x: r.maxX, y: v)); y += step }
            ctx.addPath(p)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        if minor * Double(zoom) >= 6, major == major0 { lines(step: minor, color: CanvasColor.line) }
        lines(step: major, color: CanvasColor.hex(0x3c3c3c))
        ctx.restoreGState()
    }

    private func drawLabel(_ s: String, at p: CGPoint, color: NSColor, boxed: Bool = false, size: CGFloat = 11) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: color]
        let a = NSAttributedString(string: s, attributes: attrs)
        if boxed {
            let sz = a.size()
            let r = CGRect(x: p.x - 4, y: p.y - 2, width: sz.width + 8, height: sz.height + 4)
            NSColor(white: 0.07, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        }
        a.draw(at: p)
    }

    private func drawRulers(_ ctx: CGContext) {
        let R = Self.rulerSize
        let top = CGRect(x: 0, y: bounds.maxY - R, width: bounds.width, height: R)
        let left = CGRect(x: 0, y: 0, width: R, height: bounds.height - R)
        ctx.setFillColor(CanvasColor.slate.cgColor)
        ctx.fill(top); ctx.fill(left)
        ctx.setStrokeColor(CanvasColor.line.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: top.minY + 0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: top.minY + 0.5))
        ctx.move(to: CGPoint(x: R - 0.5, y: 0)); ctx.addLine(to: CGPoint(x: R - 0.5, y: top.minY))
        ctx.strokePath()

        let inches = model.useInches
        let unit = inches ? 25.4 : 1.0
        // Label spacing: a 1-2-5 series in the display unit, at least 56 pt apart.
        var label = 1.0
        let series = inches ? [0.125, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100] : [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000]
        label = series.first { $0 * unit * Double(zoom) >= 56 } ?? series.last!
        let tick = label / (inches ? 4 : 5)
        let lo = toStock(CGPoint(x: R, y: 0)), hi = toStock(CGPoint(x: bounds.maxX, y: bounds.maxY - R))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CanvasColor.steel]
        func text(_ v: Double) -> String {
            if inches { return v.rounded() == v ? String(Int(v)) : String(format: "%g", v) }
            return String(Int(v.rounded()))
        }
        let ticks = CGMutablePath()
        // Top (X)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: R, y: top.minY, width: bounds.width - R, height: R))
        var u = (lo.x / unit / tick).rounded(.down) * tick
        while u * unit <= hi.x {
            let x = toView(V2(u * unit, 0)).x.rounded() + 0.5
            let isLabel = abs((u / label).rounded() * label - u) < 1e-6
            ticks.move(to: CGPoint(x: x, y: top.minY)); ticks.addLine(to: CGPoint(x: x, y: top.minY + (isLabel ? R * 0.6 : R * 0.25)))
            if isLabel { NSAttributedString(string: text(u), attributes: attrs).draw(at: CGPoint(x: x + 3, y: top.minY + 8)) }
            u += tick
        }
        ctx.addPath(ticks)
        ctx.setStrokeColor(CanvasColor.steel.withAlphaComponent(0.7).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
        // Left (Y)
        let lt = CGMutablePath()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: R, height: top.minY))
        u = (lo.y / unit / tick).rounded(.down) * tick
        while u * unit <= hi.y {
            let y = toView(V2(0, u * unit)).y.rounded() + 0.5
            let isLabel = abs((u / label).rounded() * label - u) < 1e-6
            lt.move(to: CGPoint(x: R, y: y)); lt.addLine(to: CGPoint(x: R - (isLabel ? R * 0.6 : R * 0.25), y: y))
            if isLabel {
                ctx.saveGState()
                ctx.translateBy(x: 9, y: y + 3)
                ctx.rotate(by: .pi / 2)
                NSGraphicsContext.current.map { _ in NSAttributedString(string: text(u), attributes: attrs).draw(at: CGPoint(x: 0, y: -4)) }
                ctx.restoreGState()
            }
            u += tick
        }
        ctx.addPath(lt)
        ctx.setStrokeColor(CanvasColor.steel.withAlphaComponent(0.7).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
        // Cursor markers
        if let c = cursor?.stock {
            let v = toView(c)
            ctx.setStrokeColor(CanvasColor.accent.cgColor)
            ctx.move(to: CGPoint(x: v.x, y: top.minY)); ctx.addLine(to: CGPoint(x: v.x, y: bounds.maxY))
            ctx.move(to: CGPoint(x: 0, y: v.y)); ctx.addLine(to: CGPoint(x: R, y: v.y))
            ctx.strokePath()
        }
        // Corner with the unit
        ctx.setFillColor(CanvasColor.slate.cgColor)
        ctx.fill(CGRect(x: 0, y: top.minY, width: R, height: R))
        NSAttributedString(string: inches ? "in" : "mm", attributes: attrs).draw(at: CGPoint(x: 3, y: top.minY + 5))
    }
}
