import AppKit
import SwiftUI

/// SwiftUI buttons normally swallow the first click on an inactive window as
/// "activate me". For a small utility window that feels broken, so let the
/// first click through.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the Kooha-style main view in a small fixed, transparent-titlebar window.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 250, height: MainView.height),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L("window.main.title")
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            let host = FirstMouseHostingView(rootView: MainView())
            host.sizingOptions = []
            w.contentView = host
            w.setContentSize(CGSize(width: 250, height: MainView.height))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func hide() { window?.orderOut(nil) }
}

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L("window.preferences.title")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PreferencesView())
            // AppKit does not shrink an over-tall window to fit, and this one is not
            // scrollable at its full height — so on a small or heavily scaled display
            // the Shortcuts section at the bottom was clipped away with no way to
            // reach it. Start no taller than the screen allows, and let the user
            // resize.
            let room = (NSScreen.main?.visibleFrame.height ?? 700) - 60
            w.setContentSize(CGSize(width: 480, height: min(700, max(400, room))))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
