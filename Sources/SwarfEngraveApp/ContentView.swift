// One document window: sidebar, the design and carve views, and the inspector.

import CAMCore
import EngraveCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var file: EngraveFile
    var fileURL: URL?
    @StateObject private var model: EditorModel
    @Environment(\.undoManager) private var undoManager

    init(file: Binding<EngraveFile>, fileURL: URL?) {
        _file = file
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: EditorModel(doc: file.wrappedValue.doc))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            detail
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
        .background(Color.obsidian)
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .environment(\.useInches, model.useInches)
        .focusedSceneValue(\.editor, model)
        .onAppear {
            model.undoManager = undoManager
            model.onChange = { doc in if file.doc != doc { file.doc = doc } }
            model.documentName = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        }
        .onChange(of: undoManager) { _, u in model.undoManager = u }
        .onChange(of: file.doc) { _, d in if d != model.doc { model.replaceDocument(d) } }
        .onChange(of: fileURL) { _, u in model.documentName = u?.deletingPathExtension().lastPathComponent ?? "Untitled" }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: ContentView.importTypes) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                model.importArtwork(url: url, at: nil)
            }
        }
        .sheet(item: Binding(get: { model.showTraceSheet.map(TraceItem.init) }, set: { model.showTraceSheet = $0?.url })) { item in
            TraceSheet(model: model, url: item.url)
        }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .alert("SwarfEngrave", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    static var importTypes: [UTType] {
        var t: [UTType] = [.svg, .pdf, .png, .jpeg, .tiff, .bmp, .gif, .heic, .image]
        if let dxf = UTType(filenameExtension: "dxf") { t.append(dxf) }
        return t
    }

    @ViewBuilder var detail: some View {
        switch model.viewMode {
        case .design: DesignCanvasView(model: model)
        case .carve: CarveView(model: model)
        case .both:
            VSplitView {
                DesignCanvasView(model: model).frame(minHeight: 160)
                CarveView(model: model).frame(minHeight: 160)
            }
        }
    }

    var subtitle: String {
        let s = model.sheet.stock
        var parts = ["Stock \(UnitFormat.length(s.width, inches: model.useInches, digits: 1).dropUnit) × \(UnitFormat.length(s.height, inches: model.useInches, digits: 1).dropUnit) × \(UnitFormat.length(s.thickness, inches: model.useInches, digits: 1))",
                     model.doc.machine.name]
        if let t = model.estimatedSeconds { parts.append("~" + formatDuration(t)) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("SWARFENGRAVE")
                .font(.custom("Helvetica", size: 13).weight(.bold))
                .tracking(3)
                .foregroundStyle(Color.accent)
                .fixedSize()
                .padding(.horizontal, 6)
        }
        ToolbarItemGroup(placement: .principal) {
            Menu {
                ForEach(ShapeKind.allCases) { k in
                    Button { model.addShape(k) } label: { Label(k.label, systemImage: k.symbol) }
                }
            } label: {
                Label("Add Shape", systemImage: "square.on.circle")
            }
            .help("Add a shape at the centre of the stock")
            Button { model.addText() } label: { Label("Add Text", systemImage: "textformat") }
                .help("Add text at the centre of the stock")
            Button { model.showImporter = true } label: { Label("Import Artwork", systemImage: "square.and.arrow.down") }
                .help("Import SVG, DXF, PDF or a picture to trace")
            Picker("View", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { m in Label(m.label, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .help("Show the design, the 3D carve, or both")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.busy { ProgressView().controlSize(.small) }
            Button { model.makeToolpaths() } label: {
                Label("Make Toolpaths", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .disabled(model.busy || model.sheet.objects.isEmpty)
            .help(model.planIsCurrent ? "Toolpaths are up to date" : "Work out the toolpaths and the carving time")
            Button { model.showExport = true } label: { Label("Export G-code", systemImage: "doc.badge.arrow.up") }
                .disabled(model.sheet.objects.isEmpty)
                .help("Save G-code files")
            Button { sendToHub() } label: { Label("Send to SwarfGRBL", systemImage: "paperplane") }
                .disabled(model.sheet.objects.isEmpty)
                .help("Send the G-code to SwarfGRBL")
            Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help(model.showInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    /// Send opens the export sheet, which sends and reports the result.
    func sendToHub() {
        model.sendWhenExportOpens = true
        model.showExport = true
    }
}

private struct TraceItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension String {
    /// "12.5 mm" → "12.5".
    var dropUnit: String { components(separatedBy: " ").first ?? self }
}

// MARK: Focused model for menu commands

struct EditorKey: FocusedValueKey { typealias Value = EditorModel }

extension FocusedValues {
    var editor: EditorModel? {
        get { self[EditorKey.self] }
        set { self[EditorKey.self] = newValue }
    }
}
