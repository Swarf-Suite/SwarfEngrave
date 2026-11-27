// Inspector content for the sidebar's Setup rows: Stock, Work Zero, and Machine & Bits.

import CAMCore
import EngraveCore
import SwiftUI

// MARK: Stock

struct StockInspector: View {
    @ObservedObject var model: EditorModel

    var stock: Stock { model.sheet.stock }

    func stockBinding(_ kp: WritableKeyPath<Stock, Double>, _ name: String, min lo: Double) -> Binding<Double> {
        Binding(get: { stock[keyPath: kp] }, set: { v in model.editSheet(name, coalesce: "stock-\(name)") { $0.stock[keyPath: kp] = max(lo, v) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Stock") {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow("Width (X)") { NumberField(value: stockBinding(\.width, "Stock Width", min: 1), range: 1...100000) }
                    FieldRow("Height (Y)") { NumberField(value: stockBinding(\.height, "Stock Height", min: 1), range: 1...100000) }
                    FieldRow("Thickness") { NumberField(value: stockBinding(\.thickness, "Stock Thickness", min: 0.1), range: 0.1...1000, step: 0.5) }
                    if let over = model.sheet.objects.first(where: { !$0.cut.through && $0.cut.type != .none && $0.cut.type != .vcarve && $0.cut.depth > stock.thickness }) {
                        WarningRow(text: "\(over.name) cuts deeper than the stock is thick.")
                    }
                }
            }
            InspectorSection("Material") {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
                        ForEach(Stock.species, id: \.name) { sp in
                            let on = sp.colorHex.lowercased() == stock.colorHex.lowercased() && sp.materialID == stock.materialID
                            Button {
                                model.editSheet("Stock Species") { $0.stock.materialID = sp.materialID; $0.stock.colorHex = sp.colorHex }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(hexString: sp.colorHex) ?? .steel).frame(width: 12, height: 12)
                                        .overlay(Circle().strokeBorder(Color.lineStrong))
                                    Text(sp.name).font(.system(size: 11.5)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .swarfButton(.normal, .small, active: on)
                        }
                    }
                    FieldRow("Feeds for") {
                        Picker("", selection: Binding(get: { stock.materialID }, set: { id in model.editSheet("Stock Material") { $0.stock.materialID = id } })) {
                            ForEach(Material.library, id: \.id) { m in Text(m.name).tag(m.id) }
                        }
                        .labelsHidden().frame(maxWidth: 160)
                    }
                    FieldRow("Colour") {
                        ColorPicker("", selection: Binding(get: { Color(hexString: stock.colorHex) ?? .steel },
                                                           set: { c in model.editSheet("Stock Colour", coalesce: "stock-colour") { $0.stock.colorHex = c.hexString } }),
                                    supportsOpacity: false)
                            .labelsHidden()
                        Text(stock.colorHex).font(.mono).foregroundStyle(Color.steel)
                    }
                    FieldRow("Grain") {
                        Toggle("Show wood grain in 3D", isOn: Binding(get: { stock.showGrain }, set: { v in model.editSheet("Grain") { $0.stock.showGrain = v } }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
}

// MARK: Work zero

struct WorkZeroInspector: View {
    @ObservedObject var model: EditorModel

    var zero: WorkZero { model.sheet.workZero }

    var body: some View {
        InspectorSection("Work Zero") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where X0 Y0 Z0 is on the stock. Zero the machine at this point before carving.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.steel)
                    .fixedSize(horizontal: false, vertical: true)
                CornerDiagram(corner: Binding(get: { zero.corner }, set: { c in model.editSheet("Work Zero") { $0.workZero.corner = c } }),
                              aspect: model.sheet.stock.width / max(model.sheet.stock.height, 1))
                    .frame(maxWidth: .infinity)
                FieldRow("Corner") {
                    Text(zero.corner.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.offwhite)
                }
                FieldRow("Z zero") {
                    Picker("", selection: Binding(get: { zero.zOnTop }, set: { v in model.editSheet("Work Zero") { $0.workZero.zOnTop = v } })) {
                        Text("Stock top").tag(true)
                        Text("Spoilboard").tag(false)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
                Text(zero.zOnTop ? "Touch off on the top of the stock." : "Touch off on the spoilboard; the stock thickness must be accurate.")
                    .font(.system(size: 11)).foregroundStyle(Color.steelDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The stock seen from above, with a target at each corner and the centre.
private struct CornerDiagram: View {
    @Binding var corner: WorkZero.Corner
    let aspect: Double

    var body: some View {
        let w: CGFloat = 200
        let h = max(60, min(160, w / CGFloat(max(aspect, 0.2))))
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.slate3)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.lineStrong))
                .frame(width: w, height: h)
            Text("FRONT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Color.steelDim)
                .offset(y: h / 2 + 10)
            ForEach(WorkZero.Corner.allCases) { c in
                let p = pos(c, w, h)
                Button { corner = c } label: {
                    Image(systemName: c == corner ? "scope" : "circle")
                        .font(.system(size: c == corner ? 18 : 11, weight: .semibold))
                        .foregroundStyle(c == corner ? Color.accent : Color.steel)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.label)
                .offset(x: p.x, y: p.y)
            }
        }
        .frame(width: w + 30, height: h + 40)
    }

    func pos(_ c: WorkZero.Corner, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        switch c {
        case .frontLeft: return CGPoint(x: -w / 2, y: h / 2)
        case .frontRight: return CGPoint(x: w / 2, y: h / 2)
        case .backLeft: return CGPoint(x: -w / 2, y: -h / 2)
        case .backRight: return CGPoint(x: w / 2, y: -h / 2)
        case .center: return .zero
        }
    }
}

// MARK: Machine & bits

struct MachineInspector: View {
    @ObservedObject var model: EditorModel

    var bits: BitSettings { model.doc.bits }
    var library: [Tool] { ToolLibrary.starter.tools }
    var flats: [Tool] { library.filter { $0.kind != .vBit } }
    var vBits: [Tool] { library.filter { $0.kind == .vBit } }

    func editBits(_ name: String, coalesce: String? = nil, _ change: @escaping (inout BitSettings) -> Void) {
        model.edit(name, coalesce: coalesce) { change(&$0.bits) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Machine") {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow("Machine") {
                        Picker("", selection: Binding(get: { model.doc.machineID }, set: { id in model.edit("Machine") { $0.machineID = id } })) {
                            ForEach(EngraveDocument.machines, id: \.id) { m in Text(m.name).tag(m.id) }
                        }
                        .labelsHidden().frame(maxWidth: 190)
                    }
                    FieldRow("Files") {
                        Text(model.doc.machine.splitFilesPerTool ? "One .\(model.doc.machine.fileExtension) per bit" : "One .\(model.doc.machine.fileExtension) file")
                            .font(.system(size: 11.5)).foregroundStyle(Color.steel)
                    }
                }
            }
            InspectorSection("Bits") {
                VStack(alignment: .leading, spacing: 12) {
                    bitBlock("Main bit", "Engraving, profiles and pocket finishing.", tool: bits.main, choices: flats) { t in editBits("Main Bit") { $0.main = t } }
                    Divider().overlay(Color.line)
                    FieldRow("Clearing") {
                        Toggle("Use a larger bit for big pockets", isOn: Binding(get: { bits.clearing != nil }, set: { on in
                            editBits("Clearing Bit") { b in
                                b.clearing = on ? (flats.filter { $0.diameter > b.main.diameter }.min { $0.diameter < $1.diameter } ?? flats.max { $0.diameter < $1.diameter }) : nil
                            }
                        }))
                        .toggleStyle(.checkbox)
                    }
                    if let c = bits.clearing {
                        bitBlock("Clearing bit", "Clears the bulk of large pockets first.", tool: c, choices: flats) { t in editBits("Clearing Bit") { $0.clearing = t } }
                    }
                    Divider().overlay(Color.line)
                    bitBlock("V-bit", "For V-carve objects.", tool: bits.vBit, choices: vBits) { t in editBits("V-bit") { $0.vBit = t } }
                }
            }
            InspectorSection("Heights") {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow("Overcut") {
                        NumberField(value: Binding(get: { bits.overcut }, set: { v in editBits("Overcut", coalesce: "overcut") { $0.overcut = max(0, v) } }), range: 0...20, step: 0.1)
                    }
                    Text("Extra depth below the stock for through cuts.").font(.system(size: 11)).foregroundStyle(Color.steelDim).padding(.leading, 86)
                    FieldRow("Safe height") {
                        NumberField(value: Binding(get: { bits.safeHeight }, set: { v in editBits("Safe Height", coalesce: "safe") { $0.safeHeight = max(0.5, v) } }), range: 0.5...100, step: 1)
                    }
                    Text("Clearance above the stock top for rapid moves.").font(.system(size: 11)).foregroundStyle(Color.steelDim).padding(.leading, 86)
                }
            }
        }
    }

    /// A bit picker (matched by name: starter tool ids change each launch) with its editable diameter and angle.
    @ViewBuilder
    func bitBlock(_ title: String, _ blurb: String, tool: Tool, choices: [Tool], set: @escaping (Tool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.offwhite)
                Text(blurb).font(.system(size: 11)).foregroundStyle(Color.steel).lineLimit(1)
            }
            FieldRow("Bit") {
                Picker("", selection: Binding(get: { tool.name }, set: { n in if let t = choices.first(where: { $0.name == n }) { set(t) } })) {
                    if !choices.contains(where: { $0.name == tool.name }) { Text(tool.name).tag(tool.name) }
                    ForEach(choices, id: \.name) { t in Text(t.name).tag(t.name) }
                }
                .labelsHidden().frame(maxWidth: 200)
            }
            HStack(spacing: 10) {
                NumberField(title: "Ø", value: Binding(get: { tool.diameter }, set: { v in var t = tool; t.diameter = max(0.05, v); set(t) }), range: 0.05...100, width: 56)
                if tool.kind == .vBit {
                    NumberField(title: "Angle", value: Binding(get: { tool.vAngle }, set: { v in var t = tool; t.vAngle = min(max(v, 10), 170); set(t) }), kind: .angle, range: 10...170, width: 44)
                }
            }
            .padding(.leading, 86)
        }
    }
}
