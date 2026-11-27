// The inspector column: the selected objects' Geometry, Text and Cut, or the Setup item picked in the sidebar.

import AppKit
import CAMCore
import EngraveCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let s = model.setupSelection {
                    switch s {
                    case .stock: StockInspector(model: model)
                    case .workZero: WorkZeroInspector(model: model)
                    case .machine: MachineInspector(model: model)
                    }
                } else if !model.selectedObjects.isEmpty {
                    ObjectInspector(model: model)
                } else {
                    NothingSelected(model: model)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.slate)
        .environment(\.useInches, model.useInches)
    }
}

private struct NothingSelected: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(model.sheet.name) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select an object on the canvas or in the sidebar to set its size, text and cut.")
                        .font(.system(size: 12)).foregroundStyle(Color.steel)
                        .fixedSize(horizontal: false, vertical: true)
                    let s = model.sheet.stock
                    FieldRow("Stock") {
                        Text("\(model.formatLength(s.width)) × \(model.formatLength(s.height)) × \(model.formatLength(s.thickness))")
                            .font(.mono).foregroundStyle(Color.offwhite)
                    }
                    FieldRow("Objects") { Text("\(model.sheet.objects.count)").font(.mono).foregroundStyle(Color.offwhite) }
                    if let t = model.estimatedSeconds {
                        FieldRow("Time") { Text("~" + formatDuration(t)).font(.mono).foregroundStyle(Color.offwhite) }
                    }
                    HStack {
                        Button("Edit Stock") { model.setupSelection = .stock }.swarfButton(.outlineAccent, .small)
                        Button("Machine & Bits") { model.setupSelection = .machine }.swarfButton(.normal, .small)
                    }
                }
            }
        }
    }
}

/// Font lookups for the Text section.
typealias Fonts = FontCatalog

// MARK: Selection bindings

extension DesignObject {
    var textSpec: TextSpec? {
        get { if case .text(let t) = geometry { return t } else { return nil } }
        set { if let newValue, case .text = geometry { geometry = .text(newValue) } }
    }
}

extension EditorModel {
    /// A value of the first selected object; setting it changes every selected object (one undo step).
    func binding<T: Equatable>(_ kp: WritableKeyPath<DesignObject, T>, _ name: String, default d: T, coalesce: String? = nil) -> Binding<T> {
        Binding(get: { [weak self] in self?.selectedObjects.first?[keyPath: kp] ?? d },
                set: { [weak self] v in self?.editSelection(name, coalesce: coalesce) { $0[keyPath: kp] = v } })
    }

    func isMixed<T: Equatable>(_ kp: KeyPath<DesignObject, T>) -> Bool {
        let objs = selectedObjects
        guard let f = objs.first?[keyPath: kp] else { return false }
        return objs.contains { $0[keyPath: kp] != f }
    }

    var selectedTexts: [DesignObject] { selectedObjects.filter { $0.textSpec != nil } }

    /// A text setting of the first selected text object; setting it changes every selected text object.
    func textBinding<T: Equatable>(_ kp: WritableKeyPath<TextSpec, T>, _ name: String, default d: T, coalesce: String? = nil) -> Binding<T> {
        Binding(get: { [weak self] in self?.selectedTexts.first?.textSpec?[keyPath: kp] ?? d },
                set: { [weak self] v in
                    self?.editSelection(name, coalesce: coalesce) { o in
                        if var t = o.textSpec { t[keyPath: kp] = v; o.textSpec = t }
                    }
                })
    }

    func cutBinding<T: Equatable>(_ kp: WritableKeyPath<CutSettings, T>, _ name: String = "Change Cut", default d: T, coalesce: String? = nil) -> Binding<T> {
        binding((\DesignObject.cut).appending(path: kp), name, default: d, coalesce: coalesce)
    }
}

// MARK: Object inspector

struct ObjectInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometrySection(model: model)
            if !model.selectedTexts.isEmpty { TextSection(model: model) }
            CutSection(model: model)
        }
    }
}

// MARK: Geometry

private struct GeometrySection: View {
    @ObservedObject var model: EditorModel

    var objs: [DesignObject] { model.selectedObjects }
    var bounds: Rect2D { model.selectionBounds ?? Rect2D(min: .zero, max: .zero) }

    func anchorPoint(_ b: Rect2D) -> V2 { V2(b.min.x + b.size.x * model.anchor.fx, b.min.y + b.size.y * model.anchor.fy) }

    var body: some View {
        InspectorSection(objs.count == 1 ? "Geometry" : "Geometry · \(objs.count) objects") {
            VStack(alignment: .leading, spacing: 10) {
                if objs.count == 1, let o = objs.first {
                    FieldRow("Name") {
                        NameField(name: o.name) { model.rename(o.id, to: $0) }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    AnchorPicker(anchor: $model.anchor)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            NumberField(title: "X", value: Binding(get: { anchorPoint(bounds).x }, set: { model.moveSelection(anchorTo: V2($0, anchorPoint(bounds).y), anchor: model.anchor) }), width: 64)
                            NumberField(title: "Y", value: Binding(get: { anchorPoint(bounds).y }, set: { model.moveSelection(anchorTo: V2(anchorPoint(bounds).x, $0), anchor: model.anchor) }), width: 64)
                        }
                        HStack(spacing: 10) {
                            NumberField(title: "W", value: Binding(get: { bounds.size.x }, set: { model.resizeSelection(width: $0, height: nil, anchor: model.anchor, keepAspect: model.lockAspect) }), range: 0.01...100000, width: 64)
                            NumberField(title: "H", value: Binding(get: { bounds.size.y }, set: { model.resizeSelection(width: nil, height: $0, anchor: model.anchor, keepAspect: model.lockAspect) }), range: 0.01...100000, width: 64)
                        }
                        Toggle(isOn: $model.lockAspect) {
                            Label("Lock aspect", systemImage: model.lockAspect ? "lock.fill" : "lock.open")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Keep width and height in proportion")
                    }
                }
                FieldRow("Rotation") {
                    NumberField(value: model.binding(\.transform.rotation, "Rotate", default: 0), kind: .angle, step: 15, width: 60,
                                mixed: model.isMixed(\.transform.rotation))
                    Button { rotate(-90) } label: { Image(systemName: "rotate.left") }.swarfButton(.ghost, .small).help("Rotate 90° anticlockwise")
                    Button { rotate(90) } label: { Image(systemName: "rotate.right") }.swarfButton(.ghost, .small).help("Rotate 90° clockwise")
                }
                FieldRow("Mirror") {
                    Button { model.mirror(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .swarfButton(.normal, .small, active: objs.first?.transform.mirrored == true && model.isMixed(\.transform.mirrored) == false)
                        .help("Flip horizontally")
                    Button { model.mirror(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                        .swarfButton(.normal, .small)
                        .help("Flip vertically")
                }
                shapeRows
                FieldRow("Lock") {
                    Toggle("Locked on the canvas", isOn: model.binding(\.locked, "Lock", default: false))
                        .toggleStyle(.checkbox)
                    Toggle("Hidden", isOn: model.binding(\.hidden, "Hide", default: false))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    func rotate(_ d: Double) {
        model.editSelection("Rotate") { $0.transform.rotation = EditorModel.normalizedAngle($0.transform.rotation - d) }
    }

    /// The selected shape's own parameters (single selection).
    @ViewBuilder var shapeRows: some View {
        if objs.count == 1, let o = objs.first {
            switch o.geometry {
            case .rectangle(let w, let h, let r):
                FieldRow("Corners") {
                    NumberField(value: Binding(get: { r }, set: { v in model.editObject(o.id, "Corner Radius", coalesce: "corner") { $0.geometry = .rectangle(width: w, height: h, cornerRadius: max(0, min(v, min(w, h) / 2))) } }),
                                range: 0...10000, step: 1)
                }
            case .polygon(let n, let rad):
                FieldRow("Sides") {
                    NumberField(value: Binding(get: { Double(n) }, set: { v in model.editObject(o.id, "Sides") { $0.geometry = .polygon(sides: Int(v), radius: rad) } }),
                                kind: .count, range: 3...64, step: 1, width: 50)
                }
            case .star(let n, let ro, let ri):
                FieldRow("Points") {
                    NumberField(value: Binding(get: { Double(n) }, set: { v in model.editObject(o.id, "Points") { $0.geometry = .star(points: Int(v), outerRadius: ro, innerRadius: ri) } }),
                                kind: .count, range: 3...64, step: 1, width: 50)
                }
                FieldRow("Inner") {
                    NumberField(value: Binding(get: { ri / max(ro, 1e-9) * 100 }, set: { v in model.editObject(o.id, "Star Depth", coalesce: "star") { $0.geometry = .star(points: n, outerRadius: ro, innerRadius: ro * min(max(v, 1), 99) / 100) } }),
                                kind: .percent, range: 1...99, step: 5, width: 50)
                }
            case .line(let l):
                FieldRow("Length") {
                    NumberField(value: Binding(get: { l }, set: { v in model.editObject(o.id, "Length") { $0.geometry = .line(length: max(0.01, v)) } }), range: 0.01...100000)
                }
            case .path(let p):
                FieldRow("Path") {
                    Text("\(p.subpaths.count) subpath\(p.subpaths.count == 1 ? "" : "s") · \(p.subpaths.contains { $0.closed } ? "closed" : "open")")
                        .font(.system(size: 11.5)).foregroundStyle(Color.steel)
                }
            default: EmptyView()
            }
        }
    }
}

/// Commits a name on Return or when focus leaves.
struct NameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Name", text: $text)
            .swarfField()
            .focused($focused)
            .onSubmit { commit(text) }
            .onAppear { text = name }
            .onChange(of: name) { _, n in if !focused { text = n } }
            .onChange(of: focused) { _, f in if !f, text != name { commit(text) } }
    }
}

/// The 9-point reference grid for X/Y and resizing.
struct AnchorPicker: View {
    @Binding var anchor: Anchor
    var body: some View {
        let cell: CGFloat = 14
        ZStack {
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.lineStrong).frame(width: cell * 3 + 4, height: cell * 3 + 4)
            VStack(spacing: 0) {
                ForEach(0..<3) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<3) { c in
                            let a = Anchor.all[r * 3 + c]
                            Button { anchor = a } label: {
                                Circle()
                                    .fill(a == anchor ? Color.accent : Color.steelDim)
                                    .frame(width: a == anchor ? 7 : 4, height: a == anchor ? 7 : 4)
                                    .frame(width: cell, height: cell)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .help("Point that X and Y refer to, and that stays put when resizing")
    }
}

// MARK: Text

private struct TextSection: View {
    @ObservedObject var model: EditorModel

    var spec: TextSpec { model.selectedTexts.first?.textSpec ?? TextSpec(string: "") }

    var body: some View {
        InspectorSection("Text") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: model.textBinding(\.string, "Edit Text", default: "", coalesce: "text-string"))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 54, maxHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.obsidian))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.lineStrong))
                fontRows
                FieldRow("Size") {
                    NumberField(value: model.textBinding(\.size, "Text Size", default: 20), range: 0.1...10000, step: 1, width: 60)
                    Picker("", selection: model.textBinding(\.sizeMode, "Text Size", default: .capHeight)) {
                        Text("Cap height").tag(TextSpec.SizeMode.capHeight)
                        Text("Em").tag(TextSpec.SizeMode.em)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 120)
                    .help("Size measured as the height of capital letters, or as the font's em square")
                }
                FieldRow("Tracking") {
                    NumberField(value: model.textBinding(\.tracking, "Tracking", default: 0), range: -1000...1000, step: 0.5, width: 60)
                }
                FieldRow("Line spacing") {
                    NumberField(value: model.textBinding(\.lineSpacing, "Line Spacing", default: 1.2), kind: .plain, range: 0.3...10, step: 0.1, width: 60)
                    Text("× size").font(.system(size: 10)).foregroundStyle(Color.steelDim)
                }
                FieldRow("Alignment") {
                    Picker("", selection: model.textBinding(\.alignment, "Alignment", default: .center)) {
                        Image(systemName: "text.alignleft").tag(TextSpec.Alignment.left).help("Left")
                        Image(systemName: "text.aligncenter").tag(TextSpec.Alignment.center).help("Centre")
                        Image(systemName: "text.alignright").tag(TextSpec.Alignment.right).help("Right")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 120)
                }
                layoutRows
                axesRows
                if !Fonts.isInstalled(spec.fontName) {
                    WarningRow(text: "\(spec.fontName) isn't installed on this Mac. The last outlines are kept so the carve doesn't change; pick another font to edit the text.")
                }
            }
        }
    }

    // MARK: Fonts

    var family: String? { Fonts.family(of: spec.fontName) }

    @ViewBuilder var fontRows: some View {
        FieldRow("Font") {
            Menu {
                ForEach(Fonts.families(), id: \.self) { f in
                    Button(f) { setFamily(f) }
                }
            } label: {
                Text(family ?? spec.fontName).lineLimit(1)
            }
            .frame(maxWidth: 170)
            Button("Show Fonts") { showFontPanel() }.swarfButton(.normal, .small)
                .help("Pick a font in the macOS font panel")
        }
        if let family {
            FieldRow("Face") {
                Menu {
                    ForEach(Fonts.faces(family: family), id: \.postScriptName) { face in
                        Button(face.styleName.isEmpty ? face.displayName : face.styleName) { setFont(face.postScriptName) }
                    }
                } label: {
                    Text(Fonts.faces(family: family).first { $0.postScriptName == spec.fontName }?.styleName ?? spec.fontName).lineLimit(1)
                }
                .frame(maxWidth: 170)
            }
        }
    }

    func setFamily(_ f: String) {
        let faces = Fonts.faces(family: f)
        let currentStyle = family.flatMap { fam in Fonts.faces(family: fam).first { $0.postScriptName == spec.fontName }?.styleName }
        let pick = faces.first { $0.styleName == currentStyle } ?? faces.first { ["Regular", "Roman", "Medium", "Book"].contains($0.styleName) } ?? faces.first
        if let pick { setFont(pick.postScriptName) }
    }

    func setFont(_ ps: String, variations: [String: Double] = [:]) {
        model.editSelection("Font") { o in
            if var t = o.textSpec {
                t.fontName = ps
                t.variations = variations
                o.textSpec = t
            }
        }
    }

    func showFontPanel() {
        let font = NSFont(name: spec.fontName, size: 24) ?? .systemFont(ofSize: 24)
        FontPanelBridge.shared.show(font) { f in
            setFont(f.fontName, variations: FontPanelBridge.variations(of: f))
        }
    }

    // MARK: Layout

    enum LayoutKind: String, CaseIterable { case straight, arc, path }

    var layoutKind: LayoutKind {
        switch spec.layout {
        case .straight: return .straight
        case .arc: return .arc
        case .onPath: return .path
        }
    }

    @ViewBuilder var layoutRows: some View {
        FieldRow("Layout") {
            Picker("", selection: Binding(get: { layoutKind }, set: { k in
                switch k {
                case .straight: setLayout(.straight)
                case .arc: setLayout(.arc(radius: max(10, (model.selectionBounds?.size.x ?? 60) / 2), top: true))
                case .path:
                    if let first = pathCandidates.first { fitToPath(first) }
                }
            })) {
                Text("Straight").tag(LayoutKind.straight)
                Text("Arc").tag(LayoutKind.arc)
                Text("On path").tag(LayoutKind.path)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 180)
        }
        if case .arc(let r, let top) = spec.layout {
            FieldRow("Radius") {
                NumberField(value: Binding(get: { r }, set: { setLayout(.arc(radius: max(0.5, $0), top: top), coalesce: "arc") }), range: 0.5...100000, step: 1, width: 60)
                Picker("", selection: Binding(get: { top }, set: { setLayout(.arc(radius: r, top: $0)) })) {
                    Text("Top").tag(true)
                    Text("Bottom").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 110)
            }
        }
        if layoutKind == .path || !pathCandidates.isEmpty {
            FieldRow("Path") {
                Menu {
                    ForEach(pathCandidates) { o in Button(o.name) { fitToPath(o) } }
                } label: { Text(layoutKind == .path ? "On a path" : "Fit to a path…").lineLimit(1) }
                    .frame(maxWidth: 170)
                    .disabled(pathCandidates.isEmpty)
                    .help("Run the text along another object's outline")
            }
        }
    }

    var pathCandidates: [DesignObject] {
        model.sheet.objects.filter { $0.textSpec == nil && !model.selection.contains($0.id) }
    }

    func setLayout(_ l: TextSpec.Layout, coalesce: String? = nil) {
        model.editSelection("Text Layout", coalesce: coalesce) { o in
            if var t = o.textSpec { t.layout = l; o.textSpec = t }
        }
    }

    /// The other object's outline, in each text object's own coordinates.
    func fitToPath(_ guide: DesignObject) {
        let outline = guide.outline()
        model.editSelection("Text on Path") { o in
            guard var t = o.textSpec else { return }
            let tr = o.transform
            t.layout = .onPath(outline.mapped { tr.invert($0) })
            o.textSpec = t
        }
    }

    // MARK: Variable axes

    @ViewBuilder var axesRows: some View {
        let axes = Fonts.axes(postScriptName: spec.fontName)
        if !axes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Variable axes").font(.system(size: 11)).foregroundStyle(Color.steel)
                    Spacer()
                    Button("Reset") {
                        model.editSelection("Font Axes") { o in if var t = o.textSpec { t.variations = [:]; o.textSpec = t } }
                    }
                    .swarfButton(.ghost, .small)
                    .disabled(spec.variations.isEmpty)
                }
                ForEach(axes, id: \.tag) { a in
                    let value = Binding<Double>(get: { spec.variations[a.tag] ?? a.default }, set: { v in
                        model.editSelection("Font Axes", coalesce: "axis-\(a.tag)") { o in
                            if var t = o.textSpec { t.variations[a.tag] = v; o.textSpec = t }
                        }
                    })
                    HStack(spacing: 8) {
                        Text(a.name).font(.system(size: 11.5)).foregroundStyle(Color.offwhite).frame(width: 70, alignment: .leading).lineLimit(1)
                        Slider(value: value, in: a.min...max(a.max, a.min + 0.001))
                        Text(UnitFormat.trimmed(value.wrappedValue, digits: 0)).font(.mono).foregroundStyle(Color.steel).frame(width: 40, alignment: .trailing)
                    }
                    .help("\(a.name) (\(a.tag)): \(UnitFormat.trimmed(a.min, digits: 1))–\(UnitFormat.trimmed(a.max, digits: 1))")
                }
            }
        }
    }
}

/// Bridges the shared NSFontPanel to the inspector: the font manager sends `changeFont:` here.
@MainActor
final class FontPanelBridge: NSObject {
    static let shared = FontPanelBridge()
    private var current: NSFont = .systemFont(ofSize: 24)
    private var onChange: ((NSFont) -> Void)?

    func show(_ font: NSFont, onChange: @escaping (NSFont) -> Void) {
        current = font
        self.onChange = onChange
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(changeFont(_:))
        fm.setSelectedFont(font, isMultiple: false)
        fm.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager else { return }
        let f = fm.convert(current)
        current = f
        onChange?(f)
    }

    @objc func validModesForFontPanel(_ panel: NSFontPanel) -> NSFontPanel.ModeMask { [.collection, .face] }

    /// Variable-font axis values of a font, keyed by four-character tag.
    static func variations(of font: NSFont) -> [String: Double] {
        guard let v = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] else { return [:] }
        var out: [String: Double] = [:]
        for (k, val) in v {
            let id = k.uint32Value
            let tag = String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) }, encoding: .ascii) ?? "\(id)"
            out[tag] = val.doubleValue
        }
        return out
    }
}

// MARK: Cut

private struct CutSection: View {
    @ObservedObject var model: EditorModel

    var objs: [DesignObject] { model.selectedObjects }
    var cut: CutSettings { objs.first?.cut ?? CutSettings() }
    var thickness: Double { model.sheet.stock.thickness }

    var body: some View {
        InspectorSection("Cut") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: model.cutBinding(\.type, default: .pocket)) {
                    ForEach(CutType.allCases) { t in
                        Image(systemName: t.symbol).tag(t).help(t.label)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                HStack {
                    Text(model.isMixed(\.cut.type) ? "Mixed cuts" : cut.type.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.offwhite)
                    Text(blurb(cut.type)).font(.system(size: 11)).foregroundStyle(Color.steel).lineLimit(2)
                }
                if objs.contains(where: { !$0.geometry.isClosed }) && [.pocket, .profile, .vcarve].contains(cut.type) {
                    WarningRow(text: "Open paths can only be engraved along the line.")
                }
                switch cut.type {
                case .none: EmptyView()
                case .vcarve: vcarveRows
                default: depthRows
                }
                if cut.type == .profile { profileRows }
            }
        }
    }

    func blurb(_ t: CutType) -> String {
        switch t {
        case .none: return "Drawn only, not cut."
        case .engrave: return "The bit runs on the line."
        case .profile: return "Around the line, inside or out."
        case .pocket: return "Clears the area to depth."
        case .vcarve: return "V-bit; depth follows the width."
        }
    }

    @ViewBuilder var depthRows: some View {
        FieldRow("Depth") {
            if cut.through {
                Text("Through + \(model.formatLength(model.doc.bits.overcut))").font(.mono).foregroundStyle(Color.offwhite)
            } else {
                NumberField(value: setDepth, range: 0...max(thickness + 5, 0.01), step: 0.1, width: 64, mixed: model.isMixed(\.cut.depth))
            }
        }
        Slider(value: Binding(get: { cut.through ? thickness : min(cut.depth, thickness) }, set: { v in
            model.editSelection("Depth", coalesce: "depth-slider") { o in
                o.cut.through = false
                o.cut.depth = (v * 10).rounded() / 10
            }
        }), in: 0...max(thickness, 0.1))
        .help("From the stock top (left) to the bottom (right)")
        HStack(spacing: 4) {
            ForEach([0.5, 1, 2, 3], id: \.self) { d in
                Button(UnitFormat.trimmed(model.useInches ? d / 25.4 : d, digits: 3)) { setDepth.wrappedValue = d }
                    .swarfButton(.normal, .small, active: !cut.through && abs(cut.depth - d) < 1e-6)
                    .disabled(d > thickness)
            }
            Button("Through") {
                model.editSelection("Through") { $0.cut.through = true }
            }
            .swarfButton(.normal, .small, active: cut.through)
        }
        if !cut.through && cut.depth > thickness {
            WarningRow(text: "Deeper than the stock (\(model.formatLength(thickness))).", error: true)
        }
    }

    var setDepth: Binding<Double> {
        Binding(get: { cut.depth }, set: { v in
            model.editSelection("Depth", coalesce: "depth") { o in
                o.cut.through = false
                o.cut.depth = max(0, v)
            }
        })
    }

    @ViewBuilder var profileRows: some View {
        FieldRow("Side") {
            Picker("", selection: model.cutBinding(\.profileSide, default: .outside)) {
                Text("Outside").tag(ProfileSide.outside)
                Text("Inside").tag(ProfileSide.inside)
                Text("On line").tag(ProfileSide.on)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 190)
        }
        FieldRow("Tabs") {
            Toggle("Hold the part with tabs", isOn: model.cutBinding(\.tabs.enabled, "Tabs", default: true))
                .toggleStyle(.checkbox)
        }
        if cut.tabs.enabled {
            HStack(spacing: 10) {
                NumberField(title: "Count", value: Binding(get: { Double(cut.tabs.count) }, set: { v in model.editSelection("Tabs") { $0.cut.tabs.count = Int(v) } }),
                            kind: .count, range: 0...64, step: 1, width: 36)
                NumberField(title: "L", value: model.cutBinding(\.tabs.length, "Tabs", default: 6), range: 0.5...200, width: 46)
                NumberField(title: "H", value: model.cutBinding(\.tabs.height, "Tabs", default: 2), range: 0.1...100, width: 46)
            }
            .padding(.leading, 86)
            if !cut.tabs.positions.isEmpty {
                HStack {
                    Text("\(cut.tabs.positions.count) placed by hand").font(.system(size: 11)).foregroundStyle(Color.steel)
                    Button("Space Evenly") { model.editSelection("Tabs") { $0.cut.tabs.positions = [] } }.swarfButton(.ghost, .small)
                }
                .padding(.leading, 86)
            }
            if !cut.through {
                Text("Tabs apply to through cuts.").font(.system(size: 11)).foregroundStyle(Color.steelDim).padding(.leading, 86)
            }
        }
    }

    @ViewBuilder var vcarveRows: some View {
        FieldRow("Bit") {
            Text(model.doc.bits.vBit.name).font(.system(size: 11.5)).foregroundStyle(Color.offwhite).lineLimit(1)
        }
        FieldRow("Flat bottom") {
            Toggle("Limit depth", isOn: Binding(get: { cut.vcarveMaxDepth != nil }, set: { on in
                model.editSelection("V-carve Depth") { $0.cut.vcarveMaxDepth = on ? min(3, thickness) : nil }
            }))
            .toggleStyle(.checkbox)
        }
        if let d = cut.vcarveMaxDepth {
            FieldRow("Max depth") {
                NumberField(value: Binding(get: { d }, set: { v in model.editSelection("V-carve Depth", coalesce: "vdepth") { $0.cut.vcarveMaxDepth = max(0.05, v) } }),
                            range: 0.05...max(thickness, 0.05), step: 0.1, width: 64)
            }
        }
    }
}
