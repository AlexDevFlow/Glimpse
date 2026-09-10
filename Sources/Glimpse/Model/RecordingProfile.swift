import AVFoundation

/// Output container + codec, the macOS counterpart of Kooha's profiles.yml.
struct RecordingProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let fileExtension: String
    let codec: AVVideoCodecType
    let fileType: AVFileType
    let suggestedMaxFPS: Int

    static let all: [RecordingProfile] = [
        RecordingProfile(id: "mp4-h264", name: "MP4 (H.264)", fileExtension: "mp4",
                         codec: .h264, fileType: .mp4, suggestedMaxFPS: 60),
        RecordingProfile(id: "mp4-hevc", name: "MP4 (HEVC)", fileExtension: "mp4",
                         codec: .hevc, fileType: .mp4, suggestedMaxFPS: 60),
        RecordingProfile(id: "mov-h264", name: "QuickTime (H.264)", fileExtension: "mov",
                         codec: .h264, fileType: .mov, suggestedMaxFPS: 60),
        RecordingProfile(id: "mov-hevc", name: "QuickTime (HEVC)", fileExtension: "mov",
                         codec: .hevc, fileType: .mov, suggestedMaxFPS: 60),
    ]

    static let framerates: [Int] = [10, 20, 24, 25, 30, 48, 50, 60]
}

/// How much bitrate a recording is allowed. Screen content is mostly flat colour,
/// static regions and sharp text, so it compresses far better than the natural
/// video an encoder's defaults assume — measured at 1080p30 on screen-like
/// content, halving the budget cost about 1 dB PSNR while cutting the file by a
/// third. The floor scales with the level so a small capture is not dragged back
/// up to the high setting's minimum.
enum RecordingQuality: String, CaseIterable, Identifiable {
    case high, balanced, small

    var id: String { rawValue }

    /// Bits per pixel per frame.
    var bitsPerPixel: Double {
        switch self {
        case .high: return 0.12
        case .balanced: return 0.06
        case .small: return 0.03
        }
    }

    var minimumBitrate: Int {
        switch self {
        case .high: return 2_000_000
        case .balanced: return 1_200_000
        case .small: return 800_000
        }
    }

    var displayName: String {
        switch self {
        case .high: return L("prefs.quality.high")
        case .balanced: return L("prefs.quality.balanced")
        case .small: return L("prefs.quality.small")
        }
    }

    func bitrate(width: Int, height: Int, framerate: Int) -> Int {
        let target = Double(width * height * framerate) * bitsPerPixel
        return min(max(Int(target), minimumBitrate), 60_000_000)
    }
}
