import Foundation

/// Plain-text diagnostics in ~/Library/Logs/Glimpse.log (unified logging redacts
/// everything dynamic, which makes recorder problems impossible to debug from a report).
enum Log {
    static let url: URL = {
        // Same trap AppSettings guards against: this can be empty in a restricted
        // container, and it is touched on the launch path.
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let logs = library.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("Glimpse.log")
        // Readable only by its owner: it is a diagnostic file the user may be asked
        // to share, but not with anyone else on the machine. Created here, because
        // setting the mode on a path that does not exist yet silently does nothing.
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            FileManager.default.createFile(atPath: file.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        return file
    }()
    private static let queue = DispatchQueue(label: "Glimpse.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Same trap as the file names: a fixed format needs a fixed locale, or the
        // timestamps in a bug report come back in era years.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// A few lines per recording, but the file would otherwise live forever.
    private static let maxBytes = 512 * 1024

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            trimIfOversized()
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else if !FileManager.default.fileExists(atPath: url.path) {
                // Only when there is no log yet — writing unconditionally would replace
                // the whole history with one line whenever opening the file failed. And
                // with the mode set, or deleting the log while the app runs quietly
                // recreates it world-readable.
                FileManager.default.createFile(atPath: url.path, contents: line.data(using: .utf8),
                                               attributes: [.posixPermissions: 0o600])
            }
        }
    }

    /// Keeps the newest half of the file: the last lines are the ones that explain
    /// whatever just went wrong.
    private static func trimIfOversized() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        // Drop the leading partial line so the file still parses line by line.
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: url)
    }
}
