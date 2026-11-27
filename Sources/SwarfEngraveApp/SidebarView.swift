// The sidebar: Setup, the design's objects grouped by cut, sheets and problems.

import CAMCore
import EngraveCore
import SwiftUI

enum SidebarItem: Hashable {
    case setup(SetupItem)
    case object(UUID)
}

struct SidebarView: View {
    @ObservedObject var model: EditorModel

    /// The List's selection, mapped onto the model's object and Setup selections.
    private var listSelection: Binding<Set<SidebarItem>> {
        Binding(get: {
            if let s = model.setupSelection { return [.setup(s)] }
            return Set(model.selection.map { .object($0) })
        }, set: { items in
            let setups = items.compactMap { if case .setup(let s) = $0 { return s } else { return nil } }
            let objects = items.compactMap { if case .object(let id) = $0 { return id } else { return nil } }
            if let s = setups.first(where: { $0 != model.setupSelection }) ?? (objects.isEmpty ? setups.first : nil) {
                model.selection = []
                model.setupSelection = s
            } else {
                model.setupSelection = nil
                model.selection = Set(objects)
            }
        })
    }

    var body: some View {
        List(selection: listSelection) {
            setupSection
            designSection
            sheetsSection
            problemsSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.slate)
        .onDeleteCommand { model.deleteSelection() }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            let s = model.sheet
            SetupRow(item: .stock, detail: "\(UnitFormat.trimmed(s.stock.width / unitDiv, digits: 2)) × \(UnitFormat.trimmed(s.stock.height / unitDiv, digits: 2)) × \(UnitFormat.trimmed(s.stock.thickness / unitDiv, digits: 2)) \(model.useInches ? "in" : "mm")") {
                Circle().fill(Color(hexString: s.stock.colorHex) ?? .steel).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.lineStrong))
                    .help(speciesName(s.stock))
            }
            .tag(SidebarItem.setup(.stock))
            SetupRow(item: .workZero, detail: "\(s.workZero.corner.label) · Z on \(s.workZero.zOnTop ? "top" : "spoilboard")") { EmptyView() }
                .tag(SidebarItem.setup(.workZero))
            SetupRow(item: .machine, detail: model.doc.machine.name) { EmptyView() }
                .tag(SidebarItem.setup(.machine))
        } header: {
            Eyebrow("Setup")
        }
    }

    private var unitDiv: Double { model.useInches ? 25.4 : 1 }

    private func speciesName(_ s: Stock) -> String {
        Stock.species.first { $0.colorHex.lowercased() == s.colorHex.lowercased() && $0.materialID == s.materialID }?.name ?? s.material.name
    }

    // MARK: Design

    private var designSection: some View {
        Section {
            let groups = model.cutGroups
            if groups.isEmpty {
                Text("Add a shape, text or artwork from the toolbar.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.steel)
                    .selectionDisabled()
            }
            ForEach(groups) { g in
                GroupHeaderRow(model: model, group: g)
                    .selectionDisabled()
                ForEach(g.objects) { o in
                    ObjectRow(model: model, object: o, groupCut: g.cut)
                        .tag(SidebarItem.object(o.id))
                }
            }
        } header: {
            HStack {
                Eyebrow("Design")
                Spacer()
                Menu {
                    ForEach(ShapeKind.allCases) { k in
                        Button { model.addShape(k) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                    Divider()
                    Button { model.addText() } label: { Label("Text", systemImage: "textformat") }
                    Button { model.showImporter = true } label: { Label("Import Artwork…", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an object")
            }
        }
    }

    // MARK: Sheets

    private var sheetsSection: some View {
        Section {
            ForEach(model.doc.sheets) { s in
                SheetRow(model: model, sheet: s)
                    .selectionDisabled()
            }
        } header: {
            HStack {
                Eyebrow("Sheets")
                Spacer()
                Button { model.addSheet() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a sheet of stock")
            }
        }
    }

    // MARK: Problems

    private var problemsSection: some View {
        Section {
            if model.problems.isEmpty {
                Label {
                    Text("No problems found").font(.system(size: 12))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ok)
                }
                .selectionDisabled()
            }
            ForEach(model.problems) { p in
                Button {
                    if let id = p.objectID, model.sheet.objects.contains(where: { $0.id == id }) { model.selection = [id] }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.message).font(.system(size: 11.5)).foregroundStyle(Color.offwhite)
                                .fixedSize(horizontal: false, vertical: true)
                            if let id = p.objectID, let o = model.sheet.objects.first(where: { $0.id == id }) {
                                Text(o.name).font(.system(size: 10.5)).foregroundStyle(Color.steel)
                            }
                        }
                    } icon: {
                        Image(systemName: p.symbol).foregroundStyle(p.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .help(p.severity == .error ? "Error" : "Warning")
            }
        } header: {
            HStack {
                Eyebrow("Problems")
                Spacer()
                if !model.problems.isEmpty {
                    Badge(text: "\(model.problems.count)", color: model.problems.contains { $0.severity == .error } ? .danger : .warn)
                }
            }
        }
    }
}

// MARK: Rows

private struct SetupRow<Accessory: View>: View {
    let item: SetupItem
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).foregroundStyle(Color.offwhite)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.steel).lineLimit(1)
                }
                Spacer()
                accessory
            }
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(Color.accent)
        }
    }
}

/// A cut group's heading inside the Design section; rows dropped on it take its cut.
private struct GroupHeaderRow: View {
    @ObservedObject var model: EditorModel
    let group: CutGroup
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.cut.type.symbol).font(.system(size: 10)).foregroundStyle(Color.steel)
            Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Color.steel)
            Spacer()
            Text("\(group.objects.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.steelDim)
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(targeted ? Color.accentDim : .clear))
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(objectID(from:))
            guard !ids.isEmpty else { return false }
            model.dropObjects(ids, onto: nil, groupCut: group.cut)
            return true
        } isTargeted: { targeted = $0 }
    }
}

func objectID(from s: String) -> UUID? {
    guard s.hasPrefix(objectDragPrefix) else { return nil }
    return UUID(uuidString: String(s.dropFirst(objectDragPrefix.count)))
}

private struct ObjectRow: View {
    @ObservedObject var model: EditorModel
    let object: DesignObject
    let groupCut: CutSettings
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var depthText: String {
        let c = object.cut
        switch c.type {
        case .none: return "—"
        case .vcarve: return c.vcarveMaxDepth.map { "≤" + model.formatLength($0, digits: 1) } ?? "V"
        default: return c.through ? "thru" : model.formatLength(c.depth, digits: 2)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: object.cut.type.symbol)
                .frame(width: 16)
                .foregroundStyle(object.cut.type == .none ? Color.steel : Color.accent)
            if model.renamingID == object.id {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { finishRename() }
                    .onAppear { name = object.name; nameFocused = true }
                    .onChange(of: nameFocused) { _, f in if !f { finishRename() } }
            } else {
                Text(object.name).lineLimit(1)
                    .foregroundStyle(object.hidden ? Color.steelDim : Color.offwhite)
                    .strikethrough(object.hidden)
            }
            Spacer(minLength: 4)
            if object.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.steel) }
            if object.hidden { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(Color.steel) }
            if object.groupID != nil { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Color.steelDim).help("Grouped") }
            Text(depthText).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.steel)
        }
        .padding(.leading, 6)
        .overlay(alignment: .top) {
            if targeted { Rectangle().fill(Color.accent).frame(height: 2).offset(y: -3) }
        }
        .draggable(objectDragPrefix + object.id.uuidString) {
            Label(object.name, systemImage: object.cut.type.symbol).padding(6).background(Color.slate3, in: RoundedRectangle(cornerRadius: 5))
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(objectID(from:))
            guard !ids.isEmpty else { return false }
            model.dropObjects(ids, onto: object.id, groupCut: groupCut)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Rename") { model.renamingID = object.id }
            Button(object.hidden ? "Show" : "Hide") { model.toggleHidden(object.id) }
            Button(object.locked ? "Unlock" : "Lock") { model.toggleLocked(object.id) }
            Divider()
            Button("Duplicate") {
                if !model.selection.contains(object.id) { model.selection = [object.id] }
                model.duplicateSelection()
            }
            Button("Delete", role: .destructive) {
                if !model.selection.contains(object.id) { model.selection = [object.id] }
                model.deleteSelection()
            }
        }
    }

    private func finishRename() {
        guard model.renamingID == object.id else { return }
        model.renamingID = nil
        model.rename(object.id, to: name)
    }
}

private struct SheetRow: View {
    @ObservedObject var model: EditorModel
    let sheet: Sheet
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var current: Bool { sheet.id == model.currentSheetID }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: current ? "square.fill.on.square.fill" : "square.on.square")
                .foregroundStyle(current ? Color.accent : Color.steel)
                .frame(width: 16)
            if model.renamingID == sheet.id {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { finishRename() }
                    .onAppear { name = sheet.name; nameFocused = true }
                    .onChange(of: nameFocused) { _, f in if !f { finishRename() } }
            } else {
                Text(sheet.name).fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(current ? Color.offwhite : Color.steel)
            }
            Spacer()
            Text("\(sheet.objects.count)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.steelDim)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.accentDim : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.currentSheetID = sheet.id }
        .contextMenu {
            Button("Rename") { model.renamingID = sheet.id }
            Button("Duplicate") { model.duplicateSheet(sheet.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSheet(sheet.id) }
                .disabled(model.doc.sheets.count < 2)
        }
    }

    private func finishRename() {
        guard model.renamingID == sheet.id else { return }
        model.renamingID = nil
        model.renameSheet(sheet.id, to: name)
    }
}
