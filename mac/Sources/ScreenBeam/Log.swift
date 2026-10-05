import Foundation

/// Appends diagnostics to ~/Library/Logs/ScreenBeam.log (readable in Console.app).
enum Log {
    private static let queue = DispatchQueue(label: "screenbeam.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenBeam.log")

    static func write(_ message: String) {
        NSLog("ScreenBeam: \(message)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
