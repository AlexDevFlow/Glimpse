import AVFoundation
import CoreAudio

/// Microphone via AVAudioEngine with Apple's voice processing (echo cancellation,
/// noise suppression). The echo canceller uses what the Mac is playing as reference,
/// so music coming out of the speakers is removed from the microphone track instead
/// of being recorded twice. Buffers are re-packaged as CMSampleBuffers on the host
/// clock, the same timeline ScreenCaptureKit uses.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    /// start() and stop() have callers on different threads — the recorder's setup
    /// and teardown on the cooperative pool, the device-change observer wherever the
    /// notification lands — and mutating the engine graph from two at once is a hard
    /// crash Swift cannot catch. The lock covers the graph, not just the two flags:
    /// guarding the flags alone still leaves stop()'s removeTap racing start()'s
    /// engine.start().
    private let lock = NSLock()
    private var running = false
    private var configurationObserver: Any?

    func start(handler: @escaping (CMSampleBuffer) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        // Returning quietly would tell the caller a microphone is live on a handler
        // that was never installed. A fresh instance is built per recording, so this
        // is a programming error rather than a state to recover from.
        guard !running else {
            Log.write("microphone: start() called on an already running capture; ignored")
            return
        }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        if #available(macOS 14.0, *) {
            // Don't let voice processing turn the system audio down while we record it.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw NSError(domain: "Glimpse", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("error.no_microphone")])
        }
        // Voice processing wants a full input → output graph, so route the input to the
        // main mixer at volume zero (nothing is played back). The processed signal comes
        // out as N identical channels; a mixer downmix of those yields silence, so we
        // tap the input node itself and keep channel 0 as mono.
        let mono = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1)!
        engine.connect(input, to: engine.mainMixerNode, format: hardware)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        engine.mainMixerNode.outputVolume = 0
        Log.write("microphone (voice processing): \(hardware.sampleRate) Hz, \(hardware.channelCount) ch → mono")

        var delivered = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { buffer, time in
            guard let src = buffer.floatChannelData,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let dst = out.floatChannelData else { return }
            out.frameLength = buffer.frameLength
            dst[0].update(from: src[0], count: Int(buffer.frameLength))
            if let sb = Self.makeSampleBuffer(out, at: time) {
                delivered += 1
                if delivered == 1 { Log.write("microphone: first buffer \(out.frameLength) frames") }
                handler(sb)
            }
        }
        engine.prepare()
        // Set before the engine starts: a throw would otherwise leave the tap
        // installed with teardown() refusing to remove it.
        running = true
        do {
            try engine.start()
        } catch {
            teardown()
            throw error
        }
        // Armed only once the engine is up. AVAudioEngine posts a configuration
        // change from inside start() while its I/O unit settles — voice processing
        // makes that likelier still — and with the observer already armed that post
        // tore the microphone down the moment start() released the lock, after
        // reporting success. The recording then had a mic input nothing ever wrote
        // to: a silent track and a live toggle that did nothing.
        //
        // Unplugging the interface or dropping Bluetooth stops the engine without a
        // word, and the hardware format promised to the writer no longer holds. End
        // the microphone track deliberately and say so, rather than going quiet.
        // queue: nil runs the block on whatever thread posts, which may be one still
        // inside the lock — so the teardown is handed to a detached task and can
        // never re-enter the lock synchronously.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                Log.write("microphone: audio device changed or went away; the microphone track ends here")
                Task.detached { self?.stop() }
            }
        // Arming after start() closes one window and opens its mirror image: a device
        // that went away between the two would post to nobody, and the caller would
        // get a success for an engine that had already stopped. Ask the engine
        // directly rather than trust the gap — but do not treat a stopped engine as
        // a lost device. AVAudioEngine documents that it stops ITSELF when its I/O
        // unit sees the hardware channel count or sample rate change, which is
        // exactly what voice processing provokes while settling. Failing here would
        // quietly drop every such Mac back to the ScreenCaptureKit microphone and
        // leave the echo-cancellation switch inert.
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else {
            Log.write("microphone: engine would not stay running; falling back")
            teardown()
            throw NSError(domain: "Glimpse", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: L("error.no_microphone")])
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardown()
    }

    /// The lock is held by both callers; it covers the graph mutations too, which is
    /// the point.
    private func teardown() {
        guard running else { return }
        running = false
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func peak(of buffer: AVAudioPCMBuffer, channel: Int = 0) -> Float {
        guard let data = buffer.floatChannelData, channel < Int(buffer.format.channelCount) else { return -1 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][i])) }
        return peak
    }

    private static func makeSampleBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> CMSampleBuffer? {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return nil }
        let pts = time.isHostTimeValid
            ? CMClockMakeHostTimeFromSystemUnits(time.hostTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buffer.format.formatDescription,
                                   sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sb
    }
}
