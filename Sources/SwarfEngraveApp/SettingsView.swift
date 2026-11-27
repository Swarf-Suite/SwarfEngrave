// The Settings window: where SwarfGRBL is, and the default units for new windows.

import CAMCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(GCodeHub.urlKey) private var hubURL = GCodeHub.defaultURL
    @AppStorage("defaultUseInches") private var defaultInches = false
    @State private var testing = false
    @State private var testResult: (text: String, ok: Bool)?

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $hubURL, prompt: Text(GCodeHub.defaultURL))
                    .font(.mono)
                HStack {
                    Button("Test Connection") { test() }.disabled(testing)
                    Button("Use Default") { hubURL = GCodeHub.defaultURL }.disabled(hubURL == GCodeHub.defaultURL)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? Color.ok : Color.danger)
                            .font(.system(size: 12))
                    }
                }
            } header: {
                Text("SwarfGRBL")
            } footer: {
                Text("Send to SwarfGRBL posts the G-code to this address. SwarfGRBL shows it when you open its file list.")
                    .foregroundStyle(Color.steel)
            }
            Section("Units") {
                Picker("New windows use", selection: $defaultInches) {
                    Text("Millimetres").tag(false)
                    Text("Inches").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Checks that something answers at the address.
    func test() {
        testing = true
        testResult = nil
        let address = GCodeHub.resolvedAddress(hubURL)
        Task {
            defer { testing = false }
            guard let url = URL(string: address) else {
                testResult = ("Not a valid address", false)
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            do {
                _ = try await URLSession.shared.data(for: req)
                testResult = ("SwarfGRBL answered", true)
            } catch {
                testResult = ("No answer: \(error.localizedDescription)", false)
            }
        }
    }
}
