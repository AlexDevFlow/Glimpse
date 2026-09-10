import Foundation
import Testing
@testable import Glimpse

/// `make check` guards the .strings files against each other. These guard what it
/// cannot see: that the Language picker and the shipped .lproj folders agree.
@Suite("Localization")
struct LocalizationTests {
    private var localizationDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/GlimpseTests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization")
    }

    @Test func everyOfferedLanguageShipsATranslation() {
        for language in AppLanguage.allCases where language != .system {
            let strings = localizationDirectory
                .appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
            #expect(FileManager.default.fileExists(atPath: strings.path),
                    "AppLanguage.\(language) has no \(language.rawValue).lproj")
        }
    }

    @Test func everyShippedTranslationIsOffered() throws {
        let offered = Set(AppLanguage.allCases.map(\.rawValue))
        let shipped = try FileManager.default
            .contentsOfDirectory(atPath: localizationDirectory.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
        #expect(!shipped.isEmpty)
        for code in shipped {
            #expect(offered.contains(code), "\(code).lproj is missing from the Language picker")
        }
    }

    /// The picker is unusable if entries are named in a language the reader cannot
    /// read, so every entry but "follow the system" is an endonym.
    @Test func languagesAreNamedInTheirOwnLanguage() {
        for language in AppLanguage.allCases where language != .system {
            #expect(!language.displayName.isEmpty)
            #expect(language.displayName != language.rawValue)
        }
    }
}

@Suite("Recording profiles")
struct RecordingProfileTests {
    @Test func profileIDsAreUnique() {
        let ids = RecordingProfile.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func extensionMatchesContainer() {
        for profile in RecordingProfile.all {
            #expect(profile.fileExtension == (profile.fileType == .mp4 ? "mp4" : "mov"), "\(profile.id)")
        }
    }

    @Test func framerateChoicesAreSortedAndSupported() {
        #expect(RecordingProfile.framerates == RecordingProfile.framerates.sorted())
        let highest = RecordingProfile.all.map(\.suggestedMaxFPS).max()!
        #expect(RecordingProfile.framerates.last! <= highest)
    }
}
