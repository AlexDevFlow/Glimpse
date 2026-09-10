import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingState: Equatable {
    case idle
    case selectingSource
    case delayed(secondsLeft: Int)
    case recording(duration: TimeInterval)
    case flushing

    var isBusy: Bool { self != .idle }
    var isRecording: Bool { if case .recording = self { return true } else { return false } }
    var isCountingDown: Bool { if case .delayed = self { return true } else { return false } }
}

/// What to record, resolved before the countdown starts.
struct RecordingSource {
    var filter: SCContentFilter
    var sourceRect: CGRect?
    var usesSystemPicker: Bool
    /// Delay chosen in the capture overlay. nil means "use the Preferences value";
    /// without this the overlay timer and the Preferences one would both run.
    var delay: Int?
}

/// Kooha's `Recording` state machine: source selection → delay → recording → flushing.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var state: RecordingState = .idle
    /// Kept beside `state` rather than inside it: a paused recording is still a
    /// recording as far as the HUD, the ticker and the menu bar are concerned.
    @Published private(set) var isPaused = false
    @Published var lastError: String? {
        didSet { if let lastError { Log.write("error: \(lastError)") } }
    }

    private let settings = AppSettings.shared
    private let recorder = ScreenRecorder()
    private var delayTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var currentSourceUsesPicker = false
    private var cancellables = Set<AnyCancellable>()
    private var mainWindowWasVisible = false
    /// Bumped whenever anyone claims the state machine. A flow suspended in an await
    /// — the system picker, a permission dialog, SCStream.startCapture — compares it
    /// on the way out, so a recording the user cancelled meanwhile cannot start.
    private var flowGeneration = 0
    /// Whether the flush in progress is actually writing something out.
    private var flushPresents = true
    private var flushesInFlight = 0
    private var flushTask: Task<Void, Never>?
    private var flushGeneration = 0

    /// False when the microphone was off at start and had no permission yet:
    /// a mic track can't be added to a running stream.
    var canToggleMicrophoneLive: Bool { recorder.capturesMicrophone }

    private init() {
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedStop(error) }
        }
        // The same three toggles drive the main window, the overlay bar and the HUD;
        // while recording they act on the live stream.
        settings.$recordDesktopAudio.dropFirst().sink { [weak self] on in
            self?.recorder.desktopAudioMuted = !on
        }.store(in: &cancellables)
        settings.$recordMicrophone.dropFirst().sink { [weak self] on in
            self?.recorder.microphoneMuted = !on
        }.store(in: &cancellables)
        settings.$showPointer.dropFirst().sink { [weak self] _ in
            guard let self, self.state.isRecording else { return }
            // Read the setting when the task actually runs: two quick toggles produce
            // two unordered tasks, and whichever lands last must still be correct.
            Task { try? await self.recorder.setShowsCursor(AppSettings.shared.showPointer) }
        }.store(in: &cancellables)
        $state.map { [weak self] state in
            state.isRecording || state.isCountingDown || (state == .flushing && self?.flushPresents == true)
        }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                // The Kooha window gives way to the floating HUD while recording.
                if active {
                    self.mainWindowWasVisible = MainWindowController.shared.isVisible
                    MainWindowController.shared.hide()
                    RecordingHUD.shared.show()
                } else {
                    RecordingHUD.shared.hide()
                    if self.mainWindowWasVisible { MainWindowController.shared.show() }
                }
            }.store(in: &cancellables)
    }

    // MARK: Public actions

    /// Record button: starts a recording using the capture mode from settings.
    func toggleRecord() {
        // In the entry point rather than in the hot key wrapper: the menu item and
        // the main window's Record button reached none of these.
        if SaveDestination.isPresenting || Permissions.isPresenting { return }
        // A capture flow still owns the machine between the overlay closing and its
        // outcome arriving here, and starting a second flow in that gap threw the
        // user's framing away without a word.
        if CaptureOverlay.shared.isActive || ScreenshotController.shared.isBusy { return }
        switch state {
        case .idle:
            // Claim the slot before awaiting anything: the state used to be set
            // inside the task, so two quick presses both saw .idle and raced.
            let generation = claim()
            state = .selectingSource
            Task { await startFlow(source: nil, generation: generation) }
        case .recording:
            Task { await stop() }
        case .delayed, .selectingSource:
            cancel()
        case .flushing:
            break
        }
    }

    /// Start recording a source that was already chosen (e.g. from the capture overlay).
    func record(source: RecordingSource) {
        guard state == .idle else {
            // The overlay handed us a framed selection and something else claimed the
            // machine in between. Silently dropping it left the user watching their
            // framing disappear.
            Log.write("a recording source arrived while the machine was \(state); dropped")
            return
        }
        let generation = claim()
        state = .selectingSource
        Task { await startFlow(source: source, generation: generation) }
    }

    /// Pause and resume. The stream stays up; the paused stretch is cut out of the
    /// file, so the timer and the finished video agree.
    func togglePause() {
        guard state.isRecording else { return }
        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        isPaused = recorder.isPaused
        // Refresh straight away instead of waiting for the next tick.
        state = .recording(duration: recorder.recordedDuration)
    }

    /// Errors have to reach the user even with the main window closed, which is the
    /// normal state for a menu-bar app: the alert lives on that window.
    private func reportError(_ message: String) {
        lastError = message
        MainWindowController.shared.show()
    }

    /// Set while the app is terminating: a modal Save panel then holds the logout
    /// and macOS reports that Glimpse cancelled it.
    var isTerminating = false

    /// A flush is still placing the file. This outlives `.flushing`, because the
    /// state returns to idle as soon as the file is written while the Save panel and
    /// the preview still have to run — and a quit must wait for those too.
    ///
    /// Counted rather than read off `flushTask`: a flush publishes `.idle` before its
    /// Save panel and preview have run, so a second flush can legally begin and clear
    /// the handle while the first is still placing a file. A quit would then be told
    /// there was nothing to wait for.
    var hasPendingWork: Bool { flushesInFlight > 0 }

    /// Quitting must not interrupt a flush, or the file is left without its moov atom.
    /// Every flush goes through beginFlush, so awaiting the task is the whole story.
    func waitWhileFlushing() async {
        // Poll the count rather than awaiting the task. Awaiting `flushTask` returns
        // as soon as the NEWEST flush is done, which may not be the one still
        // writing — and, worse, that await is itself unbounded: a flush sitting on a
        // Save panel would hold a logout for as long as the panel stayed up, with
        // the tick limit below never completing a single iteration.
        var ticks = 0
        while flushesInFlight > 0, ticks < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            ticks += 1
        }
        if flushesInFlight > 0 { Log.write("quit: gave up waiting for \(flushesInFlight) flush(es)") }
    }

    /// Claims the machine for a new owner: bumps the generation any suspended flow
    /// compares against, and cancels a countdown that would otherwise keep writing
    /// the state from under the new owner.
    @discardableResult
    private func claim() -> Int {
        flowGeneration &+= 1
        delayTask?.cancel()
        delayTask = nil
        return flowGeneration
    }

    /// The single way into `.flushing`. The state is claimed here, synchronously,
    /// rather than inside the task — two callers racing used to leave the loser's
    /// do-nothing task in `flushTask`, which is what a quit then awaited.
    /// `presenting` is false for a flush that only waits for the recorder to let go
    /// of a stream: nothing is being written, so the HUD must not claim to be saving
    /// — and the main window must not be swept away for a recording that never was.
    private func beginFlush(presenting: Bool = true, _ body: @escaping @MainActor () async -> Void) {
        guard state != .flushing else { return }
        stopTicking()
        isPaused = false
        flushPresents = presenting
        state = .flushing
        // Tagged, because a later flush may have started between this one publishing
        // .idle and its own cleanup running — clearing the field blindly would then
        // erase the newer task a quit is waiting on.
        flushGeneration &+= 1
        let generation = flushGeneration
        flushesInFlight += 1
        flushTask = Task { @MainActor in
            await body()
            flushesInFlight -= 1
            if flushGeneration == generation { flushTask = nil }
        }
    }

    /// The recorder may still own a stream after the controller has given up on it;
    /// a flow suspended in startCapture tears it down when it resumes. Advertising
    /// idle before then makes the next Record press fail with "already running".
    private func awaitRecorderIdle() async {
        var ticks = 0
        while recorder.isRunning, ticks < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            ticks += 1
        }
        if recorder.isRunning { Log.write("gave up waiting for the recorder to release its stream") }
    }

    func cancel() {
        switch state {
        case .delayed, .selectingSource:
            claim()
            finishPickerIfNeeded()
            // The flow may be suspended inside startCapture; wait for it to let go
            // rather than claiming to be idle over a live stream.
            if recorder.isRunning {
                beginFlush(presenting: false) { await self.awaitRecorderIdle(); self.state = .idle }
            } else {
                state = .idle
            }
        case .recording:
            claim()
            beginFlush {
                await self.recorder.cancel()
                self.finishPickerIfNeeded()
                self.state = .idle
            }
        default:
            break
        }
    }

    func stop() async {
        guard case .recording = state else { return }
        beginFlush { [self] in
            do {
                let result = try await recorder.stop()
                finishPickerIfNeeded()
                // The file is written; the HUD's work is over. The quit path waits on
                // this task rather than on the state, so it still covers what follows.
                state = .idle
                await presentSuccess(relocateIfAsked(result))
            } catch {
                finishPickerIfNeeded()
                state = .idle
                reportError(error.localizedDescription)
            }
        }
        // Bounded, like waitWhileFlushing: quitting while recording comes through
        // here first, and an unbounded await on a volume that has gone away would
        // hold the logout for as long as finishWriting blocked — the bound one
        // function away never got a chance to apply.
        await waitWhileFlushing()
    }

    // MARK: Flow

    /// `generation` is the value `claim()` returned to the caller, not a fresh read:
    /// the task body runs a turn later, and anything claiming the machine in between
    /// would otherwise be adopted as this flow's own generation — a cancelled flow
    /// would then put the picker up and record anyway.
    private func startFlow(source preselected: RecordingSource?, generation: Int) async {
        // Cleared before the generation guard: a cancelled logout leaves this set
        // otherwise, and "ask where to save" stays silently disabled for the rest of
        // the session — including when this flow is the one being claimed away.
        isTerminating = false
        guard generation == flowGeneration else { return }
        func stillOurs() -> Bool { generation == flowGeneration }
        lastError = nil
        // ensureScreenCapture runs a modal alert, whose nested run loop keeps
        // draining the main queue — so another flow can claim the machine while this
        // line is on the stack. Every other state writer in this file checks; this
        // one did not, which made the comment below about claiming untrue of it.
        guard Permissions.ensureScreenCapture() else {
            if stillOurs() { state = .idle }
            return
        }
        let source: RecordingSource
        if let preselected {
            source = preselected
        } else {
            // Set before awaiting: cancelling while the picker is up runs
            // finishPickerIfNeeded, which would otherwise be a no-op and leave the
            // system sharing indicator lit for the rest of the session.
            currentSourceUsesPicker = settings.captureMode == .monitorWindow
            do {
                source = try await selectSource()
            } catch RecordingError.cancelled {
                guard stillOurs() else { return }
                finishPickerIfNeeded()
                state = .idle
                return
            } catch {
                guard stillOurs() else { return }
                finishPickerIfNeeded()
                state = .idle
                reportError(error.localizedDescription)
                return
            }
            // Cancelled while the picker was up. stillOurs() already implies the
            // state has not moved, since every writer that could move it claims first.
            guard stillOurs() else { return }
        }
        currentSourceUsesPicker = source.usesSystemPicker

        let delay = preselected?.delay ?? settings.recordDelay
        if delay > 0 {
            let ok = await runCountdown(seconds: delay)
            guard stillOurs() else { return }
            guard ok else { finishPickerIfNeeded(); state = .idle; return }
        }

        // Read once. The microphone permission dialog below can sit there for
        // minutes without blocking the main queue, so Preferences stays reachable —
        // and a format changed while it is up used to give the file one profile's
        // extension and the other's container.
        let profile = settings.profile
        let folder = settings.recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(folder.appendingPathComponent(
            timestampedFileName(prefix: "Screen Recording", ext: profile.fileExtension)))

        // Capture the microphone whenever we can do so silently (permission already
        // granted) so it can be un-muted mid-recording; otherwise only when asked for.
        // A microphone we are not allowed to read delivers nothing, and the writer
        // would wait out its grace period before starting — losing the first seconds
        // of the video. So settle the permission before the stream starts, and only
        // create the track when it is actually granted.
        var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if settings.recordMicrophone && !micAuthorized {
            micAuthorized = await AVCaptureDevice.requestAccess(for: .audio)
            // That dialog can stay up for minutes; the user may well have cancelled.
            // The picker belongs to whoever owns the machine now, so leave it alone.
            guard stillOurs() else { return }
        }
        let options = RecordingOptions(
            filter: source.filter,
            sourceRect: source.sourceRect,
            outputURL: url,
            profile: profile,
            framerate: settings.framerate,
            quality: settings.quality,
            capturesMicrophone: settings.recordMicrophone && micAuthorized,
            // The voice processor costs ~10% CPU on its own, so only pay for it when the
            // microphone is actually on; a mic enabled later mid-recording goes without it.
            microphoneEchoCancellation: settings.microphoneEchoCancellation && settings.recordMicrophone,
            desktopAudioMuted: !settings.recordDesktopAudio,
            microphoneMuted: !settings.recordMicrophone,
            showsCursor: settings.showPointer
        )

        do {
            try await recorder.start(options)
            // Starting the stream takes a few hundred milliseconds; without this a
            // recording the user cancelled in that window would start anyway.
            guard stillOurs() else {
                await recorder.cancel()
                return
            }
            isPaused = false
            state = .recording(duration: 0)
            startTicking()
        } catch {
            finishPickerIfNeeded()
            // An unexpected stop may already have reported this and reset the state.
            guard stillOurs() else { return }
            state = .idle
            reportError(error.localizedDescription)
        }
    }

    private func selectSource() async throws -> RecordingSource {
        switch settings.captureMode {
        case .monitorWindow:
            var filter = try await SourcePicker.shared.pick()
            // For a whole display, rebuild the filter so our own HUD/windows stay out of the video.
            if #available(macOS 15.2, *), filter.style == .display, let display = filter.includedDisplays.first,
               let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
               let me = content.currentApplication {
                filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
            }
            return RecordingSource(filter: filter, sourceRect: nil, usesSystemPicker: true, delay: nil)
        case .selection:
            guard let selection = await CaptureOverlay.shared.selectArea(initial: settings.lastSelection) else {
                throw RecordingError.cancelled
            }
            settings.lastSelection = selection.rect
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.display(for: selection.screen) else {
                throw RecordingError.failed(NSError(domain: "Glimpse", code: 1,
                                                    userInfo: [NSLocalizedDescriptionKey: L("error.display_not_found")]))
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: content.currentApplication.map { [$0] } ?? [],
                                         exceptingWindows: [])
            return RecordingSource(filter: filter,
                                   sourceRect: selection.rectInDisplaySpace,
                                   usesSystemPicker: false,
                                   delay: nil)
        }
    }

    private func runCountdown(seconds: Int) async -> Bool {
        state = .delayed(secondsLeft: seconds)
        let task = Task<Void, Never> {
            var left = seconds
            while left > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                left -= 1
                state = .delayed(secondsLeft: left)
            }
        }
        delayTask = task
        await task.value
        delayTask = nil
        if case .delayed = state { return true }
        return false
    }

    private func startTicking() {
        tickTimer?.invalidate()
        // Once a second, aligned to the second boundary: the display shows whole seconds,
        // and every tick re-renders the HUD and the menu bar item.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.state else { return }
                self.state = .recording(duration: self.recorder.recordedDuration)
            }
        }
        timer.tolerance = 0.05
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func finishPickerIfNeeded() {
        if currentSourceUsesPicker {
            SourcePicker.shared.deactivate()
            currentSourceUsesPicker = false
        }
    }

    /// The stream died on us — the window closed, the display was unplugged, the
    /// disk filled. Everything written so far is the user's work, so finalise the
    /// file and hand it over; only discard if finalising is impossible.
    /// Only a live recording can be salvaged, and only once. Entering here while a
    /// stop is already flushing would run cancel() against the writer that stop() is
    /// finalising, deleting the very file being saved.
    private func handleUnexpectedStop(_ error: Error) {
        guard state.isBusy, state != .flushing else {
            Log.write("unexpected stop ignored in state \(state): \(error.localizedDescription)")
            return
        }
        // Invalidate any start still in flight, so it cannot resume into .recording
        // on a stream that has already died.
        claim()
        let wasRecording = state.isRecording
        guard wasRecording else {
            // The stream died while a start was still being awaited. Cancelling from
            // here would race startCapture, so the suspended flow tears it down when
            // it resumes — but the state must not say idle before it has, or the next
            // Record press meets a recorder that is still holding a stream.
            reportError(error.localizedDescription)
            guard recorder.isRunning else { state = .idle; return }
            beginFlush(presenting: false) { await self.awaitRecorderIdle(); self.state = .idle }
            return
        }
        beginFlush { [self] in
            let salvaged = try? await recorder.stop()
            if salvaged == nil { await recorder.cancel() }
            finishPickerIfNeeded()
            state = .idle
            if let salvaged {
                // The file survived, so an error alert would misrepresent it. The
                // preview says the recording ended early; the log has the reason.
                Log.write("salvaged after unexpected stop: \(error.localizedDescription)")
                await presentSuccess(relocateIfAsked(salvaged), title: L("preview.recording_salvaged"))
            } else {
                reportError(error.localizedDescription)
            }
        }
    }

    /// With "ask where to save" on, the finished file is offered for a move. The
    /// video has to be written somewhere while it records, so unlike a screenshot the
    /// question comes at the end — and cancelling simply leaves it in the recordings
    /// folder rather than throwing the recording away.
    private func relocateIfAsked(_ result: RecordingResult) -> RecordingResult {
        guard settings.askWhereToSave, !isTerminating,
              let destination = SaveDestination.ask(name: result.url.lastPathComponent,
                                                    in: settings.recordingsFolder)
        else { return result }
        // The Save panel hands back a symlink-resolved URL while the stored folder
        // may not be resolved, so "keep it where it is" can look like a different
        // path. Compare canonical paths, and never delete before the move lands.
        let source = result.url.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != target else { return result }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: target.path) {
                do {
                    _ = try files.replaceItemAt(target, withItemAt: source)
                } catch {
                    // replaceItemAt refuses across volumes. Stage the copy beside the
                    // destination first: clearing what is already there before a
                    // cross-volume copy would destroy it if the copy then failed.
                    let staged = target.deletingLastPathComponent()
                        .appendingPathComponent(".\(target.lastPathComponent).glimpse-partial")
                    try? files.removeItem(at: staged)
                    try files.copyItem(at: source, to: staged)
                    // Whatever happens next, do not leave a hidden copy of the
                    // recording behind in the user's folder.
                    defer { try? files.removeItem(at: staged) }
                    _ = try files.replaceItemAt(target, withItemAt: staged)
                    try? files.removeItem(at: source)
                }
            } else {
                try files.moveItem(at: source, to: target)
            }
            return RecordingResult(url: target, duration: result.duration, fileSize: result.fileSize)
        } catch {
            // Through reportError, not a bare assignment: the alert lives on the main
            // window, which a menu-bar app normally keeps closed, so a bare
            // assignment surfaced the failure later and out of context. The preview
            // still follows and still points at the file's real location — the move
            // is what failed, not the recording.
            reportError(error.localizedDescription)
            return result
        }
    }

    private func presentSuccess(_ result: RecordingResult,
                                title: String = L("preview.recording_saved")) async {
        let subtitle = "\(formatDuration(result.duration)), \(formatFileSize(result.fileSize))"
        guard settings.showPreviewAfterCapture else { return }
        let thumb = await Self.thumbnail(for: result.url)
        CapturePreviewPanel.shared.show(image: thumb, title: title,
                                        subtitle: subtitle, fileURL: result.url)
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: time) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
