// Commands on the document: adding objects, import, arrange, path operations, sheets and the sidebar's cut groups.

import AppKit
import CAMCore
import EngraveCore
import Foundation
import simd

enum ShapeKind: String, CaseIterable, Identifiable {
    case rectangle, roundedRectangle, ellipse, polygon, star, line
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .line: return "Line"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "app"
        case .ellipse: return "circle"
        case .polygon: return "hexagon"
        case .star: return "star"
        case .line: return "line.diagonal"
        }
    }
}

enum AlignEdge: String, CaseIterable, Identifiable {
    case left, centre, right, top, middle, bottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "Align Left Edges"
        case .centre: return "Align Centres"
        case .right: return "Align Right Edges"
        case .top: return "Align Top Edges"
        case .middle: return "Align Middles"
        case .bottom: return "Align Bottom Edges"
        }
    }
}

enum PathOperation: String, CaseIterable, Identifiable {
    case union, subtract, intersect, exclude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .union: return "Union"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .exclude: return "Exclude"
        }
    }
}

/// Objects in the sidebar's Design section that share a cut.
struct CutGroup: Identifiable {
    var id: String
    var title: String
    var cut: CutSettings
    var objects: [DesignObject]  // top of the drawing order first
}

/// Dragged sidebar rows carry this prefix and the object's id.
let objectDragPrefix = "swarfengrave.object:"

extension EditorModel {
    // MARK: Adding

    var stockCentre: V2 { V2(sheet.stock.width / 2, sheet.stock.height / 2) }

    /// Adds an object on the current sheet and selects it.
    func add(_ object: DesignObject) {
        editSheet("Add \(object.geometry.kindName)") { $0.objects.append(object) }
        selection = [object.id]
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(sheet.objects.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func addShape(_ kind: ShapeKind, at point: V2? = nil) {
        let s = sheet.stock
        let size = max(5, (min(s.width, s.height) * 0.4).rounded())
        let geometry: ObjectGeometry
        var cut = CutSettings(type: .pocket, depth: min(3, s.thickness))
        switch kind {
        case .rectangle: geometry = .rectangle(width: size * 1.5, height: size, cornerRadius: 0)
        case .roundedRectangle: geometry = .rectangle(width: size * 1.5, height: size, cornerRadius: (size * 0.15).rounded())
        case .ellipse: geometry = .ellipse(width: size, height: size)
        case .polygon: geometry = .polygon(sides: 6, radius: size / 2)
        case .star: geometry = .star(points: 5, outerRadius: size / 2, innerRadius: size / 4.6)
        case .line:
            geometry = .line(length: max(10, (s.width * 0.5).rounded()))
            cut = CutSettings(type: .engrave, depth: min(1, s.thickness))
        }
        add(DesignObject(name: uniqueName(kind.label), geometry: geometry, transform: Transform2D(position: point ?? stockCentre), cut: cut))
    }

    func addText(_ string: String = "Text", at point: V2? = nil) {
        let s = sheet.stock
        let size = max(3, min(20, (s.height * 0.2).rounded()))
        var spec = TextSpec(string: string, fontName: "Helvetica-Bold", size: size)
        spec.alignment = .center
        add(DesignObject(name: uniqueName("Text"), geometry: .text(spec), transform: Transform2D(position: point ?? stockCentre),
                         cut: CutSettings(type: .vcarve, depth: min(3, s.thickness))))
    }

    // MARK: Import

    static let vectorExtensions: Set<String> = ["svg", "dxf", "pdf", "eps", "ai"]
    static let bitmapExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// Artwork from a file: vectors become path objects (one per layer, grouped), bitmaps open the trace sheet.
    /// Placed centred on `point` (stock space), else on the stock centre, and scaled down to fit the stock.
    func importArtwork(url: URL, at point: V2?) {
        let ext = url.pathExtension.lowercased()
        if Self.bitmapExtensions.contains(ext) {
            traceDropPoint = point
            showTraceSheet = url
            return
        }
        do {
            let art = try ArtworkImporter.importVector(url: url)
            let layers = art.layers.filter { !$0.path.isEmpty }
            guard !layers.isEmpty else {
                errorMessage = "\(url.lastPathComponent) has no paths to import."
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            placeArtwork(layers.map { (layers.count == 1 ? name : $0.name, $0.path) }, at: point, actionName: "Import \(url.lastPathComponent)")
            if !art.warnings.isEmpty { errorMessage = "Imported \(url.lastPathComponent):\n" + art.warnings.joined(separator: "\n") }
        } catch {
            errorMessage = "\(url.lastPathComponent) could not be imported: \(error.localizedDescription)"
        }
    }

    /// Paths in stock-space millimetres (not centred) placed as path objects, keeping their layout.
    func placeArtwork(_ layers: [(name: String, path: Path2D)], at point: V2?, actionName: String) {
        let withBounds = layers.compactMap { l in l.path.tightBounds(tolerance: 0.05).map { (l.name, l.path, $0) } }
        guard var all = withBounds.first?.2 else { return }
        for l in withBounds { all = all.union(l.2) }
        let stock = sheet.stock
        let fit = min(1, stock.width * 0.9 / max(all.size.x, 1e-6), stock.height * 0.9 / max(all.size.y, 1e-6))
        let target = point ?? stockCentre
        let group: UUID? = withBounds.count > 1 ? UUID() : nil
        var objects: [DesignObject] = []
        for (name, path, b) in withBounds {
            let c = b.center
            let local = path.mapped { $0 - c }
            let closed = path.subpaths.contains { $0.closed }
            var o = DesignObject(name: uniqueName(name.isEmpty ? "Artwork" : name), geometry: .path(local),
                                 transform: Transform2D(position: target + (c - all.center) * fit, scale: V2(fit, fit)),
                                 cut: closed ? CutSettings(type: .pocket, depth: min(3, stock.thickness)) : CutSettings(type: .engrave, depth: min(1, stock.thickness)))
            o.groupID = group
            objects.append(o)
        }
        editSheet(actionName) { $0.objects += objects }
        selection = Set(objects.map(\.id))
    }

    // MARK: Selection commands

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        let n = ids.count
        editSheet(n == 1 ? "Delete" : "Delete \(n) Objects") { $0.objects.removeAll { ids.contains($0.id) } }
        selection = []
    }

    func duplicateSelection(offset: V2 = V2(5, -5)) {
        guard !selection.isEmpty else { return }
        var groupMap: [UUID: UUID] = [:]
        var copies: [DesignObject] = []
        for o in selectedObjects {
            var c = o
            c.id = UUID()
            c.name = uniqueName(o.name)
            c.transform.position += offset
            if let g = o.groupID {
                if groupMap[g] == nil { groupMap[g] = UUID() }
                c.groupID = groupMap[g]
            }
            copies.append(c)
        }
        editSheet("Duplicate") { $0.objects += copies }
        selection = Set(copies.map(\.id))
    }

    func nudge(by delta: V2) {
        guard !selection.isEmpty else { return }
        editSelection("Move", coalesce: "nudge") { o in if !o.locked { o.transform.position += delta } }
    }

    func selectAll() {
        selection = Set(sheet.objects.filter { !$0.hidden && !$0.locked }.map(\.id))
    }

    func toggleHidden(_ id: UUID) { editObject(id, "Hide") { $0.hidden.toggle() } }
    func toggleLocked(_ id: UUID) { editObject(id, "Lock") { $0.locked.toggle() } }
    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        editObject(id, "Rename") { $0.name = n }
    }

    // MARK: Bounds and resizing

    func bounds(of objects: [DesignObject]) -> Rect2D? {
        var r: Rect2D?
        for o in objects { if let b = o.bounds { r = r?.union(b) ?? b } }
        return r
    }

    var selectionBounds: Rect2D? { bounds(of: selectedObjects) }

    /// Moves the selection so its anchor point lands at `p`.
    func moveSelection(anchorTo p: V2, anchor a: Anchor) {
        guard let b = selectionBounds else { return }
        let cur = V2(b.min.x + b.size.x * a.fx, b.min.y + b.size.y * a.fy)
        let d = p - cur
        guard simd_length(d) > 1e-9 else { return }
        editSelection("Move") { $0.transform.position += d }
    }

    /// Resizes the selection's bounds about the anchor point. Shapes change their own dimensions; paths and text
    /// change their scale.
    func resizeSelection(width: Double?, height: Double?, anchor a: Anchor, keepAspect: Bool) {
        guard let b = selectionBounds else { return }
        var sx = width.map { $0 / max(b.size.x, 1e-9) } ?? 1
        var sy = height.map { $0 / max(b.size.y, 1e-9) } ?? 1
        if keepAspect {
            if width != nil { sy = sx } else { sx = sy }
        }
        // Lines have no height: only their length scales.
        if b.size.x < 1e-6 { sx = 1 }
        if b.size.y < 1e-6 { sy = 1 }
        guard sx > 0, sy > 0, sx.isFinite, sy.isFinite, abs(sx - 1) > 1e-9 || abs(sy - 1) > 1e-9 else { return }
        let pivot = V2(b.min.x + b.size.x * a.fx, b.min.y + b.size.y * a.fy)
        editSelection("Resize", coalesce: "resize") { o in
            Self.scale(&o, sx: sx, sy: sy)
            o.transform.position = pivot + (o.transform.position - pivot) * V2(sx, sy)
        }
    }

    /// Scales one object about its own origin by stock-axis factors.
    static func scale(_ o: inout DesignObject, sx: Double, sy: Double) {
        let r = o.transform.rotation.truncatingRemainder(dividingBy: 180)
        let swapped = abs(abs(r) - 90) < 45
        let lx = swapped ? sy : sx, ly = swapped ? sx : sy
        let uniform = abs(lx - ly) < 1e-9
        switch o.geometry {
        case .rectangle(let w, let h, let cr):
            o.geometry = .rectangle(width: w * lx, height: h * ly, cornerRadius: cr * min(lx, ly))
        case .ellipse(let w, let h):
            o.geometry = .ellipse(width: w * lx, height: h * ly)
        case .line(let l):
            let rad = o.transform.rotation * .pi / 180
            let f = simd_length(V2(cos(rad) * sx, sin(rad) * sy))
            o.geometry = .line(length: l * f)
        case .polygon(let n, let rad) where uniform:
            o.geometry = .polygon(sides: n, radius: rad * lx)
        case .star(let n, let ro, let ri) where uniform:
            o.geometry = .star(points: n, outerRadius: ro * lx, innerRadius: ri * lx)
        default:
            o.transform.scale *= V2(lx, ly)
        }
    }

    // MARK: Arrange

    func align(_ edge: AlignEdge) {
        let objs = selectedObjects
        guard !objs.isEmpty else { return }
        // One object aligns to the stock; several align to each other.
        let ref: Rect2D = objs.count == 1 ? sheet.stockRect : (bounds(of: objs) ?? sheet.stockRect)
        var moves: [UUID: V2] = [:]
        for o in objs {
            guard let b = o.bounds else { continue }
            var d = V2.zero
            switch edge {
            case .left: d.x = ref.min.x - b.min.x
            case .centre: d.x = ref.center.x - b.center.x
            case .right: d.x = ref.max.x - b.max.x
            case .top: d.y = ref.max.y - b.max.y
            case .middle: d.y = ref.center.y - b.center.y
            case .bottom: d.y = ref.min.y - b.min.y
            }
            moves[o.id] = d
        }
        editSheet(edge.label) { s in
            for i in s.objects.indices { if let d = moves[s.objects[i].id] { s.objects[i].transform.position += d } }
        }
    }

    /// Spaces the selection evenly between its outermost objects.
    func distribute(horizontally: Bool) {
        let items = selectedObjects.compactMap { o in o.bounds.map { (o.id, $0) } }
        guard items.count > 2 else { return }
        let axis = horizontally ? 0 : 1
        let sorted = items.sorted { $0.1.center[axis] < $1.1.center[axis] }
        let first = sorted.first!.1.center[axis], last = sorted.last!.1.center[axis]
        let step = (last - first) / Double(sorted.count - 1)
        var moves: [UUID: Double] = [:]
        for (i, it) in sorted.enumerated() { moves[it.0] = first + step * Double(i) - it.1.center[axis] }
        editSheet("Distribute") { s in
            for i in s.objects.indices { if let d = moves[s.objects[i].id] { s.objects[i].transform.position[axis] += d } }
        }
    }

    func groupSelection() {
        guard selection.count > 1 else { return }
        let g = UUID()
        editSelection("Group") { $0.groupID = g }
    }

    func ungroupSelection() { editSelection("Ungroup") { $0.groupID = nil } }

    enum Reorder { case forward, backward, front, back }

    func reorder(_ r: Reorder) {
        let ids = selection
        guard !ids.isEmpty else { return }
        editSheet("Arrange") { s in
            var objs = s.objects
            switch r {
            case .front: objs = objs.filter { !ids.contains($0.id) } + objs.filter { ids.contains($0.id) }
            case .back: objs = objs.filter { ids.contains($0.id) } + objs.filter { !ids.contains($0.id) }
            case .forward:
                var i = objs.count - 2
                while i >= 0 {
                    if ids.contains(objs[i].id) && !ids.contains(objs[i + 1].id) { objs.swapAt(i, i + 1) }
                    i -= 1
                }
            case .backward:
                for i in 1..<max(1, objs.count) where ids.contains(objs[i].id) && !ids.contains(objs[i - 1].id) { objs.swapAt(i, i - 1) }
            }
            s.objects = objs
        }
    }

    /// Mirrors each selected object in place.
    func mirror(horizontal: Bool) {
        editSelection(horizontal ? "Flip Horizontal" : "Flip Vertical") { o in
            o.transform.mirrored.toggle()
            if horizontal {
                o.transform.rotation = -o.transform.rotation
            } else {
                o.transform.rotation = 180 - o.transform.rotation
            }
            o.transform.rotation = Self.normalizedAngle(o.transform.rotation)
        }
    }

    static func normalizedAngle(_ a: Double) -> Double {
        var r = a.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return abs(r) < 1e-9 ? 0 : r
    }

    // MARK: Path operations

    var canCombinePaths: Bool { selectedObjects.filter { $0.geometry.isClosed }.count >= 2 }

    /// Replaces the selection with one path object made by a boolean operation (in drawing order: the bottom object
    /// is the one others subtract from).
    func combine(_ op: PathOperation) {
        let objs = selectedObjects.filter { $0.geometry.isClosed }
        guard objs.count >= 2 else { return }
        let outlines = objs.map { $0.outline() }
        let result: Path2D
        switch op {
        case .union: result = PathOps.union(outlines)
        case .subtract: result = outlines.dropFirst().reduce(outlines[0]) { PathOps.subtract($0, $1) }
        case .intersect: result = outlines.dropFirst().reduce(outlines[0]) { PathOps.intersect($0, $1) }
        case .exclude: result = outlines.dropFirst().reduce(outlines[0]) { PathOps.exclude($0, $1) }
        }
        replaceSelection(with: result, template: objs[0], name: op.label, ids: Set(objs.map(\.id)))
    }

    func offsetSelection(by distance: Double) {
        let objs = selectedObjects
        guard !objs.isEmpty else { return }
        let result = PathOps.offset(PathOps.union(objs.map { $0.outline() }), by: distance)
        replaceSelection(with: result, template: objs[0], name: "Offset", ids: selection)
    }

    func simplifySelection(tolerance: Double = 0.1) {
        let objs = selectedObjects
        guard !objs.isEmpty else { return }
        editSheet("Simplify") { s in
            for i in s.objects.indices where self.selection.contains(s.objects[i].id) {
                let o = s.objects[i]
                guard let (local, pos) = Self.centred(PathOps.simplify(o.outline(), tolerance: tolerance)) else { continue }
                s.objects[i].geometry = .path(local)
                s.objects[i].transform = Transform2D(position: pos)
            }
        }
    }

    /// A stock-space path centred on its bounds: local path and position.
    static func centred(_ p: Path2D) -> (Path2D, V2)? {
        guard !p.isEmpty, let b = p.tightBounds(tolerance: 0.05) else { return nil }
        let c = b.center
        return (p.mapped { $0 - c }, c)
    }

    private func replaceSelection(with result: Path2D, template: DesignObject, name: String, ids: Set<UUID>) {
        guard let (local, pos) = Self.centred(result) else {
            errorMessage = "\(name) left nothing: the shapes don't overlap that way."
            return
        }
        var o = DesignObject(name: uniqueName(name), geometry: .path(local), transform: Transform2D(position: pos), cut: template.cut)
        o.groupID = nil
        editSheet(name) { s in
            let at = s.objects.firstIndex { ids.contains($0.id) } ?? s.objects.count
            s.objects.removeAll { ids.contains($0.id) }
            s.objects.insert(o, at: min(at, s.objects.count))
        }
        selection = [o.id]
    }

    // MARK: Sheets

    func addSheet() {
        var s = Sheet(name: "Sheet \(doc.sheets.count + 1)", stock: sheet.stock, workZero: sheet.workZero)
        s.id = UUID()
        edit("Add Sheet") { $0.sheets.append(s) }
        currentSheetID = s.id
    }

    func duplicateSheet(_ id: UUID) {
        guard let src = doc.sheets.first(where: { $0.id == id }) else { return }
        var s = src
        s.id = UUID()
        s.name = src.name + " copy"
        s.objects = src.objects.map { var o = $0; o.id = UUID(); return o }
        let i = (doc.sheets.firstIndex { $0.id == id } ?? doc.sheets.count - 1) + 1
        edit("Duplicate Sheet") { $0.sheets.insert(s, at: i) }
        currentSheetID = s.id
    }

    func deleteSheet(_ id: UUID) {
        guard doc.sheets.count > 1, let i = doc.sheets.firstIndex(where: { $0.id == id }) else { return }
        if id == currentSheetID { currentSheetID = doc.sheets[i == 0 ? 1 : i - 1].id }
        edit("Delete Sheet") { $0.sheets.remove(at: i) }
    }

    func renameSheet(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = doc.sheets.firstIndex(where: { $0.id == id }) else { return }
        edit("Rename Sheet") { $0.sheets[i].name = n }
    }

    // MARK: Cut groups (sidebar)

    static func groupKey(_ c: CutSettings) -> String {
        switch c.type {
        case .none: return "none"
        case .vcarve: return "vcarve|\(c.vcarveMaxDepth.map { String(format: "%.2f", $0) } ?? "full")"
        default: return c.through ? "\(c.type.rawValue)|through" : "\(c.type.rawValue)|\(String(format: "%.2f", c.depth))"
        }
    }

    func groupTitle(_ c: CutSettings) -> String {
        switch c.type {
        case .none: return "Guides"
        case .vcarve: return c.vcarveMaxDepth.map { "V-carve · ≤ \(formatLength($0))" } ?? "V-carve"
        default:
            if c.through { return c.type == .profile ? "Through" : "\(c.type.label) · Through" }
            return "\(c.type.label) · \(formatLength(c.depth))"
        }
    }

    func formatLength(_ mm: Double, digits: Int = 2) -> String { UnitFormat.length(mm, inches: useInches, digits: digits) }

    var cutGroups: [CutGroup] {
        var groups: [String: CutGroup] = [:]
        var order: [String] = []
        for o in sheet.objects.reversed() {
            let k = Self.groupKey(o.cut)
            if groups[k] == nil {
                groups[k] = CutGroup(id: k, title: groupTitle(o.cut), cut: o.cut, objects: [])
                order.append(k)
            }
            groups[k]!.objects.append(o)
        }
        let t = sheet.stock.thickness
        func rank(_ c: CutSettings) -> (Int, Double) {
            switch c.type {
            case .none: return (3, 0)
            case .vcarve: return (1, c.vcarveMaxDepth ?? 0)
            default: return c.through ? (2, t) : (0, c.depth)
            }
        }
        return order.compactMap { groups[$0] }.sorted { a, b in
            let ra = rank(a.cut), rb = rank(b.cut)
            return ra.0 != rb.0 ? ra.0 < rb.0 : ra.1 < rb.1
        }
    }

    /// Sidebar drop: the dragged objects take the target group's cut and, when dropped on a row, move just above it
    /// in the drawing order.
    func dropObjects(_ ids: [UUID], onto targetID: UUID?, groupCut: CutSettings) {
        var moving = Set(ids)
        if ids.contains(where: { selection.contains($0) }) { moving.formUnion(selection) }
        moving.remove(targetID ?? UUID())
        guard !moving.isEmpty else { return }
        editSheet("Move to Group") { s in
            for i in s.objects.indices where moving.contains(s.objects[i].id) {
                var c = s.objects[i].cut
                c.type = groupCut.type
                c.depth = groupCut.depth
                c.through = groupCut.through
                c.vcarveMaxDepth = groupCut.vcarveMaxDepth
                if groupCut.type == .profile { c.profileSide = groupCut.profileSide }
                s.objects[i].cut = c
            }
            guard let targetID else { return }
            let moved = s.objects.filter { moving.contains($0.id) }
            var rest = s.objects.filter { !moving.contains($0.id) }
            if let t = rest.firstIndex(where: { $0.id == targetID }) {
                rest.insert(contentsOf: moved, at: t + 1)
                s.objects = rest
            }
        }
    }
}

// MARK: Units

enum UnitFormat {
    static func length(_ mm: Double, inches: Bool, digits: Int = 2) -> String {
        if inches { return trimmed(mm / 25.4, digits: max(digits, 3)) + " in" }
        return trimmed(mm, digits: digits) + " mm"
    }

    static func trimmed(_ v: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        f.minimumIntegerDigits = 1
        f.usesGroupingSeparator = false
        f.decimalSeparator = "."
        return f.string(from: NSNumber(value: abs(v) < 1e-12 ? 0 : v)) ?? "\(v)"
    }
}
