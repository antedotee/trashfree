import SwiftUI

@main
struct TrashFreeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // Every launch starts at the disk list, so there is no window state worth
        // restoring, and SwiftUI can hang restoring a window left by a crashed run.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 252)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary has no Info.plist, so it starts as a background app.
        // Inside the .app bundle this call is redundant and hides the window from
        // the accessibility tree, so skip it there.
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
