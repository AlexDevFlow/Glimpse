import ScreenCaptureKit

/// Wraps the system content sharing picker (macOS 14+) into a single async call,
/// the way Kooha talks to the xdg screencast portal.
@MainActor
final class SourcePicker: NSObject, SCContentSharingPickerObserver {
    static let shared = SourcePicker()

    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    func pick() async throws -> SCContentFilter {
        if continuation != nil { throw RecordingError.alreadyRunning }
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        config.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            config.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = config
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        picker.present()
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    /// Call when the recording is over so the system sharing indicator goes away.
    func deactivate() {
        SCContentSharingPicker.shared.isActive = false
        // Resume anyone still awaiting a pick: dropping the continuation here left
        // pick() suspended forever and every later attempt throwing alreadyRunning.
        finish(.failure(RecordingError.cancelled))
    }

    private func finish(_ result: Result<SCContentFilter, Error>) {
        let cont = continuation
        continuation = nil
        SCContentSharingPicker.shared.remove(self)
        cont?.resume(with: result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.finish(.failure(RecordingError.cancelled))
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.finish(.success(filter)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.finish(.failure(RecordingError.failed(error)))
            SCContentSharingPicker.shared.isActive = false
        }
    }
}
