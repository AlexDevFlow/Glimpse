import AppKit
import ScreenCaptureKit

/// AppKit uses a bottom-left origin on the primary screen; CoreGraphics / ScreenCaptureKit
/// use a top-left origin. These helpers convert between the two global spaces.
enum ScreenSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension SCShareableContent {
    func display(for screen: NSScreen) -> SCDisplay? {
        displays.first { $0.displayID == screen.displayID }
    }

    var currentApplication: SCRunningApplication? {
        applications.first { $0.processID == getpid() }
    }
}

extension CGRect {
    /// Rounded to whole points, sizes forced even (H.264 wants even dimensions).
    var evenPixelAligned: CGRect {
        var r = integral
        if Int(r.width) % 2 != 0 { r.size.width -= 1 }
        if Int(r.height) % 2 != 0 { r.size.height -= 1 }
        return r
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    // An invalid CMTime yields NaN, and Int(nan) traps.
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let s = Int(seconds.rounded(.down))
    if s >= 3600 {
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A fixed format needs a fixed locale and calendar, or a user on a Japanese or
/// Buddhist calendar gets era years in their file names. Exposed so a test can
/// constrain it — asserting on the output alone only tests the host's locale.
func timestampFormatter() -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return f
}

func timestampedFileName(prefix: String, ext: String) -> String {
    "\(prefix) \(timestampFormatter().string(from: Date())).\(ext)"
}

/// Adds " (2)", " (3)"… when something is already there. The name carries seconds,
/// so two captures inside one second collide — and the recorder actively removes
/// whatever sits at its output URL, which would destroy the earlier file.
func uniqueURL(_ url: URL) -> URL {
    let files = FileManager.default
    guard files.fileExists(atPath: url.path) else { return url }
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    let folder = url.deletingLastPathComponent()
    for n in 2...999 {
        let candidate = folder.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
        if !files.fileExists(atPath: candidate.path) { return candidate }
    }
    // Never hand back the colliding URL: the recorder removes whatever sits there.
    return folder.appendingPathComponent("\(stem) \(UUID().uuidString)").appendingPathExtension(ext)
}
