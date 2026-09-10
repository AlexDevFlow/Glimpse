import AppKit
import CoreGraphics

/// Screen Recording is a TCC permission granted per app. Without it every capture fails
/// with an opaque error, so we check up front and explain what to do.
@MainActor
enum Permissions {
    static var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true when capture is allowed. Otherwise triggers the system prompt
    /// (first time only) and shows an alert pointing at System Settings.
    /// runModal keeps pumping the main queue, so a second hot-key press would stack
    /// another alert on top of this one, without limit.
    private static var presenting = 0
    /// True while the permission alert is up; the hot keys consult it.
    static var isPresenting: Bool { presenting > 0 }

    @discardableResult
    static func ensureScreenCapture() -> Bool {
        if hasScreenCapture { return true }
        let granted = CGRequestScreenCaptureAccess()
        if granted { return true }
        guard !isPresenting else { return false }
        presenting += 1
        defer { presenting -= 1 }

        let alert = NSAlert()
        alert.messageText = L("perm.screen.title")
        alert.informativeText = L("perm.screen.body")
        alert.addButton(withTitle: L("perm.open_settings"))
        alert.addButton(withTitle: L("perm.relaunch"))
        alert.addButton(withTitle: L("perm.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    /// Quit and start a fresh process so a newly granted permission takes effect.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as an argument, never interpolated into the script: a
        // bundle living under a directory containing a quote, $ or a backtick would
        // otherwise break the relaunch — or run as a command.
        // Waiting on the pid rather than sleeping a fixed 0.5 s: terminating goes
        // through applicationShouldTerminate, which holds the quit while a recording
        // is being finalised. `open` on a still-running app just activates the old
        // one, which then exits — leaving nothing running at all.
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                          url.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }
}
