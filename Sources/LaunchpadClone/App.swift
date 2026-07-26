import SwiftUI
import AppKit

@main
struct LaunchpadCloneApp: App {
    init() {
        // Running as a plain SPM executable (no .app bundle), we still want a
        // real, focused GUI app rather than a background process.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Launchpad") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
    }
}
