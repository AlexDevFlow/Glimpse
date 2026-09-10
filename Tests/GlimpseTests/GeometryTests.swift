import Foundation
import Testing
@testable import Glimpse

@Suite("Geometry and formatting")
struct GeometryTests {
    @Test(arguments: [
        (0.0, "00:00"),
        (9.9, "00:09"),      // truncated, never rounded up
        (59.0, "00:59"),
        (60.0, "01:00"),
        (3599.0, "59:59"),
        (3600.0, "01:00:00"),
        (3661.0, "01:01:01"),
    ])
    func durationSwitchesToHoursOnlyWhenNeeded(seconds: TimeInterval, expected: String) {
        #expect(formatDuration(seconds) == expected)
    }

    /// H.264 rejects odd dimensions. `integral` rounds outward first, so a rect can
    /// grow by up to a point before its sides are trimmed to even — the invariant is
    /// evenness, not shrinkage.
    @Test(arguments: [
        CGRect(x: 10.4, y: 20.6, width: 101.2, height: 99.8),
        CGRect(x: 0, y: 0, width: 3, height: 5),
        CGRect(x: -1.5, y: -2.5, width: 7.1, height: 9.9),
        CGRect(x: 0.5, y: 0.5, width: 1, height: 1),
    ])
    func evenPixelAlignedMakesBothSidesEven(rect: CGRect) {
        let aligned = rect.evenPixelAligned
        #expect(Int(aligned.width) % 2 == 0, "\(rect) -> \(aligned)")
        #expect(Int(aligned.height) % 2 == 0, "\(rect) -> \(aligned)")
    }

    @Test func durationSurvivesNonFiniteInput() {
        // An invalid CMTime yields NaN, and Int(nan) traps.
        #expect(formatDuration(.nan) == "00:00")
        #expect(formatDuration(.infinity) == "00:00")
        #expect(formatDuration(-5) == "00:00")
    }

    @Test func evenPixelAlignedLeavesEvenRectAlone() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(rect.evenPixelAligned == rect)
    }

    @Test func timestampedFileNameIsSafeToSave() {
        let name = timestampedFileName(prefix: "Screenshot", ext: "png")
        #expect(name.hasPrefix("Screenshot "))
        #expect(name.hasSuffix(".png"))
        // "/" and ":" would break the save or show up mangled in the Finder.
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    /// A fixed date format without a pinned locale yields era years on a Japanese or
    /// Buddhist calendar. Asserting on the output alone only tests the host's own
    /// locale — on a Gregorian machine, which every CI runner is, dropping the pin
    /// changes nothing. So constrain the formatter, and prove it against a calendar
    /// that would differ.
    @Test func timestampFormatterIsPinnedRegardlessOfTheHost() {
        let formatter = timestampFormatter()
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.locale?.identifier == "en_US_POSIX")

        let buddhist = DateFormatter()
        buddhist.locale = Locale(identifier: "th_TH")
        buddhist.calendar = Calendar(identifier: .buddhist)
        buddhist.dateFormat = "yyyy"
        let now = Date()
        #expect(formatter.string(from: now).prefix(4) != buddhist.string(from: now).prefix(4),
                "the pinned formatter must not follow a non-Gregorian calendar")
    }

    @Test func uniqueURLStepsAsideForAnExistingFile() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glimpse-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("Shot.png")
        #expect(uniqueURL(first) == first)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        // Two captures inside one second share a name; the second must not overwrite.
        #expect(uniqueURL(first).lastPathComponent == "Shot (2).png")
    }
}
