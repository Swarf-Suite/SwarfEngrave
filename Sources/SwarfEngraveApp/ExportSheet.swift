// Export G-code: one file per bit with a preview, saved to disk or sent to SwarfGRBL.

import AppKit
import CAMCore
import EngraveCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var files: [GCodeHub.File] = []
    @State private var loading = true
    @State private var picked = 0
    @State private var sending = false
    @State private var status: (text: String, error: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Export G-code")
                Spacer()
                if let t = model.estimatedSeconds {
                    Label("~" + formatDuration(t), systemImage: "clock").font(.system(size: 12)).foregroundStyle(Color.steel)
                }
            }
            .padding(14)
            Divider().overlay(Color.line)
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Making toolpaths…").font(.system(size: 12)).foregroundStyle(Color.steel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(Color.warn)
                    Text("Nothing to carve").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.offwhite)
                    Text("Give at least one object a cut other than Guide, then try again.")
                        .font(.system(size: 12)).foregroundStyle(Color.steel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { picked }, set: { picked = $0 ?? 0 })) {
                        ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(f.name, systemImage: "doc.text").font(.system(size: 12)).lineLimit(1)
                                Text("\(f.content.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                                    .font(.system(size: 10.5)).foregroundStyle(Color.steel)
                            }
                            .tag(i)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(Color.slate)
                    .frame(width: 220)
                    Divider().overlay(Color.line)
                    ScrollView([.vertical, .horizontal]) {
                        Text(preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.offwhite)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(Color.obsidian)
                }
            }
            Divider().overlay(Color.line)
            HStack(spacing: 10) {
                if let status {
                    Label(status.text, systemImage: status.error ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(status.error ? Color.danger : Color.ok)
                        .lineLimit(2)
                } else {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") for \(model.doc.machine.name)")
                        .font(.system(size: 12)).foregroundStyle(Color.steel)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).swarfButton(.ghost)
                Button { save() } label: { Label(files.count > 1 ? "Save to Folder…" : "Save…", systemImage: "square.and.arrow.down") }
                    .swarfButton(.normal)
                    .disabled(files.isEmpty)
                Button { send() } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Send to SwarfGRBL", systemImage: "paperplane.fill") }
                }
                .swarfButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || sending)
                .help("Send to SwarfGRBL at \(GCodeHub.address)")
            }
            .padding(14)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color.slate)
        .task {
            files = await model.gcodeFiles()
            loading = false
            if model.sendWhenExportOpens {
                model.sendWhenExportOpens = false
                if !files.isEmpty { send() }
            }
        }
    }

    var preview: String {
        guard files.indices.contains(picked) else { return "" }
        let c = files[picked].content
        // Long programs: show the start; the file itself is complete.
        let limit = 4000
        let lines = c.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > limit ? lines.prefix(limit).joined(separator: "\n") + "\n… \(lines.count - limit) more lines" : c
    }

    func save() {
        if files.count == 1, let f = files.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = f.name
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write([f], to: nil, single: url)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose a folder for the \(files.count) G-code files."
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            write(files, to: dir, single: nil)
        }
    }

    func write(_ fs: [GCodeHub.File], to dir: URL?, single: URL?) {
        do {
            if let single, let f = fs.first {
                try f.content.write(to: single, atomically: true, encoding: .utf8)
                status = ("Saved \(single.lastPathComponent)", false)
            } else if let dir {
                for f in fs { try f.content.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
                status = ("Saved \(fs.count) files to \(dir.lastPathComponent)", false)
            }
        } catch {
            status = (error.localizedDescription, true)
        }
    }

    func send() {
        sending = true
        status = nil
        let fs = files, job = model.jobName
        Task {
            do {
                let n = try await GCodeHub.send(fs, source: "SwarfEngrave", group: job)
                status = ("Sent \(n) file\(n == 1 ? "" : "s") to SwarfGRBL", false)
            } catch {
                status = ("Couldn't reach SwarfGRBL at \(GCodeHub.address): \(error.localizedDescription)", true)
            }
            sending = false
        }
    }
}
