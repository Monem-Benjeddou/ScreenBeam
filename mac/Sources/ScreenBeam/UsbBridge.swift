import Foundation

/// Streams over a USB cable: whenever an Android phone with USB debugging is plugged in, runs
/// `adb reverse tcp:PORT tcp:PORT` so the phone reaches this Mac at 127.0.0.1 through the cable.
/// Steadier than Wi-Fi (no radio retries or scan spikes) and the phone charges while playing.
final class UsbBridge {
    /// Serials of phones currently tunnelled. Fired on the main queue.
    var onDevicesChanged: (([String]) -> Void)?
    private(set) var adbPath: String?

    private let queue = DispatchQueue(label: "screenbeam.usb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tunnelled: Set<String> = []
    private var published: [String]?
    private var port: UInt16 = 7878

    func start(port: UInt16) {
        queue.async {
            self.port = port
            self.adbPath = Self.findAdb()
            Log.write("usb: adb \(self.adbPath ?? "not found")")
            guard self.adbPath != nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 2)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    func updatePort(_ port: UInt16) {
        queue.async {
            guard port != 0, port != self.port else { return }
            self.port = port
            self.tunnelled.removeAll() // re-create tunnels for the new port
        }
    }

    private func poll() {
        guard let out = run(["devices"]) else { return }
        // Lines look like "R5CX12345\tdevice"; "unauthorized" means the phone hasn't accepted the Mac yet.
        let ready = Set(out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t")
            return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
        })
        for serial in ready.subtracting(tunnelled) {
            if run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]) != nil {
                Log.write("usb: tunnel ready for \(serial) on port \(port)")
                tunnelled.insert(serial)
            }
        }
        tunnelled.formIntersection(ready) // unplugged phones
        let list = tunnelled.sorted()
        if list != published {
            published = list
            DispatchQueue.main.async { self.onDevicesChanged?(list) }
        }
    }

    private func run(_ args: [String]) -> String? {
        guard let adbPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func findAdb() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
