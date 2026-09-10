import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

// MARK: - Model types

enum OverlayPurpose {
    /// Windows-style snipping: photo/video toggle, rectangle / window / full screen.
    case screenshot
    /// Kooha "Selection" mode for recording: rectangle only, confirm with a button.
    case recordingArea
}

enum SnipMode: String, CaseIterable, Identifiable {
    case rectangle, window, fullscreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: return L("snip.rectangle")
        case .window: return L("snip.window")
        case .fullscreen: return L("snip.fullscreen")
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        }
    }
}

enum SnipKind: String, CaseIterable, Identifiable {
    case photo, video
    var id: String { rawValue }
    var symbol: String { self == .photo ? "camera.fill" : "video.fill" }
    var title: String { self == .photo ? L("snip.photo") : L("snip.video") }
}

struct AreaSelection {
    var screen: NSScreen
    /// Global AppKit coordinates (bottom-left origin).
    var rect: CGRect

    /// Top-left-origin rect relative to the screen's display, as ScreenCaptureKit wants it.
    var rectInDisplaySpace: CGRect {
        CGRect(x: rect.minX - screen.frame.minX,
               y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}

struct WindowInfo {
    let window: SCWindow
    /// Global AppKit coordinates.
    let frame: CGRect
}

enum CaptureTarget {
    case area(AreaSelection)
    case window(WindowInfo)
    case display(NSScreen)
}

struct CaptureOutcome {
    var kind: SnipKind
    var target: CaptureTarget
    /// nil when the user never touched the overlay's timer, which is different from
    /// choosing "No delay": only the former falls back to the Preferences value.
    var delay: Int?
}

// MARK: - Shared state for the toolbar and the overlay views

@MainActor
final class OverlayModel: ObservableObject {
    @Published var purpose: OverlayPurpose = .screenshot
    @Published var kind: SnipKind = .photo
    @Published var mode: SnipMode = .rectangle {
        didSet {
            // Each view drops the previous mode's selection, so the toolbar button
            // must not stay enabled pointing at something that no longer exists.
            // Full screen needs no selection gesture; every other mode does.
            if mode != oldValue { hasSelection = mode == .fullscreen }
        }
    }
    @Published var delay: Int = 0
    /// Set once the user picks from the timer menu.
    @Published var delayChosen = false
    @Published var hasSelection = false

    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
}

// MARK: - Controller

/// Full-screen overlay(s) used both for Windows-style screenshots and for choosing the
/// area to record. One borderless window per screen plus a floating toolbar panel.
@MainActor
final class CaptureOverlay {
    static let shared = CaptureOverlay()

    let model = OverlayModel()
    private var windows: [OverlayWindow] = []
    private var toolbar: NSPanel?
    private var continuation: CheckedContinuation<CaptureOutcome?, Never>?
    /// finish() can be reached before present() suspends — the screen-change observer
    /// fires on the main queue during the window-list fetch. Remembering the outcome
    /// is what stops present() from installing a continuation nobody will resume.
    private var earlyFinish: CaptureOutcome??
    private var keyMonitor: Any?
    private var screenObserver: Any?
    private(set) var isActive = false
    private var windowList: [WindowInfo] = []

    private init() {
        model.onConfirm = { [weak self] in self?.confirmCurrentSelection() }
        model.onCancel = { [weak self] in self?.finish(nil) }
    }

    /// Kooha-style area selection for the "Selection" capture mode.
    func selectArea(initial: CGRect?) async -> AreaSelection? {
        guard let outcome = await present(purpose: .recordingArea, initialSelection: initial),
              case .area(let sel) = outcome.target else { return nil }
        return sel
    }

    /// The snipping-tool flow. Returns nil when cancelled.
    func present(purpose: OverlayPurpose, initialSelection: CGRect? = nil) async -> CaptureOutcome? {
        // Refuse rather than replace: a second overlay raised while the first was
        // still setting up used to orphan its continuation, leave a stray toolbar on
        // screen, and wedge the screenshot flow for the rest of the session.
        if isActive { return nil }
        isActive = true
        earlyFinish = nil
        model.purpose = purpose
        model.kind = .photo
        model.mode = .rectangle
        model.delay = 0
        model.delayChosen = false
        model.hasSelection = false

        windowList = await Self.fetchWindows()

        // Hide our own windows so they don't get in the way of the selection.
        for w in [MainWindowController.shared.window, PreferencesWindowController.shared.window].compactMap({ $0 }) where w.isVisible {
            w.orderOut(nil)
            hiddenWindows.append(w)
        }
        CapturePreviewPanel.shared.dismiss()

        let mouse = NSEvent.mouseLocation
        var keyWindow: OverlayWindow?
        var restoredSelection = false
        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen, model: model, windows: windowList,
                                  onSelection: { [weak self] sel in self?.handleSelection(sel) },
                                  onWindowPick: { [weak self] info in self?.handleWindowPick(info) },
                                  onDisplayPick: { [weak self] scr in self?.handleDisplayPick(scr) },
                                  onCancel: { [weak self] in self?.finish(nil) })
            if let initial = initialSelection, !restoredSelection, screen.frame.intersects(initial) {
                // Only one screen may hold it: two live selections and the confirm
                // step silently picks whichever screen comes first.
                w.overlayView.setInitialSelection(initial.intersection(screen.frame))
                // Announce it only if what survived clamping and even-pixel
                // alignment is something the confirm step can actually use. A stored
                // selection overlapping the new arrangement by under a point aligns
                // down to zero width, and Confirm then did nothing at all — leaving
                // the dimming overlay up with no way out but Escape.
                if w.overlayView.currentSelection != nil {
                    model.hasSelection = true
                    restoredSelection = true
                }
            }
            windows.append(w)
            w.orderFrontRegardless()
            if screen.frame.contains(mouse) { keyWindow = w }
        }
        NSApp.activate(ignoringOtherApps: true)
        (keyWindow ?? windows.first)?.makeKeyAndOrderFront(nil)

        guard let toolbarScreen = keyWindow?.overlayScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            finish(nil)
            return nil
        }
        showToolbar(on: toolbarScreen)

        // The overlay windows and the window list are a snapshot of the current
        // arrangement; plugging or unplugging a display invalidates all of it.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(nil) }
            }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.keyCode {
            case 53: self.finish(nil); return nil // Escape
            case 36, 76: // Return / keypad Enter
                if self.model.hasSelection { self.confirmCurrentSelection(); return nil }
                return event
            default: return event
            }
        }

        if let early = earlyFinish {
            earlyFinish = nil
            return early
        }
        return await withCheckedContinuation { cont in continuation = cont }
    }

    private var hiddenWindows: [NSWindow] = []

    private func finish(_ outcome: CaptureOutcome?) {
        guard isActive else { return }
        isActive = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        toolbarSizeObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        // Closing, not just ordering out: ordered-out windows stay in AppKit's window
        // list, so every previous session's views kept observing the shared model.
        for w in windows {
            w.overlayView.teardown()
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        for w in hiddenWindows { w.orderFront(nil) }
        hiddenWindows.removeAll()
        windowList.removeAll()   // a snapshot of every on-screen window, held between sessions
        let cont = continuation
        continuation = nil
        if cont == nil { earlyFinish = .some(outcome) }
        cont?.resume(returning: outcome)
    }

    // MARK: Events from the overlay views

    private func handleSelection(_ sel: AreaSelection) {
        // Keep the selection on screen; the user confirms with the toolbar button or Return.
        for w in windows where w.overlayScreen != sel.screen { w.overlayView.clearSelection() }
        model.hasSelection = true
    }

    private func handleWindowPick(_ info: WindowInfo) {
        finish(CaptureOutcome(kind: model.kind, target: .window(info), delay: model.delayChosen ? model.delay : nil))
    }

    private func handleDisplayPick(_ screen: NSScreen) {
        finish(CaptureOutcome(kind: model.kind, target: .display(screen), delay: model.delayChosen ? model.delay : nil))
    }

    private func confirmCurrentSelection() {
        let kind: SnipKind = model.purpose == .recordingArea ? .video : model.kind
        switch model.mode {
        case .rectangle:
            for w in windows {
                if let sel = w.overlayView.currentSelection {
                    finish(CaptureOutcome(kind: kind, target: .area(sel), delay: model.delayChosen ? model.delay : nil))
                    return
                }
            }
        case .window:
            if let info = windows.compactMap({ $0.overlayView.hoverWindow }).first {
                finish(CaptureOutcome(kind: kind, target: .window(info), delay: model.delayChosen ? model.delay : nil))
            }
        case .fullscreen:
            let mouse = NSEvent.mouseLocation
            let screen = windows.first { $0.overlayScreen.frame.contains(mouse) }?.overlayScreen
                ?? windows.first?.overlayScreen
            if let screen { finish(CaptureOutcome(kind: kind, target: .display(screen), delay: model.delayChosen ? model.delay : nil)) }
        }
    }

    // MARK: Toolbar

    private func showToolbar(on screen: NSScreen) {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: OverlayWindow.level.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        // finish() calls close(); without this the default releases it as well.
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        let host = NSHostingView(rootView: OverlayToolbar(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        let size = host.fittingSize
        let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.visibleFrame.maxY - size.height - 16)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        toolbar = panel
        toolbarScreen = screen
        toolbarSizeObserver = model.$kind.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayoutToolbar() }
        }
    }

    private var toolbarScreen: NSScreen?
    private var toolbarSizeObserver: Any?

    private func relayoutToolbar() {
        guard let toolbar, let host = toolbar.contentView as? NSHostingView<OverlayToolbar>, let screen = toolbarScreen else { return }
        let size = host.fittingSize
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: toolbar.frame.maxY - size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toolbar.animator().setFrame(CGRect(origin: origin, size: size), display: true)
        }
    }

    // MARK: Window list

    private static func fetchWindows() async -> [WindowInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return [] }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let me = getpid()

        // CGWindowList is front-to-back, which we need for hit testing.
        var ordered: [WindowInfo] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let win = byID[id] else { continue }
            let frame = win.frame
            guard frame.width >= 40, frame.height >= 40 else { continue }
            ordered.append(WindowInfo(window: win, frame: ScreenSpace.toAppKit(frame)))
        }
        return ordered
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    static let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    let overlayView: OverlayView
    let overlayScreen: NSScreen

    init(screen: NSScreen, model: OverlayModel, windows: [WindowInfo],
         onSelection: @escaping (AreaSelection) -> Void,
         onWindowPick: @escaping (WindowInfo) -> Void,
         onDisplayPick: @escaping (NSScreen) -> Void,
         onCancel: @escaping () -> Void) {
        overlayScreen = screen
        overlayView = OverlayView(screen: screen, model: model, windows: windows)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlayView.onSelection = onSelection
        overlayView.onWindowPick = onWindowPick
        overlayView.onDisplayPick = onDisplayPick
        overlayView.onCancel = onCancel
        level = Self.level
        isOpaque = false
        // Like the toolbar, the HUD and the preview card. Before macOS 15.2 the
        // content filter is not rebuilt to exclude this app mid-recording, so
        // without this the overlay's dim and its hint text burn into the video.
        sharingType = .none
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay view (drawing + mouse handling)

final class OverlayView: NSView {
    private let screen: NSScreen
    private let model: OverlayModel
    private let windows: [WindowInfo]
    private var cancellable: AnyCancellable?

    var onSelection: ((AreaSelection) -> Void)?
    var onWindowPick: ((WindowInfo) -> Void)?
    var onDisplayPick: ((NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var selection: CGRect?        // view coordinates
    private(set) var hoverWindow: WindowInfo?
    private var mouseInside = false
    private var mousePoint: CGPoint = .zero

    init(screen: NSScreen, model: OverlayModel, windows: [WindowInfo]) {
        self.screen = screen
        self.model = model
        self.windows = windows
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.modeChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.mode == .rectangle ? .crosshair : .pointingHand)
    }

    var currentSelection: AreaSelection? {
        guard let selection, selection.width > 1, selection.height > 1 else { return nil }
        return AreaSelection(screen: screen, rect: toGlobal(selection))
    }

    func setInitialSelection(_ global: CGRect) {
        // Even-pixel alignment can take a sliver down to zero. Storing it anyway drew
        // a hairline hole in the dimming layer that no confirm step would accept, and
        // let the loop install the same selection on a second screen as well.
        let aligned = toLocal(global).evenPixelAligned
        guard aligned.width > 1, aligned.height > 1 else { return }
        selection = aligned
        needsDisplay = true
    }

    func clearSelection() {
        selection = nil
        needsDisplay = true
    }

    /// Drops the subscription to the shared model before the window goes away.
    func teardown() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func modeChanged() {
        if model.mode != .rectangle { selection = nil }
        if model.mode != .window { hoverWindow = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func toGlobal(_ r: CGRect) -> CGRect { r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
    private func toLocal(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { mouseInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false; hoverWindow = nil; needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        mouseInside = true
        if model.mode == .window {
            let global = toGlobal(CGRect(origin: mousePoint, size: .zero)).origin
            let hit = windows.first { $0.frame.contains(global) }
            if hit?.window.windowID != hoverWindow?.window.windowID {
                hoverWindow = hit
                model.hasSelection = hit != nil
            }
        } else if model.mode == .fullscreen, !model.hasSelection {
            model.hasSelection = true
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        switch model.mode {
        case .rectangle:
            dragStart = p
            selection = nil
            model.hasSelection = false
        case .window:
            if let hoverWindow { onWindowPick?(hoverWindow) }
        case .fullscreen:
            onDisplayPick?(screen)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                       width: abs(p.x - start.x), height: abs(p.y - start.y))
        selection = r.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if let r = selection?.evenPixelAligned, r.width >= 8, r.height >= 8 {
            selection = r
            onSelection?(AreaSelection(screen: screen, rect: toGlobal(r)))
        } else {
            selection = nil
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dim = NSColor.black.withAlphaComponent(0.35)

        var hole: CGRect? = nil
        switch model.mode {
        case .rectangle: hole = selection
        case .window: hole = hoverWindow.map { toLocal($0.frame).intersection(bounds) }
        case .fullscreen: hole = mouseInside ? bounds : nil
        }

        ctx.saveGState()
        if let hole, !hole.isEmpty {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(hole)
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
        }
        ctx.setFillColor(dim.cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        if let hole, !hole.isEmpty {
            let accent = NSColor.controlAccentColor
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(hole.insetBy(dx: -1, dy: -1))
            if model.mode == .fullscreen {
                ctx.setLineWidth(6)
                ctx.stroke(bounds.insetBy(dx: 3, dy: 3))
            }
            drawSizeLabel(for: hole, in: ctx)
        }

        // Crosshair while picking a rectangle.
        if model.mode == .rectangle, mouseInside, dragStart == nil {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: mousePoint.x + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: mousePoint.x + 0.5, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: mousePoint.y + 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: mousePoint.y + 0.5))
            ctx.strokePath()
        }

        // Hint when nothing is selected yet.
        if hole == nil || hole!.isEmpty {
            let hint: String
            switch model.mode {
            case .rectangle: hint = L(model.purpose == .recordingArea ? "overlay.hint.record_area" : "overlay.hint.rectangle")
            case .window: hint = L("overlay.hint.window")
            case .fullscreen: hint = L("overlay.hint.fullscreen")
            }
            drawHint(L("overlay.hint.format", hint, L("overlay.hint.escape")))
        }
    }

    private func drawSizeLabel(for rect: CGRect, in ctx: CGContext) {
        let scale = screen.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = CGPoint(x: rect.maxX - size.width - 8, y: rect.minY - size.height - 10)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        if origin.x < 4 { origin.x = rect.minX + 6 }
        let bg = CGRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.42)
        let bg = CGRect(x: origin.x - 14, y: origin.y - 8, width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Toolbar (SwiftUI)

struct OverlayToolbar: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings = AppSettings.shared
    /// A second recording cannot start while one is running, so the video switch
    /// would just close the overlay and do nothing.
    @ObservedObject var controller = RecordingController.shared
    @Namespace private var highlight
    private let motion = Animation.snappy(duration: 0.25)

    var body: some View {
        HStack(spacing: 10) {
            if model.purpose == .screenshot {
                // Photo / video switch, like the Snipping Tool.
                HStack(spacing: 2) {
                    ForEach(SnipKind.allCases) { kind in
                        ToolbarToggle(symbol: kind.symbol, title: kind.title, isOn: model.kind == kind,
                                      highlight: highlight, group: "kind") {
                            withAnimation(motion) { model.kind = kind }
                        }
                        .disabled(kind == .video && controller.state.isBusy)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))

                Divider().frame(height: 22)

                HStack(spacing: 2) {
                    ForEach(SnipMode.allCases) { mode in
                        ToolbarToggle(symbol: mode.symbol, title: mode.title, isOn: model.mode == mode,
                                      highlight: highlight, group: "mode") {
                            withAnimation(motion) { model.mode = mode }
                        }
                    }
                }

                if model.kind == .video {
                    Divider().frame(height: 22)
                    RecordingToggles(settings: settings, iconSize: 15)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Divider().frame(height: 22)

                Menu {
                    ForEach([0, 3, 5, 10], id: \.self) { s in
                        Button {
                            model.delay = s
                            model.delayChosen = true
                        } label: {
                            if model.delay == s { Label(delayTitle(s), systemImage: "checkmark") } else { Text(delayTitle(s)) }
                        }
                    }
                } label: {
                    Image(systemName: model.delay == 0 ? "timer" : "timer.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("overlay.delay.help"))
                .accessibilityLabel(L("overlay.delay.help"))

                Divider().frame(height: 22)

                Button {
                    model.onConfirm()
                } label: {
                    Label(model.kind == .photo ? L("overlay.capture") : L("snip.video"),
                          systemImage: model.kind == .photo ? "camera.fill" : "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(model.kind == .photo ? .accentColor : .red)
                .disabled(!model.hasSelection)
                .animation(motion, value: model.hasSelection)
                .help(L(model.kind == .photo ? "overlay.capture.help" : "overlay.record.help"))
                .accessibilityLabel(L(model.kind == .photo ? "overlay.capture" : "main.start_recording.help"))
            } else {
                Label(L("overlay.select_area"), systemImage: "dot.viewfinder")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.leading, 6)

                Divider().frame(height: 22)
                RecordingToggles(settings: settings, iconSize: 15)
                Divider().frame(height: 22)

                Button(L("snip.video")) { model.onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.hasSelection)
                    .keyboardShortcut(.defaultAction)
            }

            Divider().frame(height: 22)

            Button { model.onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(L("overlay.cancel.help"))
            .accessibilityLabel(L("main.cancel"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.14)))
        .fixedSize()
    }

    private func delayTitle(_ s: Int) -> String { s == 0 ? L("overlay.delay.none") : L("overlay.delay.seconds", s) }
}

/// Desktop audio / microphone / pointer, bound to the shared settings. Used by the
/// overlay bar (video mode) and by the recording HUD.
struct RecordingToggles: View {
    @ObservedObject var settings: AppSettings
    var iconSize: CGFloat = 15
    var microphoneEnabled = true

    var body: some View {
        HStack(spacing: 2) {
            ToolbarToggle(symbol: settings.recordDesktopAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          title: L(settings.recordDesktopAudio ? "toggle.desktop_audio.disable" : "toggle.desktop_audio.enable"),
                          isOn: settings.recordDesktopAudio, iconSize: iconSize) { withAnimation(.snappy(duration: 0.2)) { settings.recordDesktopAudio.toggle() } }
            ToolbarToggle(symbol: settings.recordMicrophone ? "mic.fill" : "mic.slash.fill",
                          title: microphoneEnabled
                              ? L(settings.recordMicrophone ? "toggle.microphone.disable" : "toggle.microphone.enable")
                              : L("toggle.microphone.locked"),
                          isOn: settings.recordMicrophone, iconSize: iconSize) { withAnimation(.snappy(duration: 0.2)) { settings.recordMicrophone.toggle() } }
                .disabled(!microphoneEnabled)
                .opacity(microphoneEnabled ? 1 : 0.4)
            ToolbarToggle(symbol: settings.showPointer ? "cursorarrow" : "cursorarrow.slash",
                          title: L(settings.showPointer ? "toggle.pointer.hide" : "toggle.pointer.show"),
                          isOn: settings.showPointer, iconSize: iconSize) { withAnimation(.snappy(duration: 0.2)) { settings.showPointer.toggle() } }
        }
    }
}

struct ToolbarToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var iconSize: CGFloat = 15
    /// When given, the highlight slides between the buttons of the same group.
    var highlight: Namespace.ID? = nil
    var group: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 30)
                .foregroundStyle(isOn ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
                .background {
                    if isOn {
                        let shape = RoundedRectangle(cornerRadius: 7).fill(Color.accentColor)
                        if let highlight {
                            shape.matchedGeometryEffect(id: "highlight-\(group)", in: highlight)
                        } else {
                            shape
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isOn)
        .help(title)
        .accessibilityLabel(title)
    }
}
