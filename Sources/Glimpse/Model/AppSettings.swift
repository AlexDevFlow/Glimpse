import Carbon
import Foundation
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case monitorWindow = "monitor-window"
    case selection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitorWindow: return L("mode.normal")
        case .selection: return L("mode.selection")
        }
    }

    var help: String {
        switch self {
        case .monitorWindow: return L("mode.normal.help")
        case .selection: return L("mode.selection.help")
        }
    }

    var symbol: String {
        switch self {
        case .monitorWindow: return "macwindow.on.rectangle"
        case .selection: return "dot.viewfinder"
        }
    }
}

enum ScreenshotFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// Persisted user settings. Mirrors Kooha's gschema keys plus the screenshot side.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Written straight to `AppleLanguages`; macOS reads it at the next launch.
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "app-language")
            language.apply()
        }
    }

    @Published var captureMode: CaptureMode { didSet { defaults.set(captureMode.rawValue, forKey: "capture-mode") } }
    @Published var recordDesktopAudio: Bool { didSet { defaults.set(recordDesktopAudio, forKey: "record-desktop-audio") } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: "record-microphone") } }
    @Published var showPointer: Bool { didSet { defaults.set(showPointer, forKey: "show-pointer") } }
    @Published var microphoneEchoCancellation: Bool { didSet { defaults.set(microphoneEchoCancellation, forKey: "mic-echo-cancellation") } }
    @Published var recordDelay: Int { didSet { defaults.set(recordDelay, forKey: "record-delay") } }
    @Published var profileID: String { didSet { defaults.set(profileID, forKey: "profile-id") } }
    @Published var framerate: Int { didSet { defaults.set(framerate, forKey: "framerate") } }
    @Published var quality: RecordingQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var recordingsFolder: URL { didSet { defaults.set(recordingsFolder.path, forKey: "saving-location") } }

    @Published var screenshotsFolder: URL { didSet { defaults.set(screenshotsFolder.path, forKey: "screenshot-location") } }
    @Published var screenshotFormat: ScreenshotFormat { didSet { defaults.set(screenshotFormat.rawValue, forKey: "screenshot-format") } }
    @Published var screenshotCopiesToClipboard: Bool { didSet { defaults.set(screenshotCopiesToClipboard, forKey: "screenshot-copy") } }
    @Published var screenshotShowsPointer: Bool { didSet { defaults.set(screenshotShowsPointer, forKey: "screenshot-pointer") } }
    @Published var screenshotPlaysSound: Bool { didSet { defaults.set(screenshotPlaysSound, forKey: "screenshot-sound") } }
    @Published var showPreviewAfterCapture: Bool { didSet { defaults.set(showPreviewAfterCapture, forKey: "show-preview") } }
    @Published var askWhereToSave: Bool { didSet { defaults.set(askWhereToSave, forKey: "ask-where-to-save") } }

    @Published var screenshotHotKey: KeyCombo { didSet { defaults.set(screenshotHotKey.encoded, forKey: "hotkey-screenshot") } }
    @Published var recordHotKey: KeyCombo { didSet { defaults.set(recordHotKey.encoded, forKey: "hotkey-record") } }

    /// Last rectangle used in selection mode, in AppKit screen coordinates.
    @Published var lastSelection: CGRect? {
        didSet {
            if let r = lastSelection {
                defaults.set([r.origin.x, r.origin.y, r.size.width, r.size.height], forKey: "selection")
            } else {
                defaults.removeObject(forKey: "selection")
            }
        }
    }

    var profile: RecordingProfile {
        RecordingProfile.all.first { $0.id == profileID } ?? RecordingProfile.all[0]
    }

    private init() {
        let d = defaults
        language = AppLanguage(rawValue: d.string(forKey: "app-language") ?? "") ?? .system
        captureMode = CaptureMode(rawValue: d.string(forKey: "capture-mode") ?? "") ?? .monitorWindow
        recordDesktopAudio = d.object(forKey: "record-desktop-audio") as? Bool ?? true
        recordMicrophone = d.bool(forKey: "record-microphone")
        showPointer = d.object(forKey: "show-pointer") as? Bool ?? true
        microphoneEchoCancellation = d.object(forKey: "mic-echo-cancellation") as? Bool ?? true
        // Hand-edited defaults reach these directly; an out-of-range frame rate
        // traps in CMTimeScale, and an absurd delay hangs the countdown.
        recordDelay = min(max(d.integer(forKey: "record-delay"), 0), 30)
        // The Picker binds to the raw id, so an unknown one renders an empty row.
        let storedProfile = d.string(forKey: "profile-id") ?? ""
        profileID = RecordingProfile.all.contains { $0.id == storedProfile }
            ? storedProfile : RecordingProfile.all[0].id
        let storedFramerate = d.object(forKey: "framerate") as? Int ?? 30
        framerate = RecordingProfile.framerates.contains(storedFramerate) ? storedFramerate : 30
        // Balanced by default: on screen content it costs about a decibel of PSNR
        // and takes roughly a third off the file. The old fixed setting is still
        // there as High for anyone who wants it.
        quality = RecordingQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .balanced

        // These can come back empty in a managed or restricted container, and this
        // runs on the launch path — a force unwrap here is a crash with no recovery.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Movies")
        // An empty or non-absolute stored value resolves to the process's working
        // directory — "/" for a launched app — and every save then silently
        // retargets and fails.
        func folder(_ key: String, fallback: URL) -> URL {
            guard let stored = d.string(forKey: key), stored.hasPrefix("/") else { return fallback }
            // Shape is not enough: "/etc/hosts" is absolute and exists but is a file,
            // and "/" is a directory nobody can write to. Either one turns every
            // capture into a failure and both folder menu items into no-ops.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: stored, isDirectory: &isDirectory)
            if exists && !isDirectory.boolValue { return fallback }
            if exists && !FileManager.default.isWritableFile(atPath: stored) { return fallback }
            return URL(fileURLWithPath: stored)
        }
        recordingsFolder = folder("saving-location", fallback: movies)
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Pictures")
        screenshotsFolder = folder("screenshot-location",
                                   fallback: pictures.appendingPathComponent("Screenshots"))

        screenshotFormat = ScreenshotFormat(rawValue: d.string(forKey: "screenshot-format") ?? "") ?? .png
        screenshotCopiesToClipboard = d.object(forKey: "screenshot-copy") as? Bool ?? true
        screenshotShowsPointer = d.bool(forKey: "screenshot-pointer")
        screenshotPlaysSound = d.object(forKey: "screenshot-sound") as? Bool ?? true
        showPreviewAfterCapture = d.object(forKey: "show-preview") as? Bool ?? true
        askWhereToSave = d.bool(forKey: "ask-where-to-save")

        // A stored combination the recorder would now refuse (no modifier, or shift
        // only) decodes to nil and falls back to the default. If the OTHER shortcut
        // happens to be sitting on that default, the two collide, Carbon refuses the
        // second, and it dies behind a warning triangle — so put the loser back on
        // its own default rather than leaving both on one combination.
        let storedScreenshot = KeyCombo(encoded: d.string(forKey: "hotkey-screenshot"))
        let storedRecord = KeyCombo(encoded: d.string(forKey: "hotkey-record"))
        var screenshot = storedScreenshot ?? KeyCombo.defaultScreenshot
        var record = storedRecord ?? KeyCombo.defaultRecord
        if screenshot == record {
            // Move whichever side did NOT come from the user's own stored value; if
            // both did, the record one gives way. Assigning the default it already
            // holds — which an earlier attempt at this did — changes nothing.
            let alternatives = [KeyCombo.defaultRecord, KeyCombo.defaultScreenshot,
                                KeyCombo(keyCode: UInt32(kVK_F19), modifiers: [])]
            if storedScreenshot == nil, let free = alternatives.first(where: { $0 != record }) {
                screenshot = free
            } else if let free = alternatives.first(where: { $0 != screenshot }) {
                record = free
            }
        }
        screenshotHotKey = screenshot
        recordHotKey = record
        // didSet does not fire during init, so a refused value would otherwise stay
        // in defaults for ever and be refused again on every launch.
        // Write back only what actually changed, and never a value that still
        // collides — persisting a collision would make it survive a reinstall.
        if screenshot != record {
            if storedScreenshot != screenshot { d.set(screenshot.encoded, forKey: "hotkey-screenshot") }
            if storedRecord != record { d.set(record.encoded, forKey: "hotkey-record") }
        }

        if let a = d.array(forKey: "selection") as? [Double], a.count == 4 {
            lastSelection = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        } else {
            lastSelection = nil
        }
    }
}
