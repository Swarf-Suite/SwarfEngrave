// Trace a picture into vector outlines: before and after side by side, live as the settings change.

import AppKit
import CAMCore
import EngraveCore
import SwiftUI

struct TraceSheet: View {
    @ObservedObject var model: EditorModel
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var image: CGImage?
    @State private var options = TraceOptions()
    @State private var result: Path2D?
    @State private var tracing = false
    @State private var loadError: String?
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Trace Picture")
                Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(Color.steel).lineLimit(1)
                Spacer()
                if tracing { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider().overlay(Color.line)
            HStack(spacing: 0) {
                pane("Before") {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    } else if let loadError {
                        WarningRow(text: loadError, error: true).padding()
                    } else {
                        ProgressView()
                    }
                }
                Divider().overlay(Color.line)
                pane("After") {
                    if let result, !result.subpaths.isEmpty {
                        TracedPreview(path: result)
                    } else if result != nil {
                        Text("Nothing traced. Try another threshold or turn on Invert.")
                            .font(.system(size: 12)).foregroundStyle(Color.steel).multilineTextAlignment(.center).padding()
                    } else {
                        ProgressView()
                    }
                }
            }
            Divider().overlay(Color.line)
            controls.padding(14)
            Divider().overlay(Color.line)
            HStack {
                if let r = result, let b = r.bounds {
                    Text("\(r.subpaths.count) outline\(r.subpaths.count == 1 ? "" : "s") · \(model.formatLength(b.size.x, digits: 1)) × \(model.formatLength(b.size.y, digits: 1))")
                        .font(.system(size: 12)).foregroundStyle(Color.steel)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).swarfButton(.ghost)
                Button("Add to Design") { add() }
                    .keyboardShortcut(.defaultAction)
                    .swarfButton(.primary)
                    .disabled(result?.subpaths.isEmpty ?? true)
            }
            .padding(14)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color.slate)
        .environment(\.useInches, model.useInches)
        .task {
            let u = url
            do {
                let access = u.startAccessingSecurityScopedResource()
                defer { if access { u.stopAccessingSecurityScopedResource() } }
                let img = try ImageTracer.loadImage(url: u)
                image = img
                let aspect = Double(img.height) / Double(max(img.width, 1))
                let stock = model.sheet.stock
                options.targetWidth = max(10, min(stock.width * 0.8, stock.height * 0.8 / max(aspect, 0.01)).rounded())
                retrace(delay: false)
            } catch {
                loadError = "Couldn't open the picture: \(error.localizedDescription)"
                result = Path2D()
            }
        }
        .onChange(of: options) { _, _ in retrace(delay: true) }
    }

    func pane<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Color.steel)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                slider("Threshold", value: $options.threshold, range: 0.02...0.98, help: "Brightness that separates the artwork from the background")
                slider("Smoothing", value: $options.smoothing, range: 0...1, help: "Rounds off jagged pixel edges")
            }
            GridRow {
                HStack(spacing: 8) {
                    Text("Min detail").font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 78, alignment: .leading)
                    NumberField(value: $options.minDetail, range: 0...50, step: 0.1, width: 56)
                }
                .help("Specks smaller than this are dropped")
                HStack(spacing: 8) {
                    Text("Width").font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 78, alignment: .leading)
                    NumberField(value: $options.targetWidth, range: 1...100000, step: 5, width: 64)
                    Toggle("Invert", isOn: $options.invert).toggleStyle(.checkbox)
                        .help("Trace the light parts instead of the dark")
                }
            }
        }
    }

    func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range).frame(minWidth: 140)
            Text(UnitFormat.trimmed(value.wrappedValue * 100, digits: 0) + "%").font(.mono).foregroundStyle(Color.steel).frame(width: 40, alignment: .trailing)
        }
        .help(help)
    }

    /// Re-traces off the main thread after a short pause; older results are dropped.
    func retrace(delay: Bool) {
        guard let image else { return }
        generation += 1
        let gen = generation, opts = options
        tracing = true
        Task {
            if delay { try? await Task.sleep(for: .milliseconds(180)) }
            guard gen == generation else { return }
            let p = await Task.detached(priority: .userInitiated) { ImageTracer.trace(cgImage: image, options: opts) }.value
            guard gen == generation else { return }
            result = p
            tracing = false
        }
    }

    func add() {
        guard let r = result, !r.subpaths.isEmpty else { return }
        model.placeArtwork([(url.deletingPathExtension().lastPathComponent, r)], at: model.traceDropPoint, actionName: "Trace Picture")
        model.traceDropPoint = nil
        dismiss()
    }
}

/// The traced outlines, filled even-odd, fitted to the pane (Y up).
private struct TracedPreview: View {
    let path: Path2D
    var body: some View {
        Canvas { ctx, size in
            guard let b = path.bounds, b.size.x > 0, b.size.y > 0 else { return }
            let s = min((size.width - 24) / b.size.x, (size.height - 24) / b.size.y)
            let ox = (size.width - b.size.x * s) / 2, oy = (size.height - b.size.y * s) / 2
            let cg = path.cgPath
            var t = CGAffineTransform(translationX: ox, y: size.height - oy)
                .scaledBy(x: s, y: -s)
                .translatedBy(x: -b.min.x, y: -b.min.y)
            guard let mapped = cg.copy(using: &t) else { return }
            let p = Path(mapped)
            ctx.fill(p, with: .color(Color.accent.opacity(0.35)), style: FillStyle(eoFill: true))
            ctx.stroke(p, with: .color(Color.accent), lineWidth: 1)
        }
    }
}

extension Path2D {
    /// The path as a Core Graphics path (same coordinates).
    var cgPath: CGPath {
        let m = CGMutablePath()
        func pt(_ v: V2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
        for sp in subpaths where !sp.segments.isEmpty {
            m.move(to: pt(sp.start))
            for s in sp.segments {
                switch s {
                case .line(let e): m.addLine(to: pt(e))
                case .quad(let c, let e): m.addQuadCurve(to: pt(e), control: pt(c))
                case .cubic(let a, let b, let e): m.addCurve(to: pt(e), control1: pt(a), control2: pt(b))
                }
            }
            if sp.closed { m.closeSubpath() }
        }
        return m
    }
}
