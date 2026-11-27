// SwarfEngrave: design signs and carvings, and carve them on a hobby CNC.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a normal app when launched from `swift run` as well as from the bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

@main
struct SwarfEngraveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: EngraveFile()) { config in
            ContentView(file: config.$document, fileURL: config.fileURL)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(.dark)
                .tint(Color.accent)
                .background(Color.obsidian)
                .containerBackground(Color.obsidian, for: .window)
        }
        .commands { EngraveCommands() }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
                .tint(Color.accent)
        }
    }
}
