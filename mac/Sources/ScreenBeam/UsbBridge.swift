import Foundation

/// Streams over a USB cable: whenever an Android phone with USB debugging is plugged in, runs
/// `adb reverse tcp:PORT tcp:PORT` so the phone reaches this Mac at 127.0.0.1 through the cable.
/// Steadier than Wi-Fi (no radio retries or scan spikes) and the phone charges while playing.
///
/// Event-driven: `adb track-devices` pushes the device list whenever it changes, so nothing polls.
/// Every other adb call has a timeout, so a hung adb can't stall the bridge.
final class UsbBridge {
    /// Serials of phones currently tunnelled. Fired on the main queue.
    var onDevicesChanged: (([String]) -> Void)?
    /// Whether adb was found. Fired on the main queue.
    var onAdbAvailability: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "screenbeam.usb", qos: .utility)
    private var adbPath: String?
    private var tracker: Process?
    private var buffer = Data()
    private var ready: Set<String> = []
    private var tunnelled: Set<String> = []
    private var published: [String]?
    private var port: UInt16 = 7878
    private var restartDelay: TimeInterval = 1
    private var stopped = false

    func start(port: UInt16) {
        queue.async {
            self.port = port
            self.locateAdbAndTrack()
        }
    }

    /// Synchronous so it finishes before the app exits.
    func stop() {
        queue.sync {
            self.stopped = true
            self.tracker?.terminate()
            try? FileManager.default.removeItem(at: Self.trackerPIDFile)
        }
    }

    /// Looks for adb again (e.g. it was installed after launch). Cheap; call when the window shows.
    func recheckAdb() {
        queue.async {
            guard self.adbPath == nil else { return }
            self.locateAdbAndTrack()
        }
    }

    func updatePort(_ port: UInt16) {
        queue.async {
            guard port != 0, port != self.port else { return }
            let old = self.port
            self.port = port
            for serial in self.tunnelled {
                _ = self.run(["-s", serial, "reverse", "--remove", "tcp:\(old)"], timeout: 5)
            }
            self.tunnelled.removeAll()  // re-create tunnels for the new port
            self.reconcile()
        }
    }

    // MARK: - Tracking (on `queue`)

    private func locateAdbAndTrack() {
        adbPath = Self.findAdb()
        let found = adbPath != nil
        Log.write("usb: adb \(adbPath ?? "not found")")
        DispatchQueue.main.async { self.onAdbAvailability?(found) }
        if found { startTracker() }
    }

    /// The tracker is a child process; if the app crashes or is force-quit, macOS leaves it running.
    /// Its PID is kept on disk so the next launch (or the crash watchdog) can stop the orphan.
    static let trackerPIDFile = Resilience.directory.appendingPathComponent("adb-tracker.pid")

    static func stopOrphanedTracker() {
        guard let text = try? String(contentsOf: trackerPIDFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        try? FileManager.default.removeItem(at: trackerPIDFile)
        // Only if that PID is still an adb process (PIDs get reused).
        var name = [CChar](repeating: 0, count: 64)
        if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "adb" {
            kill(pid, SIGTERM)
        }
    }

    private func startTracker() {
        guard let adbPath, !stopped, tracker == nil else { return }
        Self.stopOrphanedTracker()
        // Starts the adb server if needed; bounded so a wedged adb can't hang us here.
        _ = run(["start-server"], timeout: 10)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["track-devices"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            self.queue.async { self.received(data) }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async { self.trackerEnded() }
        }
        do {
            try p.run()
            tracker = p
            buffer.removeAll()
            try? FileManager.default.createDirectory(at: Resilience.directory, withIntermediateDirectories: true)
            try? String(p.processIdentifier).write(to: Self.trackerPIDFile, atomically: true, encoding: .utf8)
        } catch {
            Log.write("usb: couldn't start adb track-devices: \(error)")
            trackerEnded()
        }
    }

    /// adb's server restarted or adb was removed: tunnels are gone too. Retry with backoff.
    private func trackerEnded() {
        tracker = nil
        ready.removeAll()
        tunnelled.removeAll()
        publish()
        guard !stopped else { return }
        if adbPath.map({ !FileManager.default.isExecutableFile(atPath: $0) }) ?? true {
            adbPath = nil
            DispatchQueue.main.async { self.onAdbAvailability?(false) }
            return
        }
        let delay = restartDelay
        restartDelay = min(60, restartDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startTracker() }
    }

    /// track-devices output: 4 hex digits of length, then lines of "serial\tstate".
    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while buffer.count >= 4,
              let header = String(data: buffer.prefix(4), encoding: .ascii),
              let length = Int(header, radix: 16), length >= 0 {
            guard buffer.count >= 4 + length else { return }
            let body = String(decoding: buffer.dropFirst(4).prefix(length), as: UTF8.self)
            buffer = Data(buffer.dropFirst(4 + length))
            restartDelay = 1
            ready = Set(body.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "\t")
                // "unauthorized" means the phone hasn't accepted this Mac yet.
                return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
            })
            reconcile()
        }
        if buffer.count > 65_536 { buffer.removeAll() }  // garbage: resync on the next message
    }

    private func reconcile() {
        for serial in ready.subtracting(tunnelled) {
            if run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 8) != nil {
                Log.write("usb: tunnel ready for \(serial) on port \(port)")
                tunnelled.insert(serial)
            } else {
                Log.write("usb: couldn't create the tunnel for \(serial); will retry when it reconnects")
            }
        }
        tunnelled.formIntersection(ready)  // unplugged phones
        publish()
    }

    private func publish() {
        let list = tunnelled.sorted()
        guard list != published else { return }
        published = list
        DispatchQueue.main.async { self.onDevicesChanged?(list) }
    }

    /// Runs adb and returns stdout, or nil on failure or after `timeout` seconds (the process is killed).
    private func run(_ args: [String], timeout: TimeInterval) -> String? {
        guard let adbPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            Log.write("usb: adb \(args.first ?? "") timed out after \(Int(timeout)) s")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
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
