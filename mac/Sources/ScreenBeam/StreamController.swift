import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct StreamSettings: Equatable {
    enum CodecPreference: Int { case auto = 0, hevc = 1, h264 = 2 }

    var displayID: UInt32 = 0      // 0 = main display
    var bitrateMbps: Int = 40
    var fps: Int = 60
    var maxHeight: Int = 0         // 0 = native
    var codec: CodecPreference = .auto
    var gamingMode = true          // lowest latency; false = sharpest (native res, deeper encoder pipeline)
    /// Mac speakers while the phone plays sound: synced = both play, Mac delayed to match the phone.
    enum MacSpeakers: Int { case synced = 0, muted = 1, normal = 2 }
    var macSpeakers: MacSpeakers = .synced

    private static let defaults = UserDefaults.standard

    static func load() -> StreamSettings {
        var s = StreamSettings()
        // Values are clamped: a hand-edited or corrupted preference must never crash the app.
        if let v = defaults.object(forKey: "displayID") as? Int { s.displayID = UInt32(truncatingIfNeeded: max(0, v)) }
        if let v = defaults.object(forKey: "bitrateMbps") as? Int { s.bitrateMbps = min(200, max(2, v)) }
        if let v = defaults.object(forKey: "fps") as? Int { s.fps = min(120, max(15, v)) }
        if let v = defaults.object(forKey: "maxHeight") as? Int { s.maxHeight = min(4320, max(0, v)) }
        if let v = defaults.object(forKey: "codec") as? Int, let c = CodecPreference(rawValue: v) { s.codec = c }
        if let v = defaults.object(forKey: "gamingMode") as? Bool { s.gamingMode = v }
        if let v = defaults.object(forKey: "macSpeakers") as? Int, let m = MacSpeakers(rawValue: v) { s.macSpeakers = m }
        return s
    }

    func save() {
        let d = Self.defaults
        d.set(Int(displayID), forKey: "displayID")
        d.set(bitrateMbps, forKey: "bitrateMbps")
        d.set(fps, forKey: "fps")
        d.set(maxHeight, forKey: "maxHeight")
        d.set(codec.rawValue, forKey: "codec")
        d.set(gamingMode, forKey: "gamingMode")
        d.set(macSpeakers.rawValue, forKey: "macSpeakers")
    }
}

enum StreamStatus: Equatable {
    case starting
    case waiting(port: UInt16)
    case streaming(device: String, width: Int, height: Int, codec: String, fps: Int)
    case controller(device: String)
    case sound(device: String)
    case failed(String)
}

/// Owns the capture → encode → send pipeline for the connected phone.
final class StreamController {
    let server = StreamServer()
    private let input = InputInjector()
    private let inputQueue = DispatchQueue(label: "screenbeam.input", qos: .userInteractive)

    /// Fired on the main queue.
    var onStatus: ((StreamStatus) -> Void)?

    private let pipeline = DispatchQueue(label: "screenbeam.pipeline", qos: .userInteractive)

    // Pipeline-queue state.
    private var settings = StreamSettings.load()
    private var hello: ClientHello?
    private var generation = 0
    private var capture: CaptureEngine?
    private var audioTap: AnyObject?  // SystemAudioTap (macOS 14.2+)
    private var macPlayer: SyncedMacPlayer?
    private var encoder: VideoEncoder?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast
    private var refreshesSent = 0
    private var refreshTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var port: UInt16 = 0

    // Extended mode: the phone-shaped virtual display. Kept for a short while after the phone
    // disconnects, so a reconnect doesn't send every window on it back to the main screen.
    private var virtualDisplay: VirtualDisplay?
    private var virtualDisplaySize = (0, 0)
    private var virtualDisplayRelease: DispatchWorkItem?
    private var ignoreDisplayChangesUntil = Date.distantPast

    private let audioSetupQueue = DispatchQueue(label: "screenbeam.audio-setup")
    private var audioSetupStuck = false
    /// Safe mode (after repeated crashes): no system sound capture. Set before `start()`.
    var safeMode = false

    // Flow control: frames encoded but not yet confirmed on the phone's screen, by pts µs.
    // Capping this bounds glass-to-glass latency: when the phone or Wi-Fi falls behind we
    // stop feeding the encoder (no queue builds, and nothing has to be repaired with a keyframe).
    private var usesAcks = false
    private var inFlight: [UInt64: Date] = [:]
    private var frameWindow = 4
    private var lastPTS = CMTime.invalid
    private var lastEncodedPTS: UInt64 = 0
    private var skippedSinceEncode = false
    private var drainScheduled = false

    // Adaptive bitrate + stats (per one-second window).
    private var targetBitrate = 0
    private var currentBitrate = 0
    private var statEncoded = 0
    private var statSkipped = 0
    private var latencies: [Double] = []

    func start() {
        server.onListening = { [weak self] port in
            self?.pipeline.async {
                guard let self else { return }
                self.port = port
                if self.hello == nil { self.publish(.waiting(port: port)) }
            }
        }
        server.onClientReady = { [weak self] hello in
            self?.pipeline.async { self?.startSession(hello) }
        }
        server.onClientGone = { [weak self] in
            self?.pipeline.async {
                guard let self else { return }
                self.hello = nil
                self.inputQueue.async { self.input.releaseAll() }
                self.teardown()
                self.releaseVirtualDisplay(after: 20)
                self.publish(.waiting(port: self.port))
            }
        }
        server.onKeyframeNeeded = { [weak self] in
            self?.pipeline.async { self?.sendKeyframeNow() }
        }
        server.onAck = { [weak self] pts in
            self?.pipeline.async { self?.handleAck(pts) }
        }
        server.onInput = { [weak self] type, payload in
            guard let self else { return }
            self.inputQueue.async { self.input.handle(type, payload) }
        }
        server.validatePairing = { Pairing.matches($0) }
        input.onUntrustedInput = { [weak self] in
            self?.server.sendNotice("Your Mac isn't letting ScreenBeam control it yet. On the Mac: System Settings → Privacy & Security → Accessibility → turn on ScreenBeam.")
        }
        server.onPhoneAudioLatency = { [weak self] ms in
            // Phone delay (receipt → speaker) + ~1 ms transit; the player subtracts the Mac's own output delay.
            self?.pipeline.async { self?.macPlayer?.setPhoneLatency(Double(ms + 1) / 1000) }
        }
        publish(.starting)
        server.start()
    }

    func update(_ newSettings: StreamSettings) {
        newSettings.save()
        pipeline.async {
            guard newSettings != self.settings else { return }
            self.settings = newSettings
            self.restartIfStreaming()
        }
    }

    /// Re-negotiates capture (display changes, wake from sleep, settings changes).
    func restartIfStreaming() {
        pipeline.async {
            if let hello = self.hello { self.startSession(hello) }
        }
    }

    /// Displays changed, the Mac woke, or the audio device changed: restart the stream so it picks up
    /// the new setup. Ignores the display change our own virtual display just caused.
    func environmentChanged() {
        pipeline.async {
            guard Date() > self.ignoreDisplayChangesUntil, let hello = self.hello else { return }
            Log.write("displays, wake or audio device changed: restarting the stream")
            self.startSession(hello)
        }
    }

    func disconnect() { server.disconnectClient() }

    // MARK: - Session lifecycle (pipeline queue)

    private func startSession(_ hello: ClientHello) {
        teardown()
        self.hello = hello
        // Phones from v5 get low-latency Core Audio tap audio; if the tap can't start, video sessions
        // fall back to ScreenCaptureKit audio (≈55 ms later).
        var useCaptureAudio = hello.wantsAudio
        if hello.wantsAudio && hello.version >= 5 && safeMode {
            Log.write("safe mode: system sound capture is off; using capture audio")
        } else if hello.wantsAudio && hello.version >= 5 && audioSetupStuck {
            Log.write("audio tap skipped: an earlier Core Audio call still hasn't returned")
        } else if hello.wantsAudio && hello.version >= 5, #available(macOS 14.2, *) {
            if let (tap, player) = startAudioWithTimeout(macSpeakers: settings.macSpeakers) {
                audioTap = tap
                macPlayer = player
                useCaptureAudio = false
                if let player {
                    Log.write(String(format: "Mac speakers synced to phone (Mac output latency %.1f ms)",
                                     player.macOutputLatency * 1000))
                }
            }
        }
        if hello.controllerOnly {
            releaseVirtualDisplay(after: 0)
            // No video: phone is a gamepad (Pad) and/or a speaker (Sound). No capture or encoding.
            let displayID = settings.displayID == 0 ? CGMainDisplayID() : settings.displayID
            inputQueue.async { self.input.displayID = displayID }
            if hello.wantsAudio && audioTap == nil {
                server.sendError("Sound needs macOS 14.2 or later and System Audio Recording permission for ScreenBeam.")
            }
            Log.write("session: \(hello.deviceName) v\(hello.version) no video, sound=\(audioTap != nil) soundOnly=\(hello.soundOnly)")
            publish(hello.soundOnly ? .sound(device: hello.deviceName) : .controller(device: hello.deviceName))
            return
        }
        let gen = generation
        let s = settings
        var captureDisplay = s.displayID
        var newDisplay = false
        if hello.extendDisplay {
            let previous = virtualDisplay
            guard let vd = ensureVirtualDisplay(for: hello) else {
                let message = "Couldn't create a second screen on this Mac."
                server.sendError(message)
                publish(.failed(message))
                return
            }
            captureDisplay = vd.displayID
            newDisplay = vd !== previous
        } else {
            releaseVirtualDisplay(after: 0)
        }
        let deviceLabel = hello.extendDisplay ? "\(hello.deviceName) (second screen)" : hello.deviceName
        server.congestionLimit = max(4_000_000, s.bitrateMbps * 1_000_000 / 8 / 2)
        usesAcks = hello.sendsAcks
        frameWindow = max(3, s.fps / 15)  // ≈ 66 ms of frames at 60 fps
        targetBitrate = s.bitrateMbps * 1_000_000
        currentBitrate = targetBitrate

        Task { [weak self] in
            guard let self else { return }
            do {
                // A brand-new display switches modes once just after it appears; capture after that.
                if newDisplay { try await Task.sleep(nanoseconds: 600_000_000) }
                let filter = try await CaptureEngine.makeFilter(displayID: captureDisplay,
                                                                waitForDisplay: hello.extendDisplay)
                let displayID = (captureDisplay == 0 ? CGMainDisplayID() : captureDisplay)
                self.inputQueue.async { self.input.displayID = displayID }
                var codec = Self.chooseCodec(s.codec, hello, gaming: s.gamingMode)
                // Gaming: fit the phone's screen (the encoder is ~4x faster at 1440p than at Retina size).
                let maxHeight = s.gamingMode && s.maxHeight == 0 ? 1440 : s.maxHeight
                var native = CaptureEngine.nativePixelSize(of: filter)
                // The filter's scale lags behind a just-created display; its current mode doesn't.
                if hello.extendDisplay, let mode = CGDisplayCopyDisplayMode(displayID) {
                    native = (mode.pixelWidth, mode.pixelHeight)
                }
                var (w, h) = Self.outputSize(native: native, hello: hello, codec: codec, maxHeight: maxHeight)
                let encoder: VideoEncoder
                do {
                    encoder = try VideoEncoder(codec: codec, width: w, height: h, fps: s.fps,
                                               bitrate: s.bitrateMbps * 1_000_000,
                                               flushEachFrame: s.gamingMode)
                } catch where codec == .hevc && hello.supportsH264 {
                    // Older Macs (e.g. Intel without an HEVC encoder): every Mac can encode H.264.
                    Log.write("HEVC encoder unavailable (\(error)), falling back to H.264")
                    codec = .h264
                    (w, h) = Self.outputSize(native: native, hello: hello, codec: codec, maxHeight: maxHeight)
                    encoder = try VideoEncoder(codec: codec, width: w, height: h, fps: s.fps,
                                               bitrate: s.bitrateMbps * 1_000_000,
                                               flushEachFrame: s.gamingMode)
                }
                Log.write("session: \(deviceLabel) v\(hello.version) \(w)x\(h) \(codec.name) \(s.fps)fps \(s.bitrateMbps)Mbps gaming=\(s.gamingMode)")
                encoder.onEncoded = { [weak self] config, frame, isKey in
                    self?.server.send(config: config, frame: frame, isKeyframe: isKey)
                }
                let capture = CaptureEngine(queue: self.pipeline)

                let installed = self.pipeline.sync { () -> Bool in
                    guard gen == self.generation else { return false }
                    self.encoder = encoder
                    self.capture = capture
                    capture.onFrame = { [weak self] pb, pts in self?.handleFrame(pb, pts, gen) }
                    capture.onAudio = { [weak self] sb in
                        if let payload = AudioPacker.pack(sb) { self?.server.sendAudio(payload) }
                    }
                    capture.onStop = { [weak self] error in
                        // System interrupted capture (display gone, lock screen...). Try again shortly.
                        Log.write("capture stopped by macOS (\(error)); restarting in 1 s")
                        self?.pipeline.asyncAfter(deadline: .now() + 1) {
                            guard let self, gen == self.generation, let hello = self.hello else { return }
                            self.startSession(hello)
                        }
                    }
                    return true
                }
                guard installed else { return }

                try await capture.start(filter: filter, width: w, height: h, fps: s.fps, audio: useCaptureAudio)

                self.pipeline.async {
                    guard gen == self.generation else {
                        Task { await capture.stop() }
                        return
                    }
                    self.startRefreshTimer(gen)
                    self.startStatsTimer(gen)
                    self.publish(.streaming(device: deviceLabel, width: w, height: h,
                                            codec: codec.name, fps: s.fps))
                }
            } catch {
                self.pipeline.async {
                    guard gen == self.generation else { return }
                    let message = Self.describe(error)
                    NSLog("ScreenBeam: failed to start stream: \(error)")
                    self.server.sendError(message)
                    self.teardown()
                    self.publish(.failed(message))
                }
            }
        }
    }

    /// Creates the system-sound tap (and, for "both in sync", the Mac's own delayed player) on a
    /// separate queue, waiting at most 2 s. Core Audio calls can hang (seen after the app was quit and
    /// reopened quickly); then this session streams without the tap instead of freezing the pipeline.
    /// A late success is stopped, and no new tap is tried until the stuck call returns.
    @available(macOS 14.2, *)
    private func startAudioWithTimeout(macSpeakers: StreamSettings.MacSpeakers) -> (SystemAudioTap, SyncedMacPlayer?)? {
        final class Job { var tap: SystemAudioTap?; var player: SyncedMacPlayer?; var error: Error?; var abandoned = false }
        let job = Job()
        let done = DispatchSemaphore(value: 0)
        audioSetupStuck = true
        audioSetupQueue.async { [weak self] in
            let tap = SystemAudioTap()
            tap.onPacket = { [weak self] payload in self?.server.sendAudio(payload, type: .audioLowLatency) }
            // The player must exist before the tap so this process can be excluded from it
            // (else our own delayed playback would loop back to the phone).
            var player: SyncedMacPlayer?
            var exclude: [AudioObjectID] = []
            if macSpeakers == .synced {
                let p = SyncedMacPlayer()
                do {
                    try p.start()
                    if let me = SyncedMacPlayer.currentProcessObject() {
                        exclude = [me]
                        player = p
                    } else {
                        p.stop()
                        Log.write("synced Mac playback unavailable: process not registered with Core Audio")
                    }
                } catch {
                    Log.write("synced Mac playback failed: \(error)")
                }
            }
            if let player { tap.onFloatStereo = { player.push($0, frames: $1) } }
            do {
                try tap.start(muteMac: macSpeakers == .muted || player != nil, exclude: exclude)
                job.tap = tap
                job.player = player
            } catch {
                player?.stop()
                job.error = error
            }
            done.signal()
            self?.pipeline.async {
                self?.audioSetupStuck = false
                guard job.abandoned else { return }
                Log.write("audio tap: the stuck Core Audio call finally returned; stopping it")
                self?.audioSetupQueue.async { Self.stopAudio(job.tap, job.player) }
            }
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            job.abandoned = true
            Log.write("audio tap unavailable (Core Audio didn't answer within 2 s); using capture audio")
            return nil
        }
        audioSetupStuck = false
        if let error = job.error { Log.write("audio tap unavailable (\(error)); using capture audio") }
        guard let tap = job.tap else { return nil }
        return (tap, job.player)
    }

    /// Stop first, then drop the callbacks (they're read on Core Audio's thread until it stops).
    @available(macOS 14.2, *)
    private static func stopAudio(_ tap: SystemAudioTap?, _ player: SyncedMacPlayer?) {
        tap?.stop()
        tap?.onPacket = nil
        tap?.onFloatStereo = nil
        player?.stop()
    }

    /// Reuses the virtual display if it already matches the phone, else makes a new one.
    private func ensureVirtualDisplay(for hello: ClientHello) -> VirtualDisplay? {
        virtualDisplayRelease?.cancel()
        virtualDisplayRelease = nil
        // Landscape; phones too old to report their screen get a common 20:9 size.
        // Clamped: the size comes from the network, and no phone is bigger than 8K.
        let size = hello.screenWidth > 0 && hello.screenHeight > 0
            ? (min(7680, max(hello.screenWidth, hello.screenHeight)), min(4320, min(hello.screenWidth, hello.screenHeight)))
            : (2400, 1080)
        if let vd = virtualDisplay, virtualDisplaySize == size { return vd }
        virtualDisplay = nil
        ignoreDisplayChangesUntil = Date().addingTimeInterval(3)
        virtualDisplay = VirtualDisplay(pixelWidth: size.0, pixelHeight: size.1, name: "\(hello.deviceName) (ScreenBeam)")
        virtualDisplaySize = size
        return virtualDisplay
    }

    private func releaseVirtualDisplay(after seconds: Double) {
        virtualDisplayRelease?.cancel()
        virtualDisplayRelease = nil
        guard virtualDisplay != nil else { return }
        if seconds <= 0 {
            ignoreDisplayChangesUntil = Date().addingTimeInterval(3)
            virtualDisplay = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.ignoreDisplayChangesUntil = Date().addingTimeInterval(3)
            self?.virtualDisplay = nil
            self?.virtualDisplayRelease = nil
        }
        virtualDisplayRelease = work
        pipeline.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func teardown() {
        generation += 1
        // Off the pipeline: stopping Core Audio objects can hang too.
        if #available(macOS 14.2, *), let tap = audioTap as? SystemAudioTap {
            let player = macPlayer
            audioSetupQueue.async { Self.stopAudio(tap, player) }
        }
        audioTap = nil
        macPlayer = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
        inFlight.removeAll()
        lastPTS = .invalid
        lastEncodedPTS = 0
        skippedSinceEncode = false
        drainScheduled = false
        statEncoded = 0
        statSkipped = 0
        latencies.removeAll()
        if let capture {
            capture.onFrame = nil
            capture.onAudio = nil
            capture.onStop = nil
            Task { await capture.stop() }
        }
        capture = nil
        // Stop first: VideoToolbox calls onEncoded on its own thread until the session is invalidated.
        encoder?.invalidate()
        encoder?.onEncoded = nil
        encoder = nil
        lastPixelBuffer = nil
    }

    private func handleFrame(_ pb: CVPixelBuffer, _ pts: CMTime, _ gen: Int) {
        guard gen == generation else { return }
        lastPixelBuffer = pb
        lastPTS = pts
        lastFrameAt = Date()
        refreshesSent = 0
        // Coalesce: if frames arrived while the encoder was busy, encode only the newest one.
        guard !drainScheduled else { return }
        drainScheduled = true
        pipeline.async { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            guard gen == self.generation, let latest = self.lastPixelBuffer else { return }
            self.submit(latest, pts: self.lastPTS)
        }
    }

    /// Encodes a frame unless the phone is already `frameWindow` frames behind.
    @discardableResult
    private func submit(_ pb: CVPixelBuffer, pts: CMTime, force: Bool = false) -> Bool {
        guard let encoder else { return false }
        if usesAcks {
            let stale = Date().addingTimeInterval(-0.5)  // acks lost (e.g. decoder dropped a frame)
            inFlight = inFlight.filter { $0.value > stale }
            if !force && inFlight.count >= frameWindow {
                statSkipped += 1
                skippedSinceEncode = true
                return false
            }
        }
        // Timestamps must strictly increase for the encoder and be unique for ack matching.
        var micros = VideoEncoder.micros(pts)
        var time = pts
        if micros <= lastEncodedPTS {
            micros = lastEncodedPTS + 1
            time = CMTime(value: CMTimeValue(micros), timescale: 1_000_000)
        }
        lastEncodedPTS = micros
        if usesAcks { inFlight[micros] = Date() }
        skippedSinceEncode = false
        statEncoded += 1
        encoder.encode(pb, pts: time)
        return true
    }

    private func handleAck(_ pts: UInt64) {
        guard inFlight.removeValue(forKey: pts) != nil else { return }
        let now = VideoEncoder.micros(CMClockGetTime(CMClockGetHostTimeClock()))
        if now > pts { latencies.append(Double(now - pts) / 1000) }
        // The phone caught up: send the newest screen right away instead of waiting for the next capture.
        if skippedSinceEncode, let pb = lastPixelBuffer {
            submit(pb, pts: lastPTS)
        }
    }

    private func sendKeyframeNow() {
        guard let encoder else { return }
        encoder.requestKeyframe()
        // Screen may be static (no new frames coming), so re-encode the last one immediately.
        if let pb = lastPixelBuffer {
            submit(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()), force: true)
        }
    }

    /// Once a second: adapt bitrate to what the Wi-Fi sustains, and report stats to the phone.
    private func startStatsTimer(_ gen: Int) {
        let t = DispatchSource.makeTimerSource(queue: pipeline)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, gen == self.generation else { return }
            let sorted = self.latencies.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let total = self.statEncoded + self.statSkipped
            let skipRatio = total > 0 ? Double(self.statSkipped) / Double(total) : 0

            if self.usesAcks && total > 10 {
                if skipRatio > 0.2 || median > 120 {
                    self.setBitrate(max(self.targetBitrate / 6, Int(Double(self.currentBitrate) * 0.7)))
                } else if skipRatio < 0.05 && median < 70 && self.currentBitrate < self.targetBitrate {
                    self.setBitrate(min(self.targetBitrate, Int(Double(self.currentBitrate) * 1.15)))
                }
            }
            self.server.sendStats(latencyMs: Int(median.rounded()), bitrateKbps: self.currentBitrate / 1000,
                                  fps: self.statEncoded, skipped: self.statSkipped)
            self.statEncoded = 0
            self.statSkipped = 0
            self.latencies.removeAll(keepingCapacity: true)
        }
        t.resume()
        statsTimer = t
    }

    private func setBitrate(_ bps: Int) {
        guard bps != currentBitrate else { return }
        currentBitrate = bps
        encoder?.setBitrate(bps)
    }

    /// When the screen goes still, re-encode the last frame a few times. Each pass lets the
    /// rate controller spend bits refining detail, so static text sharpens to near-lossless.
    private func startRefreshTimer(_ gen: Int) {
        let t = DispatchSource.makeTimerSource(queue: pipeline)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, gen == self.generation, self.encoder != nil,
                  let pb = self.lastPixelBuffer, self.refreshesSent < 4,
                  Date().timeIntervalSince(self.lastFrameAt) > 0.2
            else { return }
            if self.submit(pb, pts: CMClockGetTime(CMClockGetHostTimeClock())) { self.refreshesSent += 1 }
        }
        t.resume()
        refreshTimer = t
    }

    private func publish(_ status: StreamStatus) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    // MARK: - Negotiation

    private static func chooseCodec(_ pref: StreamSettings.CodecPreference, _ hello: ClientHello,
                                    gaming: Bool) -> VideoCodec {
        switch pref {
        case .h264: return hello.supportsH264 || !hello.supportsHEVC ? .h264 : .hevc
        case .hevc: return hello.supportsHEVC ? .hevc : .h264
        // Automatic: H.264 encodes ~40% faster here (latency); HEVC is sharper per bit (quality).
        case .auto: return gaming || !hello.supportsHEVC ? .h264 : .hevc
        }
    }

    static func outputSize(native: (width: Int, height: Int), hello: ClientHello,
                           codec: VideoCodec, maxHeight: Int) -> (Int, Int) {
        var maxW = Double(hello.maxWidth > 0 ? hello.maxWidth : 3840)
        var maxH = Double(hello.maxHeight > 0 ? hello.maxHeight : 2160)
        if codec == .h264 { maxW = min(maxW, 4096); maxH = min(maxH, 2304) }
        if maxHeight > 0 { maxH = min(maxH, Double(maxHeight)) }

        let w = Double(max(native.width, 2)), h = Double(max(native.height, 2))
        let scale = min(1, maxW / w, maxH / h)
        let even = { (v: Double) in max(2, Int(v * scale) & ~1) }
        return (even(w), even(h))
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        Log.write("start failed: domain=\(ns.domain) code=\(ns.code) preflight=\(CGPreflightScreenCaptureAccess()) \(ns)")
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
            return "The Mac needs Screen Recording permission. On the Mac: System Settings → Privacy & Security → Screen & System Audio Recording → enable ScreenBeam, then quit and reopen ScreenBeam."
        }
        return "\(error.localizedDescription) (\(ns.domain) \(ns.code))"
    }
}

extension StreamStatus {
    var isActive: Bool {
        switch self {
        case .streaming, .controller, .sound: return true
        default: return false
        }
    }
}
