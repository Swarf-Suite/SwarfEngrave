// The 2D design canvas: the Core Graphics view (CanvasNSView) with SwiftUI overlays for tools, zoom and the readout.

import AppKit
import CAMCore
import EngraveCore
import SwiftUI

struct DesignCanvasView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var state = CanvasViewState()
    @StateObject private var cursor = CanvasCursor()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CanvasRepresentable(model: model, state: state, cursor: cursor)
                overlays
            }
            bottomBar
        }
        .background(Color.obsidian)
    }

    private var overlays: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    toolPalette
                    Spacer()
                }
                Spacer()
                HStack(alignment: .bottom) {
                    zoomCapsule
                    Spacer()
                    if hasCuts { depthKey }
                }
            }
            .padding(.leading, CanvasNSView.rulerSize + 10)
            .padding(.top, CanvasNSView.rulerSize + 10)
            .padding([.trailing, .bottom], 10)

            if model.sheet.objects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.on.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Color.steel)
                    Text("Add a shape, some text or artwork from the toolbar, or drop a file here")
                        .font(.system(size: 12)).foregroundStyle(Color.steel).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Color.obsidian.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .allowsHitTesting(false)
            }
        }
    }

    private var hasCuts: Bool { model.sheet.objects.contains { !$0.hidden && $0.cut.type != .none } }

    private var toolPalette: some View {
        VStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 28)
                        .foregroundStyle(model.tool == t ? Color.obsidian : Color.offwhite)
                        .background(model.tool == t ? Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.label)
            }
        }
        .padding(4)
        .background(Color.slate, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private var zoomCapsule: some View {
        HStack(spacing: 2) {
            capsuleButton("minus", help: "Zoom out (⌘−)") { state.view?.zoom(by: 0.8) }
            Button { state.view?.zoomToFit() } label: {
                Text("\(Int(state.zoomPercent.rounded()))%").font(.mono).foregroundStyle(Color.offwhite).frame(minWidth: 46)
            }
            .buttonStyle(.plain).help("Fit the stock (⌘0)")
            capsuleButton("plus", help: "Zoom in (⌘+)") { state.view?.zoom(by: 1.25) }
            Divider().frame(height: 16).overlay(Color.line)
            Button { model.useInches.toggle() } label: {
                Text(model.useInches ? "in" : "mm").font(.mono).foregroundStyle(Color.offwhite).frame(width: 30)
            }
            .buttonStyle(.plain).help("Units")
            Divider().frame(height: 16).overlay(Color.line)
            Button { model.snapToGrid.toggle() } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 12))
                    .foregroundStyle(model.snapToGrid ? Color.accent : Color.steel)
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.plain).help(model.snapToGrid ? "Snap to grid is on (hold ⌘ while dragging to move freely)" : "Snap to grid is off")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.slate, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.line))
    }

    private func capsuleButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.offwhite).frame(width: 24, height: 22)
        }
        .buttonStyle(.plain).help(help)
    }

    private var depthKey: some View {
        let t = model.sheet.stock.thickness
        let gradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Color(nsColor: CanvasColor.depth($0, alpha: 1)) })
        return VStack(alignment: .leading, spacing: 4) {
            Text("DEPTH").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Color.steel)
            RoundedRectangle(cornerRadius: 3).fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                .frame(width: 130, height: 8)
            HStack {
                Text("0").font(.system(size: 10, design: .monospaced))
                Spacer()
                Text(model.useInches ? String(format: "%.3f in", t / 25.4) : String(format: "%g mm", t)).font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(Color.steel)
            .frame(width: 130)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: CanvasColor.throughFill))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .frame(width: 14, height: 10)
                    Text("Through").font(.system(size: 10))
                }
                HStack(spacing: 4) {
                    Rectangle().stroke(Color.steel, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 10)
                    Text("Guide").font(.system(size: 10))
                }
            }
            .foregroundStyle(Color.steel)
        }
        .padding(10)
        .background(Color.slate.opacity(0.94), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.line))
        .allowsHitTesting(false)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            CursorReadout(cursor: cursor, inches: model.useInches)
            Text(toolHint).font(.system(size: 11)).foregroundStyle(Color.steel).lineLimit(1)
            Spacer()
            if !model.selection.isEmpty {
                Text(model.selection.count == 1 ? "1 selected" : "\(model.selection.count) selected")
                    .font(.system(size: 11)).foregroundStyle(Color.steel)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.slate)
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    private var toolHint: String {
        switch model.tool {
        case .select: return "Click to select, shift-click to add, drag to move. Hold ⌘ to move without snapping."
        case .directSelect: return "Drag anchors and handles to reshape. Shapes become paths when edited."
        case .pen: return "Click for corners, drag for curves. Click the first point or press Return to close; Esc to finish open."
        case .measure: return "Drag to measure distance and angle."
        case .placeTabs: return "Click a through-profile's outline to add a tab; click a tab to remove it."
        }
    }
}

private struct CursorReadout: View {
    @ObservedObject var cursor: CanvasCursor
    let inches: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let m = cursor.measure {
                Text(m).foregroundStyle(Color.warn)
            } else {
                Text("X \(fmt(cursor.stock?.x))").frame(minWidth: 82, alignment: .leading)
                Text("Y \(fmt(cursor.stock?.y))").frame(minWidth: 82, alignment: .leading)
            }
        }
        .font(.mono)
        .foregroundStyle(Color.offwhite)
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return inches ? String(format: "%.3f", v / 25.4) : String(format: "%.2f", v)
    }
}

private struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    let state: CanvasViewState
    let cursor: CanvasCursor

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView(frame: .zero)
        v.model = model
        v.state = state
        v.cursor = cursor
        state.view = v
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.model = model
        state.view = v
        v.modelChanged()
    }
}
