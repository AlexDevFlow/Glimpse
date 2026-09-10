import AppKit

/// Where a capture ends up: the folder from Preferences, or a Save panel when the
/// "ask where to save" switch is on.
@MainActor
enum SaveDestination {
    /// Opens the folder in the Finder, creating it first — the defaults
    /// (~/Movies, ~/Pictures/Screenshots) may not exist yet on a fresh Mac.
    static func openInFinder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Both calls used to be discarded, so a folder on an ejected volume made the
        // menu item do nothing at all, with no way to tell it apart from a hang.
        guard !NSWorkspace.shared.open(folder) else { return }
        Log.write("could not open the save folder in the Finder")
        let alert = NSAlert()
        alert.messageText = L("error.folder_unavailable")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("common.ok"))
        // Counted like a Save panel: the nested run loop keeps pumping the main
        // queue, so a hot key would otherwise fire on top of this alert.
        presenting += 1
        defer { presenting -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// True while a Save panel is up. `runModal` spins a nested run loop that keeps
    /// pumping the main queue, so hot keys would otherwise still fire and put the
    /// capture overlay on top of the modal panel.
    private static var presenting = 0
    static var isPresenting: Bool { presenting > 0 }

    /// A folder chooser, and a runModal that counts as "a modal is up" so the hot
    /// keys cannot drop a full-screen overlay on top of it.
    static func folderChooser() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel
    }

    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        presenting += 1
        defer { presenting -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal()
    }

    /// Save panel seeded with the folder and file name the app would have used.
    /// Returns nil when the user cancels.
    static func ask(name: String, in folder: URL) -> URL? {
        // A counter, not a flag: runModal pumps the main queue, so a second panel
        // can open inside the first and its exit must not clear the outer one.
        presenting += 1
        defer { presenting -= 1 }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        // The app has no Dock icon, so the panel would otherwise open behind whatever
        // the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
