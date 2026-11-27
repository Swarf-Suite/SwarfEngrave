// Editor state shared by every view in a document window. CONTRACT between the shell agent (sidebar, inspector,
// toolbar, menus, sheets) and the canvas agent (2D canvas, 3D carve view). The shell agent owns this file; the canvas
// agent adds behaviour in `extension EditorModel` blocks in its own files and asks for any new stored property.
// Object, arrange and path commands live in EditorActions.swift.

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

/// The Setup rows in the sidebar; when one is selected the inspector edits it.
enum SetupItem: String, Hashable, CaseIterable {
    case stock, workZero, machine
    var label: String {
        switch self {
        case .stock: return "Stock"
        case .workZero: return "Work Zero"
        case .machine: return "Machine & Bits"
        }
    }
    var symbol: String {
        switch self {
        case .stock: return "shippingbox"
        case .workZero: return "scope"
        case .machine: return "gearshape.2"
        }
    }
}

/// The 9-point reference for X/Y in the inspector (fractions of the selection's bounds).
struct Anchor: Hashable {
    var fx: Double
    var fy: Double
    static let center = Anchor(fx: 0.5, fy: 0.5)
    static let all: [Anchor] = [0, 0.5, 1].reversed().flatMap { fy in [0, 0.5, 1].map { Anchor(fx: $0, fy: fy) } }
}

@MainActor
final class EditorModel: ObservableObject {
    /// The document. Views write through `edit(_:)` so changes are undoable.
    @Published var doc: EngraveDocument
    /// Called after every committed change so the FileDocument binding is updated (set by the window).
    var onChange: ((EngraveDocument) -> Void)?
    weak var undoManager: UndoManager?

    @Published var currentSheetID: UUID {
        didSet {
            guard currentSheetID != oldValue else { return }
            selection = []
            toolpaths = []
            estimatedSeconds = nil
            lastPlan = nil
            documentDidChange()
        }
    }
    /// Selected objects on the current sheet. Selecting objects clears the Setup selection.
    @Published var selection: Set<UUID> = [] {
        didSet { if !selection.isEmpty, setupSelection != nil { setupSelection = nil } }
    }
    /// A Setup row selected in the sidebar (the inspector then edits stock, work zero or machine).
    @Published var setupSelection: SetupItem?
    @Published var viewMode: ViewMode = .design
    @Published var tool: CanvasTool = .select
    @Published var showInspector = true
    @Published var useInches = false
    @Published var snapToGrid = true
    @Published var gridSpacing: Double = 10  // mm, major lines; minor = /5
    /// Inspector X/Y reference point.
    @Published var anchor: Anchor = .center
    @Published var lockAspect = true

    /// Fast preview of the carved surface for the 3D view (stock-space Z per cell), rebuilt after edits.
    @Published var previewSurface: Grid2D?
    /// Real toolpaths, made by Make Toolpaths and shown over the 3D view.
    @Published var toolpaths: [Toolpath] = []
    @Published var showToolpaths = false
    /// The design changed since the toolpaths were made.
    @Published var toolpathsStale = false
    @Published var problems: [PlanProblem] = []
    @Published var estimatedSeconds: Double?
    @Published var busy = false

    @Published var errorMessage: String?
    @Published var showExport = false
    /// The export sheet sends to SwarfGRBL as soon as it opens (Send to SwarfGRBL).
    @Published var sendWhenExportOpens = false
    @Published var showImporter = false
    @Published var showTraceSheet: URL?
    /// Where traced artwork goes (a drop point), nil = stock centre.
    var traceDropPoint: V2?
    /// The window's document name, used as the G-code job name.
    @Published var documentName = "Untitled"
    /// Sidebar inline rename (object or sheet id).
    @Published var renamingID: UUID?

    /// The last plan and what it was made from, so Export can reuse it.
    private(set) var lastPlan: CarvePlan?
    private var lastPlanInput: (sheet: Sheet, bits: BitSettings, machineID: String)?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration = 0
    private var planGeneration = 0

    init(doc: EngraveDocument) {
        self.doc = doc
        currentSheetID = doc.sheets.first?.id ?? UUID()
        useInches = UserDefaults.standard.bool(forKey: "defaultUseInches")
        documentDidChange()
    }

    var sheetIndex: Int { doc.sheets.firstIndex { $0.id == currentSheetID } ?? 0 }
    var sheet: Sheet { doc.sheets[sheetIndex] }

    // MARK: Undoable edits

    private final class UndoStep {
        var previous: EngraveDocument
        var new: EngraveDocument
        let name: String
        init(previous: EngraveDocument, new: EngraveDocument, name: String) {
            self.previous = previous
            self.new = new
            self.name = name
        }
    }
    private var lastStep: (step: UndoStep, key: String, time: Date)?

    /// Apply a change to the document as one undo step. Edits with the same `coalesce` key less than a second apart
    /// (slider drags, canvas drags, typing) merge into one undo step.
    func edit(_ actionName: String = "Edit", coalesce: String? = nil, _ change: (inout EngraveDocument) -> Void) {
        let before = doc
        var after = doc
        change(&after)
        guard after != before else { return }
        if let key = coalesce, let last = lastStep, last.key == key, Date().timeIntervalSince(last.time) < 1, last.step.new == before {
            last.step.new = after
            lastStep = (last.step, key, Date())
            apply(after)
            return
        }
        let step = UndoStep(previous: before, new: after, name: actionName)
        lastStep = coalesce.map { (step, $0, Date()) }
        apply(after)
        registerUndo(step, redo: false)
    }

    private func registerUndo(_ step: UndoStep, redo: Bool) {
        undoManager?.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated {
                m.lastStep = nil
                m.apply(redo ? step.new : step.previous)
                m.registerUndo(step, redo: !redo)
            }
        }
        undoManager?.setActionName(step.name)
    }

    private func apply(_ new: EngraveDocument) {
        doc = new
        if !doc.sheets.contains(where: { $0.id == currentSheetID }), let first = doc.sheets.first { currentSheetID = first.id }
        let ids = Set(sheet.objects.map(\.id))
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
        onChange?(new)
        documentDidChange()
    }

    /// The file changed underneath (revert, external edit): take it without an undo step.
    func replaceDocument(_ new: EngraveDocument) {
        guard new != doc else { return }
        lastStep = nil
        doc = new
        if !doc.sheets.contains(where: { $0.id == currentSheetID }), let first = doc.sheets.first { currentSheetID = first.id }
        selection = selection.intersection(Set(sheet.objects.map(\.id)))
        documentDidChange()
    }

    /// Edit the current sheet.
    func editSheet(_ actionName: String = "Edit", coalesce: String? = nil, _ change: (inout Sheet) -> Void) {
        let i = sheetIndex
        edit(actionName, coalesce: coalesce) { change(&$0.sheets[i]) }
    }

    /// Edit one object on the current sheet.
    func editObject(_ id: UUID, _ actionName: String = "Edit", coalesce: String? = nil, _ change: (inout DesignObject) -> Void) {
        editSheet(actionName, coalesce: coalesce) { s in
            if let i = s.objects.firstIndex(where: { $0.id == id }) { change(&s.objects[i]) }
        }
    }

    /// Edit every selected object as one undo step.
    func editSelection(_ actionName: String = "Edit", coalesce: String? = nil, _ change: (inout DesignObject) -> Void) {
        let ids = selection
        editSheet(actionName, coalesce: coalesce) { s in
            for i in s.objects.indices where ids.contains(s.objects[i].id) { change(&s.objects[i]) }
        }
    }

    var selectedObjects: [DesignObject] { sheet.objects.filter { selection.contains($0.id) } }

    // MARK: Preview and checks

    /// Rebuilds the carve preview and the problems list a moment after the last edit, off the main thread.
    func documentDidChange() {
        if let p = lastPlanInput { toolpathsStale = !toolpaths.isEmpty && (p.sheet != sheet || p.bits != doc.bits || p.machineID != doc.machineID) }
        rebuildTask?.cancel()
        rebuildGeneration += 1
        let gen = rebuildGeneration
        let sheet = self.sheet, bits = doc.bits
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                (CarvePreview.surface(sheet: sheet, bits: bits), CutPlanner.check(sheet: sheet, bits: bits))
            }.value
            guard let self, gen == self.rebuildGeneration else { return }
            self.previewSurface = result.0
            self.problems = Self.problems(from: result.1)
        }
    }

    static func problems(from warnings: [PlanWarning]) -> [PlanProblem] {
        var seen = Set<String>()
        return warnings.compactMap { w in
            let key = "\(w.objectID?.uuidString ?? "-")|\(w.message)"
            guard seen.insert(key).inserted else { return nil }
            return PlanProblem(objectID: w.objectID, severity: w.severity == .error ? .error : .warning, message: w.message)
        }
    }

    // MARK: Toolpaths

    var planIsCurrent: Bool {
        guard let p = lastPlanInput, lastPlan != nil else { return false }
        return p.sheet == sheet && p.bits == doc.bits && p.machineID == doc.machineID
    }

    /// Make Toolpaths: plans the current sheet off the main thread.
    func makeToolpaths() {
        Task { _ = await plan() }
    }

    /// The plan for the current sheet, reusing the last one when nothing changed.
    @discardableResult
    func plan() async -> CarvePlan {
        if planIsCurrent, let p = lastPlan { return p }
        let sheet = self.sheet, bits = doc.bits, machine = doc.machine, machineID = doc.machineID
        planGeneration += 1
        let gen = planGeneration
        busy = true
        let plan = await Task.detached(priority: .userInitiated) { CutPlanner.plan(sheet: sheet, bits: bits, machine: machine) }.value
        if gen == planGeneration { busy = false }
        lastPlan = plan
        lastPlanInput = (sheet, bits, machineID)
        if sheet.id == currentSheetID {
            toolpaths = plan.toolpaths
            estimatedSeconds = plan.toolpaths.isEmpty ? nil : plan.totalSeconds
            toolpathsStale = self.sheet != sheet
            showToolpaths = !plan.toolpaths.isEmpty
            let checks = CutPlanner.check(sheet: sheet, bits: bits)
            problems = Self.problems(from: plan.warnings + checks)
            if viewMode == .design && !plan.toolpaths.isEmpty { viewMode = .both }
        }
        return plan
    }

    /// G-code files for the current sheet (plans first when needed).
    func gcodeFiles() async -> [GCodeHub.File] {
        let plan = await plan()
        return GCodeExport.files(sheet: sheet, plan: plan, machine: doc.machine, bits: doc.bits, jobName: jobName)
    }

    var jobName: String {
        let base = documentName.isEmpty ? "SwarfEngrave" : documentName
        return doc.sheets.count > 1 ? "\(base) – \(sheet.name)" : base
    }
}

/// A problem shown in the sidebar list and as a badge on the canvas.
struct PlanProblem: Identifiable, Hashable {
    enum Severity { case ok, warning, error }
    let id = UUID()
    var objectID: UUID?
    var severity: Severity
    var message: String

    var symbol: String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch severity {
        case .ok: return .ok
        case .warning: return .warn
        case .error: return .danger
        }
    }
}

func formatDuration(_ s: Double) -> String {
    guard s.isFinite else { return "unknown" }
    let secs = Int(min(max(s, 0), 3.6e8))
    let m = secs / 60, h = m / 60
    return h > 0 ? "\(h) h \(m % 60) min" : m > 0 ? "\(m) min \(secs % 60) s" : "\(secs) s"
}
