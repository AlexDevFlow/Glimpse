import AVFoundation
import ScreenCaptureKit

struct RecordingOptions {
    var filter: SCContentFilter
    /// Region to capture, in the display's own top-left-origin point space. nil = whole filter content.
    var sourceRect: CGRect?
    var outputURL: URL
    var profile: RecordingProfile
    var framerate: Int
    var quality: RecordingQuality
    /// Whether a microphone track is created at all. Muting is a separate, live switch.
    var capturesMicrophone: Bool
    /// Capture the microphone through the system voice processor (echo cancellation).
    var microphoneEchoCancellation: Bool
    var desktopAudioMuted: Bool
    var microphoneMuted: Bool
    var showsCursor: Bool
}

struct RecordingResult {
    let url: URL
    let duration: TimeInterval
    let fileSize: Int64
}

enum RecordingError: LocalizedError {
    case alreadyRunning
    case cancelled
    case stoppedBySystem
    case writerFailed(String)
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return L("error.already_running")
        case .cancelled: return L("error.cancelled")
        case .stoppedBySystem: return L("error.stopped_by_system")
        case .writerFailed(let s): return L("error.writer_failed", s)
        case .failed(let e): return e.localizedDescription
        }
    }
}

/// SCStream → AVAssetWriter. Owning the writer (instead of SCRecordingOutput) is what
/// lets us mute desktop audio / microphone and toggle the pointer while recording:
/// muted tracks receive silence, so the file stays in sync and the stream never restarts.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var outputURL: URL?

    private let queue = DispatchQueue(label: "Glimpse.output", qos: .userInitiated)
    private let lock = NSLock()
    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime?
    /// End times, not start times: the writer rejects anything overlapping the
    /// previous sample, and a re-timed buffer typically lands one buffer back.
    private var lastDesktopAudioTime: CMTime?
    private var lastMicTime: CMTime?
    private var _startedAt: CMTime?
    /// Written on the output queue, read from the main actor on every tick.
    /// On the host clock, the same one the sample timestamps and `pausedTotal` use.
    /// It was a `Date` — wall clock — which advances across system sleep while the
    /// host clock does not: sleeping the Mac mid-recording made the HUD over-report
    /// by the whole sleep interval while the file stayed correct.
    private var startedAt: CMTime? {
        get { lock.withLock { _startedAt } }
        set { lock.withLock { _startedAt = newValue } }
    }
    private var _desktopAudioMuted = false
    private var _microphoneMuted = false
    private var stopping = false
    /// Queue-confined: closed until start() has published everything below.
    private var accepting = false
    // Pausing drops buffers and accumulates the paused time; every buffer written
    // afterwards is shifted back by that total, so the pause is cut out of the file
    // instead of being frozen into it as a still frame.
    /// Claimed by whichever of stop()/cancel() gets there first. Without it a stop
    /// and an unexpected-stop teardown can run against the same writer, which
    /// deletes the file the other one is finalising.
    private var tearingDown = false
    private var _hasStream = false
    /// True from the first line of start() until the stream is published or the
    /// attempt fails. Without it `isRunning` was false for the whole prologue —
    /// which includes bringing up the voice-processing microphone, hundreds of
    /// milliseconds — and that prologue runs off the MainActor, so a Cancel landing
    /// in it took the "nothing to wait for" branch and advertised idle while the
    /// screen and microphone indicators were still coming on.
    private var _starting = false
    private var _paused = false
    private var pauseStart: CMTime?
    private var pausedTotal: CMTime = .zero

    // The writer is created lazily on the first video frame, once the real audio formats
    // are known: AVAssetWriter needs every input up front and refuses buffers whose
    // layout differs from what it was promised ("Cannot Encode Media").
    private var pendingProfile: RecordingProfile?
    private var pendingVideoSettings: [String: Any] = [:]
    private var pendingURL: URL?
    private var audioFormat: CMFormatDescription?
    private var micFormat: CMFormatDescription?
    private var captureStartedAt: Date?
    private var microphone: MicrophoneCapture?

    var onUnexpectedStop: ((Error) -> Void)?

    /// Answered from the lock rather than the output queue: this is polled from
    /// the main thread, and that queue is busy appending media.
    var isRunning: Bool { lock.withLock { _hasStream || _starting } }
    private var _capturesMicrophone = false
    /// Read from the MainActor (the HUD's live microphone toggle) and written from
    /// the pool, so it goes through the lock like every other cross-thread flag.
    private(set) var capturesMicrophone: Bool {
        get { lock.withLock { _capturesMicrophone } }
        set { lock.withLock { _capturesMicrophone = newValue } }
    }

    var desktopAudioMuted: Bool {
        get { lock.withLock { _desktopAudioMuted } }
        set { lock.withLock { _desktopAudioMuted = newValue } }
    }

    var microphoneMuted: Bool {
        get { lock.withLock { _microphoneMuted } }
        set { lock.withLock { _microphoneMuted = newValue } }
    }

    var isPaused: Bool { lock.withLock { _paused } }

    /// Returns true to exactly one caller.
    private func claimTeardown() -> Bool {
        lock.withLock {
            if tearingDown { return false }
            tearingDown = true
            return true
        }
    }

    /// Wall-clock time minus everything spent paused — what ends up in the file.
    var recordedDuration: TimeInterval {
        let (begin, total, start) = lock.withLock { (_startedAt, pausedTotal, pauseStart) }
        guard let begin else { return 0 }
        var paused = total.seconds
        if let start {
            paused += CMTimeSubtract(Self.now(), start).seconds
        }
        let elapsed = CMTimeSubtract(Self.now(), begin).seconds
        guard elapsed.isFinite, paused.isFinite else { return 0 }
        return max(0, elapsed - paused)
    }

    // MARK: Pause

    /// The stream keeps running (the system recording indicator stays honest, and
    /// restarting a stream would drop the writer); its buffers are simply discarded.
    func pause() {
        lock.withLock {
            guard !_paused else { return }
            _paused = true
            pauseStart = Self.now()
        }
    }

    func resume() {
        lock.withLock {
            guard _paused, let start = pauseStart else { return }
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(Self.now(), start))
            pauseStart = nil
            _paused = false
        }
    }

    /// Teardown's version of `resume()`: folds an in-progress pause into the total
    /// and closes the gate in the SAME lock acquisition. Two separate ones left a
    /// window in which the sample handler read the new, larger offset while
    /// `stopping` was still false — it then shifted a frame captured during the pause
    /// back to at or before the last one written, which is fatal to the writer and
    /// cost the user the whole recording.
    private func endPauseAndSeal() {
        lock.withLock {
            if _paused, let start = pauseStart {
                pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(Self.now(), start))
                pauseStart = nil
                _paused = false
            }
            stopping = true
        }
    }

    private static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    // MARK: Start

    func start(_ options: RecordingOptions) async throws {
        guard queue.sync(execute: { self.stream }) == nil else { throw RecordingError.alreadyRunning }
        lock.withLock { _starting = true }
        // Every exit from here must clear it, or the recorder looks busy for ever.
        defer { lock.withLock { _starting = false } }

        let config = SCStreamConfiguration()
        let scale = CGFloat(options.filter.pointPixelScale)
        let size: CGSize
        if let rect = options.sourceRect {
            // The selection may predate a delay of up to 30s, during which the
            // display can be resized or rearranged. A rect outside the content would
            // otherwise fall back to scaling the whole display into the frame.
            let bounds = CGRect(origin: .zero, size: options.filter.contentRect.size)
            let clamped = rect.intersection(bounds)
            // Falling back to `rect` here would hand SCK the very off-display
            // rectangle this is meant to reject, which it accepts without complaint.
            if clamped.isNull || clamped.isEmpty {
                Log.write("selection no longer overlaps the display; recording all of it")
                size = options.filter.contentRect.size
            } else {
                config.sourceRect = clamped
                size = clamped.size
            }
        } else {
            size = options.filter.contentRect.size
        }
        var w = Int((size.width * scale).rounded())
        var h = Int((size.height * scale).rounded())
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        w = max(w, 2); h = max(h, 2)
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framerate))
        config.showsCursor = options.showsCursor
        // 4:2:0 is what the H.264/HEVC encoder consumes: no BGRA→YCbCr conversion per
        // frame and each buffer is about a third of the size.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureResolution = .best
        config.scalesToFit = true
        config.queueDepth = 4
        // Desktop audio is always captured (it rides on the screen-recording permission);
        // "off" just means silence is written. The microphone track is optional.
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Microphone: through voice processing when asked (and available), else via ScreenCaptureKit.
        var microphone: MicrophoneCapture?
        if options.capturesMicrophone && options.microphoneEchoCancellation {
            let mic = MicrophoneCapture()
            do {
                try mic.start { [weak self] sb in
                    guard let self else { return }
                    self.queue.async { self.handle(sb, of: .microphone) }
                }
                microphone = mic
            } catch {
                Log.write("voice-processing microphone unavailable (\(Self.describe(error) ?? "?")), falling back to ScreenCaptureKit")
            }
        }
        config.captureMicrophone = options.capturesMicrophone && microphone == nil
        self.microphone = microphone

        desktopAudioMuted = options.desktopAudioMuted
        microphoneMuted = options.microphoneMuted
        capturesMicrophone = options.capturesMicrophone

        try? FileManager.default.removeItem(at: options.outputURL)
        let bitrate = options.quality.bitrate(width: w, height: h, framerate: options.framerate)
        Log.write("video: \(w)x\(h) @\(options.framerate) \(options.quality.rawValue) → \(bitrate / 1000) kbit/s")
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: options.framerate,
            AVVideoMaxKeyFrameIntervalKey: options.framerate * 2,
            // The stream is variable rate — ScreenCaptureKit only emits on change —
            // so the frame count above can span minutes on a still screen. This is
            // what actually keeps keyframes two seconds apart, and scrubbing usable.
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if options.profile.codec == .h264 {
            // Otherwise VideoToolbox picks, and Main loses the 8×8 transform that
            // sharp text benefits from.
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        pendingVideoSettings = [
            AVVideoCodecKey: options.profile.codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
        ]
        pendingProfile = options.profile
        pendingURL = options.outputURL
        audioFormat = nil
        micFormat = nil

        let stream = SCStream(filter: options.filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            if config.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
        } catch {
            // Otherwise the engine keeps running with its tap installed and the
            // orange microphone indicator stays lit with nothing recording.
            microphone?.stop()
            self.microphone = nil
            throw RecordingError.failed(error)
        }

        // Everything the output queue reads is published on that queue, and only
        // then does `accepting` open the gate: a microphone buffer arriving early
        // used to be handled against half-initialised, torn state.
        queue.sync {
            self.stream = stream
            self.configuration = config
            self.outputURL = options.outputURL
            self.sessionStart = nil
            self.lastVideoTime = nil
            self.accepting = true
        }
        lock.withLock { stopping = false; tearingDown = false; _hasStream = true; _paused = false; pauseStart = nil; pausedTotal = .zero }

        do {
            try await stream.startCapture()
        } catch {
            // startCapture may have armed the session before throwing; releasing the
            // stream without stopping it can strand the system recording indicator.
            // stopCapture also drains the handler queue, and a buffer that arrives
            // while it does can build a writer on the output file — reset() alone
            // would then leave a partial recording behind from a start that failed.
            lock.withLock { stopping = true }
            try? await stream.stopCapture()
            microphone?.stop()
            queue.sync { writer?.cancelWriting() }
            if let url = queue.sync(execute: { self.outputURL }) {
                try? FileManager.default.removeItem(at: url)
            }
            reset()
            throw RecordingError.failed(error)
        }
        queue.sync {
            self.startedAt = Self.now()
            self.captureStartedAt = Date()
        }
    }

    /// Builds the writer with inputs matching the formats we have actually seen.
    private func setupWriter(firstVideoTime: CMTime) -> Bool {
        guard let url = pendingURL, let profile = pendingProfile else { return false }
        try? FileManager.default.removeItem(at: url)
        Log.write("writer setup: video \(pendingVideoSettings[AVVideoWidthKey] ?? 0)x\(pendingVideoSettings[AVVideoHeightKey] ?? 0)")
        Log.write("audio format: \(audioFormat.map { "\($0)" } ?? "none")")
        Log.write("mic format: \(micFormat.map { "\($0)" } ?? "none")")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: profile.fileType)
            // Deliberately off. With it on, AVAssetWriter stages the media in a
            // sibling ".sb-<uuid>" file and only moves it into place at
            // finishWriting. Measured: cancelWriting() does not delete that file and
            // neither does removing the output URL, so every cancelled or failed
            // recording strands its full size in the user's folder, invisibly — and a
            // crash or force-quit strands it with no cleanup running at all. It also
            // makes finishWriting copy the whole file (~1.2 ms/MB), which is the last
            // moment you want to be slow: a logout waits on it.
            writer.shouldOptimizeForNetworkUse = false
            // Without this a file truncated by a crash, a force-quit or a power cut
            // has no moov atom and will not open at all — measured: zero tracks. With
            // a one-second interval the same truncated file plays back everything up
            // to the last fragment, and a normally finished recording is unchanged in
            // duration and 0.3% larger.
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: pendingVideoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { throw RecordingError.writerFailed("video input rejected") }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if let audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(for: audioFormat),
                                               sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw RecordingError.writerFailed("audio input rejected") }
                writer.add(input)
                audioInput = input
            }

            var micInput: AVAssetWriterInput?
            if let micFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(for: micFormat),
                                               sourceFormatHint: micFormat)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw RecordingError.writerFailed("microphone input rejected") }
                writer.add(input)
                micInput = input
            }

            guard writer.startWriting() else {
                throw RecordingError.writerFailed(Self.describe(writer.error) ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: firstVideoTime)
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.micInput = micInput
            self.sessionStart = firstVideoTime
            return true
        } catch {
            Log.write("writer setup failed: \(Self.describe(error) ?? "?")")
            // Give up for good: retrying on every frame would just spam the same error.
            lock.withLock { stopping = true }
            onUnexpectedStop?(error)
            return false
        }
    }

    /// Pointer visibility can be changed on the live stream.
    func setShowsCursor(_ shows: Bool) async throws {
        // `stream` and `configuration` belong to the output queue, which nils them
        // during teardown. Reading them from the MainActor could retain memory that
        // has just been freed, so take the pair on the queue that owns them.
        let pair: (SCStream, SCStreamConfiguration)? = queue.sync {
            guard let stream = self.stream, let configuration = self.configuration else { return nil }
            return (stream, configuration)
        }
        guard let (stream, configuration) = pair else { return }
        configuration.showsCursor = shows
        try await stream.updateConfiguration(configuration)
    }

    // MARK: Stop

    /// Stops capture and waits until the file has been finalised.
    func stop() async throws -> RecordingResult {
        guard let stream = queue.sync(execute: { self.stream }) else { throw RecordingError.cancelled }
        guard claimTeardown() else {
            // Another teardown owns the writer. The controller serialises these, so
            // reaching here means that serialisation broke rather than the user
            // cancelling — worth a line in the log, not a silent no-op.
            Log.write("stop() refused: a teardown is already in progress")
            throw RecordingError.cancelled
        }
        endPauseAndSeal()
        microphone?.stop()
        try? await stream.stopCapture()
        guard let writer = queue.sync(execute: { self.writer }) else {
            reset()
            throw RecordingError.writerFailed("no frames were captured")
        }
        do {
            let result = try await finishWriting(writer)
            reset()
            return result
        } catch {
            // finishWriting throws exactly when the disk filled or the volume went
            // away. Without this the teardown claim was never released: cancel()
            // then refused too, the partial file stayed, and every later recording
            // reported "already running" until the app was relaunched.
            queue.sync { self.writer?.cancelWriting() }
            if let url = queue.sync(execute: { self.outputURL }) {
                try? FileManager.default.removeItem(at: url)
            }
            reset()
            throw error
        }
    }

    /// Stops and discards the recording file.
    func cancel() async {
        guard let stream = queue.sync(execute: { self.stream }), claimTeardown() else { return }
        endPauseAndSeal()
        microphone?.stop()
        try? await stream.stopCapture()
        queue.sync { writer?.cancelWriting() }
        // outputURL belongs to the output queue like everything else here; reading
        // it from this thread could see it already nil and leave the file behind.
        if let url = queue.sync(execute: { self.outputURL }) {
            try? FileManager.default.removeItem(at: url)
        }
        reset()
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RecordingResult, Error>) in
            queue.async {
                guard writer.status == .writing else {
                    cont.resume(throwing: RecordingError.writerFailed(Self.describe(writer.error) ?? "writer not writing"))
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                // Sample times come from the host clock; ending the session "now" keeps the
                // last frame on screen until the real stop time even if nothing changed.
                let end = CMTimeSubtract(Self.now(), self.lock.withLock { self.pausedTotal })
                if let start = self.sessionStart, end > start {
                    writer.endSession(atSourceTime: end)
                    self.lastVideoTime = end
                }
                let url = self.outputURL
                let sessionStart = self.sessionStart
                let lastVideoTime = self.lastVideoTime
                let fallback = self.recordedDuration
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: Self.makeResult(url: url, sessionStart: sessionStart,
                                                               lastVideoTime: lastVideoTime,
                                                               fallbackDuration: fallback))
                    } else {
                        cont.resume(throwing: RecordingError.writerFailed(Self.describe(writer.error) ?? "unknown"))
                    }
                }
            }
        }
    }

    /// Runs on the output queue: these fields are read there on every sample buffer,
    /// and tearing them down from the caller's thread is a use-after-free waiting to
    /// happen when a buffer is already in flight.
    private func reset() {
        queue.sync { resetOnQueue() }
    }

    private func resetOnQueue() {
        accepting = false
        capturesMicrophone = false
        lock.withLock { stopping = false }
        stream = nil
        configuration = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        sessionStart = nil
        lastVideoTime = nil
        lastDesktopAudioTime = nil
        lastMicTime = nil
        startedAt = nil
        captureStartedAt = nil
        microphone = nil
        outputURL = nil
        pendingURL = nil
        pendingProfile = nil
        audioFormat = nil
        micFormat = nil
        lock.withLock { _paused = false; pauseStart = nil; pausedTotal = .zero; tearingDown = false; _hasStream = false }
    }

    /// Built from values captured on the output queue: the writer's completion block
    /// runs on an AVFoundation thread, where reading these fields is a torn read.
    private static func makeResult(url: URL?, sessionStart: CMTime?, lastVideoTime: CMTime?,
                                   fallbackDuration: TimeInterval) -> RecordingResult {
        let url = url ?? URL(fileURLWithPath: "/dev/null")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var duration = fallbackDuration
        if let start = sessionStart, let end = lastVideoTime {
            duration = CMTimeSubtract(end, start).seconds
        }
        return RecordingResult(url: url, duration: duration, fileSize: size)
    }

    // MARK: SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handle(sampleBuffer, of: type)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, !lock.withLock({ stopping }) else { return }

        let (paused, offset) = lock.withLock { (_paused, pausedTotal) }

        if writer == nil {
            // Learn the audio formats first; start on a video frame once we have them
            // (or after a grace period, in case a source stays silent). Formats are
            // learned even while paused — the writer needs every input up front, and
            // a pause taken before the first audio buffer would otherwise cost the
            // recording its audio track entirely.
            switch type {
            case .audio: if audioFormat == nil { audioFormat = sampleBuffer.formatDescription }
            case .microphone: if micFormat == nil { micFormat = sampleBuffer.formatDescription }
            case .screen:
                guard !paused, Self.isCompleteFrame(sampleBuffer) else { return }
                let waited = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                let ready = audioFormat != nil && (!capturesMicrophone || micFormat != nil)
                guard ready || waited > 1.5 else { return }
                if capturesMicrophone && micFormat == nil {
                    // Bluetooth profile switching can take seconds. The writer is
                    // built without a microphone input, and every later mic buffer is
                    // dropped — silently, until now.
                    Log.write("microphone produced no buffer in \(String(format: "%.1f", waited))s; recording without a microphone track")
                }
                guard setupWriter(firstVideoTime: CMTimeSubtract(sampleBuffer.presentationTimeStamp, offset)) else { return }
            @unknown default: return
            }
        }

        guard !paused else { return }

        guard let writer, writer.status == .writing else {
            if let writer, writer.status == .failed, !lock.withLock({ stopping }) {
                lock.withLock { stopping = true }
                onUnexpectedStop?(RecordingError.writerFailed(Self.describe(writer.error) ?? "unknown"))
            }
            return
        }

        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let videoInput, videoInput.isReadyForMoreMediaData,
                  let frame = Self.shifted(sampleBuffer, back: offset) else { return }
            let pts = frame.presentationTimeStamp
            // Video tolerates nothing. Measured: a single repeated or earlier
            // timestamp fails the writer, and append() returns true anyway — the
            // whole recording dies later, out of sight of the else branch below.
            // A frame captured during a pause can arrive after resume has already
            // folded that pause into the offset, which lands it exactly here.
            if let last = lastVideoTime, pts <= last {
                Log.write("video frame out of order; dropped")
                return
            }
            if videoInput.append(frame) { lastVideoTime = pts } else { Log.write("video append failed: \(Self.describe(writer.error) ?? "?")") }
        case .audio:
            append(sampleBuffer, to: audioInput, muted: desktopAudioMuted, shiftedBack: offset,
                   isMicrophone: false)
        case .microphone:
            append(sampleBuffer, to: micInput, muted: microphoneMuted, shiftedBack: offset,
                   isMicrophone: true)
        @unknown default:
            break
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, muted: Bool,
                        shiftedBack offset: CMTime, isMicrophone: Bool) {
        guard let input, let start = sessionStart, input.isReadyForMoreMediaData,
              let buffer = Self.shifted(sampleBuffer, back: offset) else { return }
        // The offset a buffer gets depends on when it was delivered, so at a resume
        // the first buffer of a track can land at or before the last one written.
        // Compare against the previous buffer's START, not its end: capture stamps a
        // buffer from the device clock but declares its duration from the nominal
        // sample rate, so under any clock drift the next buffer legitimately begins a
        // shade before the previous one nominally ended. An end-time comparison reads
        // that as an overlap and drops roughly every other buffer, and because an AAC
        // writer input concatenates samples rather than honouring gaps, the audio
        // track comes out half length and out of sync. Measured, both halves.
        if let last = isMicrophone ? lastMicTime : lastDesktopAudioTime,
           buffer.presentationTimeStamp <= last {
            Log.write("audio buffer out of order (\(isMicrophone ? "mic" : "desktop")); dropped")
            return
        }
        // Audio that predates the first video frame would land before the session.
        guard buffer.presentationTimeStamp >= start else { return }
        if muted {
            // Fail closed: if the buffer cannot be silenced, drop it rather than
            // write audio the user believes is muted.
            guard let data = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                             dataLength: CMBlockBufferGetDataLength(data)) == kCMBlockBufferNoErr
            else {
                Log.write("muted audio buffer could not be silenced; dropped")
                return
            }
        }
        if input.append(buffer) {
            let time = buffer.presentationTimeStamp
            if isMicrophone { lastMicTime = time } else { lastDesktopAudioTime = time }
        } else {
            Log.write("audio append failed (\(input == micInput ? "mic" : "desktop")): \(Self.describe(writer?.error) ?? "?") buffer=\(buffer.formatDescription.map { "\($0)" } ?? "?")")
        }
    }

    /// Re-stamps a buffer earlier by `offset`, which is how the paused stretches are
    /// removed from the timeline. Returns the buffer untouched when nothing was paused.
    private static func shifted(_ sampleBuffer: CMSampleBuffer, back offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, offset > .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else { return nil }
        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                                    sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }

    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The user hit "stop sharing", the window closed, or something broke. Ignore
        // a late callback from a stream we have already let go of.
        guard queue.sync(execute: { stream === self.stream }) else { return }
        if lock.withLock({ stopping }) { return }
        onUnexpectedStop?(error)
    }

    // MARK: Helpers

    private static func aacSettings(for format: CMFormatDescription) -> [String: Any] {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let channels = min(max(Int(asbd?.mChannelsPerFrame ?? 2), 1), 2)
        var rate = asbd?.mSampleRate ?? 48_000
        // Exactly the rates AAC can encode — queried from
        // kAudioFormatProperty_AvailableEncodeSampleRates. 64/88.2/96 kHz used to be
        // in this list, and passing one to AVAssetWriterInput raises an Objective-C
        // exception that Swift cannot catch, killing the app mid-recording. USB
        // interfaces commonly default to 96 kHz.
        if ![8000.0, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000].contains(rate) {
            rate = 48_000
        }
        // AAC only accepts bitrates proportionate to the sample rate: 128 kbps is fine
        // for 48 kHz but rejected for a 16 kHz Bluetooth headset microphone.
        let perChannel = min(max(Int(rate * 2), 24_000), 96_000)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: perChannel * channels,
        ]
    }

    private static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        var parts = [ns.localizedDescription]
        if let reason = ns.localizedFailureReason { parts.append(reason) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
        }
        return parts.joined(separator: " – ")
    }
}
