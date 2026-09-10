import Foundation
import Testing
@testable import Glimpse

@Suite("Recording quality")
struct RecordingQualityTests {
    /// High is the setting the app shipped with before the picker existed, and must
    /// stay bit-for-bit what it was: 0.12 bits per pixel, floored at 2 Mbit/s and
    /// capped at 60.
    @Test func highReproducesTheOriginalFormula() {
        for (w, h, fps) in [(1280, 720, 30), (1920, 1080, 30), (3840, 2160, 30), (3840, 2160, 60)] {
            let original = min(max(Int(Double(w * h) * Double(fps) * 0.12), 2_000_000), 60_000_000)
            #expect(RecordingQuality.high.bitrate(width: w, height: h, framerate: fps) == original)
        }
    }

    @Test func lowerLevelsAskForLess() {
        let w = 1920, h = 1080, fps = 30
        let high = RecordingQuality.high.bitrate(width: w, height: h, framerate: fps)
        let balanced = RecordingQuality.balanced.bitrate(width: w, height: h, framerate: fps)
        let small = RecordingQuality.small.bitrate(width: w, height: h, framerate: fps)
        #expect(balanced < high)
        #expect(small < balanced)
        // Halving the bits per pixel must actually halve the request, not be eaten
        // by a floor that did not scale with the level.
        #expect(balanced == high / 2)
    }

    /// The floor exists so a small capture is not encoded into mush; without it a
    /// 320x240 clip at Small would ask for 69 kbit/s.
    @Test func theFloorAppliesAndScalesWithTheLevel() {
        for quality in RecordingQuality.allCases {
            let tiny = quality.bitrate(width: 320, height: 240, framerate: 10)
            #expect(tiny == quality.minimumBitrate)
        }
        #expect(RecordingQuality.small.minimumBitrate < RecordingQuality.balanced.minimumBitrate)
        #expect(RecordingQuality.balanced.minimumBitrate < RecordingQuality.high.minimumBitrate)
    }

    /// 5K at 60 would otherwise ask for 106 Mbit/s, which no hardware encoder here
    /// will honour and which fills a disk in minutes.
    @Test func theCeilingApplies() {
        #expect(RecordingQuality.high.bitrate(width: 5120, height: 2880, framerate: 60) == 60_000_000)
    }

    @Test func everyLevelSurvivesAStorageRoundTrip() {
        for quality in RecordingQuality.allCases {
            #expect(RecordingQuality(rawValue: quality.rawValue) == quality)
        }
        #expect(RecordingQuality(rawValue: "nonsense") == nil)
    }
}
