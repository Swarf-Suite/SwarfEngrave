// Menu bar commands. They act on the focused window's EditorModel.

import CAMCore
import EngraveCore
import SwiftUI

struct EngraveCommands: Commands {
    @FocusedValue(\.editor) private var model

    var hasSelection: Bool { !(model?.selection.isEmpty ?? true) }
    var multi: Bool { (model?.selection.count ?? 0) > 1 }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(!hasSelection)
            Button("Delete Objects") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
            Button("Select All Objects") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(model?.showInspector == false ? "Show Inspector" : "Hide Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model == nil)
            Toggle("Show Inches", isOn: Binding(get: { model?.useInches ?? false }, set: { model?.useInches = $0 }))
                .disabled(model == nil)
            Divider()
        }

        CommandMenu("Insert") {
            Group {
                ForEach(ShapeKind.allCases) { k in
                    Button { model?.addShape(k) } label: { Label(k.label, systemImage: k.symbol) }
                }
                Divider()
                Button { model?.addText() } label: { Label("Text", systemImage: "textformat") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button { model?.showImporter = true } label: { Label("Import Artwork…", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("New Sheet") { model?.addSheet() }
            }
            .disabled(model == nil)
        }

        CommandMenu("Arrange") {
            Group {
                Menu("Align") {
                    ForEach(AlignEdge.allCases, id: \.self) { e in
                        Button(e.label) { model?.align(e) }
                    }
                }
                .disabled(!hasSelection)
                Menu("Distribute") {
                    Button("Horizontally") { model?.distribute(horizontally: true) }
                    Button("Vertically") { model?.distribute(horizontally: false) }
                }
                .disabled((model?.selection.count ?? 0) < 3)
                Divider()
                Button("Group") { model?.groupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(!multi)
                Button("Ungroup") { model?.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                    .disabled(!hasSelection)
                Divider()
                Button("Bring Forward") { model?.reorder(.forward) }.keyboardShortcut("]")
                Button("Send Backward") { model?.reorder(.backward) }.keyboardShortcut("[")
                Button("Bring to Front") { model?.reorder(.front) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Send to Back") { model?.reorder(.back) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Flip Horizontally") { model?.mirror(horizontal: true) }
                Button("Flip Vertically") { model?.mirror(horizontal: false) }
            }
            .disabled(!hasSelection)
        }

        CommandMenu("Path") {
            Group {
                ForEach(PathOperation.allCases, id: \.self) { op in
                    Button(op.label) { model?.combine(op) }
                        .disabled(!(model?.canCombinePaths ?? false))
                }
                Divider()
                Menu("Offset") {
                    ForEach([-3.0, -1, -0.5, 0.5, 1, 3], id: \.self) { d in
                        Button((d > 0 ? "Outward " : "Inward ") + (model?.formatLength(abs(d)) ?? "\(abs(d)) mm")) { model?.offsetSelection(by: d) }
                    }
                }
                .disabled(!hasSelection)
                Menu("Simplify") {
                    Button("Lightly (0.05 mm)") { model?.simplifySelection(tolerance: 0.05) }
                    Button("Moderately (0.2 mm)") { model?.simplifySelection(tolerance: 0.2) }
                    Button("Strongly (0.5 mm)") { model?.simplifySelection(tolerance: 0.5) }
                }
                .disabled(!hasSelection)
            }
            .disabled(model == nil)
        }

        CommandMenu("Carve") {
            Group {
                Button("Make Toolpaths") { model?.makeToolpaths() }
                    .keyboardShortcut("g")
                    .disabled(model?.busy ?? true)
                Button("Export G-code…") { model?.showExport = true }
                    .keyboardShortcut("e")
                Button("Send to SwarfGRBL") {
                    model?.sendWhenExportOpens = true
                    model?.showExport = true
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("View Design") { model?.viewMode = .design }.keyboardShortcut("1")
                Button("View Carve") { model?.viewMode = .carve }.keyboardShortcut("2")
                Button("View Both") { model?.viewMode = .both }.keyboardShortcut("3")
                Divider()
                Toggle("Show Toolpaths", isOn: Binding(get: { model?.showToolpaths ?? false }, set: { model?.showToolpaths = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
            .disabled(model == nil)
        }
    }
}
