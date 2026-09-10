import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Windows-style screenshot flow: overlay → capture → save + clipboard → preview.
/// Video outcomes from the same overlay are handed to the RecordingController.
@MainActor
final class ScreenshotController: ObservableObject {
    static let shared = ScreenshotController()

    /// Seconds left before a delayed shot. Recordings get a countdown page and a
    /// HUD; without this a delayed screenshot was ten seconds of nothing at all.
    @Published private(set) var countdown: Int?

    private let settings = AppSettings.shared
    /// Published so the record item and the shutter buttons can disable themselves
    /// while a capture is in flight. It used to be a plain var, so every one of them
    /// stayed enabled and did nothing when pressed.
    @Published private(set) var running = false
    private var flow: Task<Void, Never>?
    private static let shutterSound: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Sounds/Pop.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let s = NSSound(contentsOfFile: path, byReference: true) { return s }
        }
        return NSSound(named: "Pop")
    }()

    private init() {}

    /// Hotkey / menu entry point.
    func start() {
        // First, before any refusal: a second press during the countdown calls it
        // off, and that must keep working even when something else would refuse a
        // NEW capture — otherwise an alert on screen makes a running countdown
        // uncancellable and the shot fires over it.
        if countdown != nil { cancelCountdown(); return }
        if CaptureOverlay.shared.isActive { return }
        // Guards that used to live only in the hot key wrapper, so the menu item and
        // the main window's camera button walked straight past them.
        if SaveDestination.isPresenting || Permissions.isPresenting { return }
        // The overlay covers the menu bar and the recording HUD, which between them
        // are the only ways to stop a recording — raising it over a live one left
        // the user with a running recording and no visible way out.
        if RecordingController.shared.state.isBusy {
            Log.write("screenshot refused: a recording is in progress")
            return
        }
        guard !running else { return }
        guard Permissions.ensureScreenCapture() else { return }
        running = true
        flow = Task {
            defer { running = false; flow = nil }
            guard let outcome = await CaptureOverlay.shared.present(purpose: .screenshot) else { return }
            switch outcome.kind {
            case .photo:
                await takeScreenshot(outcome)
            case .video:
                await startRecording(outcome)
            }
        }
    }

    /// True while a delayed shot is counting down and can still be called off.
    var isCountingDown: Bool { countdown != nil }

    /// True for the whole capture flow, including the stretch after the overlay has
    /// closed while its outcome is still on its way to a controller. `isActive` on
    /// the overlay goes false at the start of that stretch, which left a gap in
    /// which a second flow could be started and the first one's work discarded.
    var isBusy: Bool { running }

    /// Quitting waits for this the way it waits for a recording flush: a capture
    /// sitting on its Save panel is unwritten work. Bounded, because a logout that
    /// never gets an answer is worse than a lost screenshot.
    func waitWhileBusy() async {
        var ticks = 0
        while running, ticks < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            ticks += 1
        }
        if running { Log.write("quit: gave up waiting for a screenshot to be written") }
    }

    func cancelCountdown() {
        guard countdown != nil else { return }
        flow?.cancel()
        countdown = nil
    }

    // MARK: Screenshot

    private func takeScreenshot(_ outcome: CaptureOutcome) async {
        let shotDelay = outcome.delay ?? 0
        if shotDelay > 0 {
            for remaining in stride(from: shotDelay, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                // Cancelled by a second press of the shortcut. There is no Escape
                // here: the overlay's key monitor is gone by the time this runs.
                if Task.isCancelled { countdown = nil; return }
            }
            countdown = nil
        } else {
            // Give the window server a beat to drop our overlay before we grab pixels.
            try? await Task.sleep(for: .milliseconds(60))
        }

        do {
            let image = try await capture(outcome.target, showsCursor: settings.screenshotShowsPointer)
            var copiedToClipboard = false
            if settings.screenshotCopiesToClipboard {
                // PNG first: TIFF alone is what NSImage writes, and several editors
                // accept only PNG. TIFF is uncompressed — measured at 33 MB against
                // 145 KB of PNG for one 4K capture — so it is offered lazily and only
                // materialises for an app that asks for it.
                let item = NSPasteboardItem()
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
                let provider = TIFFProvider(bitmap: bitmap)
                item.setDataProvider(provider, forTypes: [.tiff])
                // An item with no types would clear the clipboard and write nothing.
                if item.types.isEmpty {
                    Log.write("screenshot could not be encoded for the clipboard")
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    copiedToClipboard = pb.writeObjects([item])
                }
            }
            if settings.screenshotPlaysSound { Self.shutterSound?.play() }
            // Nothing is written when the Save panel is dismissed — the clipboard copy
            // above already happened, which is often the whole point of the shot.
            guard let url = try save(image) else { return }
            if settings.showPreviewAfterCapture {
                let subtitle = L(copiedToClipboard ? "preview.size_copied" : "preview.size",
                                 image.width, image.height)
                CapturePreviewPanel.shared.show(image: NSImage(cgImage: image, size: .zero),
                                                title: L("preview.screenshot_saved"), subtitle: subtitle, fileURL: url)
            }
        } catch {
            RecordingController.shared.lastError = error.localizedDescription
            MainWindowController.shared.show()
        }
    }

    private func capture(_ target: CaptureTarget, showsCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = content.currentApplication.map { [$0] } ?? []
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.captureResolution = .best

        let filter: SCContentFilter
        switch target {
        case .area(let sel):
            guard let display = content.display(for: sel.screen) else { throw CaptureError.displayNotFound }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            // The same guards the recorder applies to the same kind of stale
            // selection: the delay is up to 10 s, in which the display can be
            // resized or rearranged, and SCK validates none of this — it accepts a
            // negative width and hands back a wrong-content image with no error.
            let scale = CGFloat(filter.pointPixelScale)
            let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
            let clamped = sel.rectInDisplaySpace.intersection(bounds)
            let rect: CGRect
            if clamped.isNull || clamped.isEmpty {
                Log.write("selection no longer overlaps the display; capturing all of it")
                rect = bounds
            } else {
                rect = clamped
                config.sourceRect = clamped
            }
            config.width = max(2, Int((rect.width * scale).rounded()))
            config.height = max(2, Int((rect.height * scale).rounded()))
        case .display(let screen):
            guard let display = content.display(for: screen) else { throw CaptureError.displayNotFound }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
        case .window(let info):
            filter = SCContentFilter(desktopIndependentWindow: info.window)
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(info.window.frame.width * scale)
            config.height = Int(info.window.frame.height * scale)
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Returns nil when "ask where to save" is on and the Save panel was cancelled.
    private func save(_ image: CGImage) throws -> URL? {
        let format = settings.screenshotFormat
        let name = timestampedFileName(prefix: "Screenshot", ext: format.fileExtension)
        let url: URL
        if settings.askWhereToSave {
            guard let chosen = SaveDestination.ask(name: name, in: settings.screenshotsFolder) else { return nil }
            url = chosen
        } else {
            let folder = settings.screenshotsFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = uniqueURL(folder.appendingPathComponent(name))
        }
        let type: UTType = format == .png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CaptureError.saveFailed
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.saveFailed }
        return url
    }

    // MARK: Video from the overlay

    private func startRecording(_ outcome: CaptureOutcome) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let me = content.currentApplication.map { [$0] } ?? []
            let source: RecordingSource
            switch outcome.target {
            case .area(let sel):
                guard let display = content.display(for: sel.screen) else { throw CaptureError.displayNotFound }
                settings.lastSelection = sel.rect
                source = RecordingSource(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                                         sourceRect: sel.rectInDisplaySpace, usesSystemPicker: false,
                                         delay: outcome.delay)
            case .display(let screen):
                guard let display = content.display(for: screen) else { throw CaptureError.displayNotFound }
                source = RecordingSource(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                                         sourceRect: nil, usesSystemPicker: false,
                                         delay: outcome.delay)
            case .window(let info):
                source = RecordingSource(filter: SCContentFilter(desktopIndependentWindow: info.window),
                                         sourceRect: nil, usesSystemPicker: false,
                                         delay: outcome.delay)
            }
            // The delay is carried on the source: the controller runs it as a visible
            // countdown, and applying the Preferences delay on top would add to it.
            RecordingController.shared.record(source: source)
        } catch {
            RecordingController.shared.lastError = error.localizedDescription
            MainWindowController.shared.show()
        }
    }
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return L("error.display_not_found")
        case .saveFailed: return L("error.screenshot_save")
        }
    }
}

/// Renders TIFF only if something on the pasteboard actually asks for it. The
/// pasteboard retains the provider for as long as the item lives.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let bitmap: NSBitmapImageRep
    init(bitmap: NSBitmapImageRep) { self.bitmap = bitmap }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = bitmap.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}
