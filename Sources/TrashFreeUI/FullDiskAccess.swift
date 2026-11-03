import AppKit
import Darwin

/// Full Disk Access: whether the app has it, and the ways to get it.
///
/// Without it, macOS hides other apps' data, Mail, Messages, Safari, and system folders
/// from the scan (they end up in hidden space), and asks separately for Desktop,
/// Documents, Downloads, and removable volumes. With it, the scan sees everything and
/// macOS asks nothing.
enum FullDiskAccess {
    /// Files that only a process with Full Disk Access can open. Opening one is the
    /// standard probe: it never shows a prompt, and the error says which case we are in.
    private static let probes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
        ]
    }()

    static var isGranted: Bool {
        for path in probes {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
            // ENOENT and the like: this probe tells us nothing, try the next.
        }
        return false
    }

    /// System Settings > Privacy & Security > Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// The app bundle, when running as one. A bare `swift run` binary has no bundle to
    /// add to the list; Full Disk Access then belongs to the terminal that runs it.
    static var appBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// Opens the settings pane and shows the app in Finder, so it can be dragged into
    /// the list if macOS has not listed it yet.
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
        if let appBundle {
            NSWorkspace.shared.activateFileViewerSelecting([appBundle])
        }
    }

    /// Quits and opens the app again. macOS applies a new Full Disk Access grant to
    /// processes started after it, so a running app may not see the grant until then.
    static func relaunch() {
        guard let appBundle else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path travels as $0 rather than inside the script, so no quoting can break.
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", appBundle.path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
