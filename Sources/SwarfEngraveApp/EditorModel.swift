// Editor state shared by every view in a document window. CONTRACT between the shell agent (sidebar, inspector,
// toolbar, menus, sheets) and the canvas agent (2D canvas, 3D carve view). The shell agent owns this file; the canvas
// agent adds behaviour in `extension EditorModel` blocks in its own files and asks for any new stored property.

import CAMCore
import Combine
import EngraveCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let swarfEngrave = UTType(exportedAs: "io.github.swarf-suite.swarfengrave")
}

struct EngraveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.swarfEngrave] }
    var doc: EngraveDocument

    init(doc: EngraveDocument = EngraveDocument()) { self.doc = doc }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        doc = try JSONDecoder().decode(EngraveDocument.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try enc.encode(doc))
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case design, carve, both
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .design: return "square.and.pencil"
        case .carve: return "cube"
        case .both: return "rectangle.split.1x2"
        }
    }
}

/// What a drag on the canvas does.
enum CanvasTool: String, CaseIterable, Identifiable {
    case select, directSelect, pen, measure, placeTabs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "Select"
        case .directSelect: return "Edit Points"
        case .pen: return "Pen"
        case .measure: return "Measure"
        case .placeTabs: return "Place Tabs"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .directSelect: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pen: return "pencil.tip"
        case .measure: return "ruler"
        case .placeTabs: return "rectangle.on.rectangle.angled"
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    /// The document. Views write through `edit(_:)` so changes are undoable.
    @Published var doc: EngraveDocument
    /// Called after every committed change so the FileDocument binding is updated (set by the window).
    var onChange: ((EngraveDocument) -> Void)?
    weak var undoManager: UndoManager?

    @Published var currentSheetID: UUID
    @Published var selection: Set<UUID> = []
    @Published var viewMode: ViewMode = .design
    @Published var tool: CanvasTool = .select
    @Published var showInspector = true
    @Published var useInches = false
    @Published var snapToGrid = true
    @Published var gridSpacing: Double = 10  // mm, major lines; minor = /5

    /// Fast preview of the carved surface for the 3D view (stock-space Z per cell), rebuilt after edits.
    @Published var previewSurface: Grid2D?
    /// Real toolpaths, made by Make Toolpaths and shown over the 3D view.
    @Published var toolpaths: [Toolpath] = []
    @Published var showToolpaths = false
    @Published var problems: [PlanProblem] = []
    @Published var estimatedSeconds: Double?
    @Published var busy = false

    @Published var errorMessage: String?
    @Published var showExport = false
    @Published var showImporter = false
    @Published var showTraceSheet: URL?

    init(doc: EngraveDocument) {
        self.doc = doc
        currentSheetID = doc.sheets.first?.id ?? UUID()
    }

    var sheetIndex: Int { doc.sheets.firstIndex { $0.id == currentSheetID } ?? 0 }
    var sheet: Sheet { doc.sheets[sheetIndex] }

    /// Apply a change to the document as one undo step.
    func edit(_ actionName: String = "Edit", _ change: (inout EngraveDocument) -> Void) {
        let before = doc
        var after = doc
        change(&after)
        guard after != before else { return }
        setDoc(after, actionName: actionName, previous: before)
    }

    private func setDoc(_ new: EngraveDocument, actionName: String, previous: EngraveDocument) {
        doc = new
        onChange?(new)
        undoManager?.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated { m.setDoc(previous, actionName: actionName, previous: new) }
        }
        undoManager?.setActionName(actionName)
        documentDidChange()
    }

    /// Edit the current sheet.
    func editSheet(_ actionName: String = "Edit", _ change: (inout Sheet) -> Void) {
        let i = sheetIndex
        edit(actionName) { change(&$0.sheets[i]) }
    }

    /// Edit one object on the current sheet.
    func editObject(_ id: UUID, _ actionName: String = "Edit", _ change: (inout DesignObject) -> Void) {
        editSheet(actionName) { s in
            if let i = s.objects.firstIndex(where: { $0.id == id }) { change(&s.objects[i]) }
        }
    }

    var selectedObjects: [DesignObject] { sheet.objects.filter { selection.contains($0.id) } }

    /// Hook for the preview rebuild (debounced); implemented by the shell agent.
    func documentDidChange() {}
}

/// A problem shown in the sidebar list and as a badge on the canvas.
struct PlanProblem: Identifiable, Hashable {
    enum Severity { case ok, warning, error }
    let id = UUID()
    var objectID: UUID?
    var severity: Severity
    var message: String
}
