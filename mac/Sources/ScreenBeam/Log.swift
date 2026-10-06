import Foundation

/// Appends diagnostics to ~/Library/Logs/ScreenBeam.log (readable in Console.app).
///
/// Safe to call from any thread, including real-time audio: the caller only enqueues; formatting,
/// NSLog and file I/O happen on a background queue. The file is rotated at 5 MB (one old copy kept
/// as ScreenBeam.1.log), so it can't grow without bound.
enum Log {
    private static let queue = DispatchQueue(label: "screenbeam.log", qos: .utility)
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenBeam.log")
    private static let maxBytes: UInt64 = 5 * 1024 * 1024
    private static let formatter = ISO8601DateFormatter()  // only used on `queue`
    private static var handle: FileHandle?

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            NSLog("ScreenBeam: %@", message)
            append("\(formatter.string(from: now)) \(message)\n")
        }
    }

    /// Blocks until queued lines are on disk (used just before an intentional exit).
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        try? h.write(contentsOf: Data(line.utf8))
        if let size = try? h.offset(), size > maxBytes {
            try? h.close()
            handle = nil
            let old = url.deletingLastPathComponent().appendingPathComponent("ScreenBeam.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }
}
