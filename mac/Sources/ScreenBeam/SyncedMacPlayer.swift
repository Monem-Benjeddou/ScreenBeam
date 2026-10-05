import AVFoundation
import CoreAudio
import Foundation

/// Plays the tapped system audio on the Mac's own speakers, delayed to line up with the phone.
///
/// The phone can't play earlier than the network and its audio hardware allow, so instead the Mac
/// plays later: the tap mutes normal output, and this player re-plays the same samples delayed by the
/// phone's measured playout latency minus the Mac's own output latency (multi-room speaker style).
/// Delay changes are applied by playing up to ±1 % faster/slower, which is inaudible.
final class SyncedMacPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()

    // Ring buffer of interleaved float stereo, 2 s.
    private let capacity: Int
    private var ring: [Float]
    private var writeFrame: Int = 0        // total frames written
    private var readFrame: Double = 0      // total frames read (fractional)
    private var targetDelayFrames: Double
    private var started = false
    let sampleRate: Double

    init() {
        // Match the Mac's output device rate (the tap delivers at the same rate).
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
            ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 48_000
        capacity = Int(sampleRate * 2)
        ring = [Float](repeating: 0, count: capacity * 2)
        targetDelayFrames = sampleRate * 0.08
    }

    /// Starts the output engine. Call before creating the tap, so this process exists as an
    /// audio object and can be excluded from it (otherwise our own playback would be re-tapped).
    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
            self?.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }

    /// The Mac's own output delay (driver + device + buffer), to subtract from the phone's.
    var macOutputLatency: Double { engine.outputNode.presentationLatency }

    /// Phone playout latency (receipt → speaker) in seconds, plus transit.
    func setPhoneLatency(_ seconds: Double) {
        let delay = max(0, seconds - macOutputLatency)
        lock.lock()
        targetDelayFrames = delay * sampleRate
        lock.unlock()
    }

    /// Called from the tap's I/O with interleaved float stereo.
    func push(_ samples: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        for f in 0..<frames {
            let i = ((writeFrame + f) % capacity) * 2
            ring[i] = samples[f * 2]
            ring[i + 1] = samples[f * 2 + 1]
        }
        writeFrame += frames
        if !started && Double(writeFrame) >= targetDelayFrames {
            readFrame = Double(writeFrame) - targetDelayFrames
            started = true
        }
    }

    private func render(_ frames: Int, _ buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        guard started else {
            for f in 0..<frames { left[f] = 0; right[f] = 0 }
            return
        }
        let currentDelay = Double(writeFrame) - readFrame
        // Far off (e.g. the phone's latency jumped): resync immediately.
        if abs(currentDelay - targetDelayFrames) > sampleRate * 0.25 || currentDelay < 2 {
            readFrame = max(0, Double(writeFrame) - targetDelayFrames)
        }
        let error = (Double(writeFrame) - readFrame - targetDelayFrames) / max(targetDelayFrames, sampleRate * 0.01)
        let rate = 1 + min(0.01, max(-0.01, error * 0.02))
        for f in 0..<frames {
            let p = readFrame
            let i0 = Int(p)
            if i0 + 1 >= writeFrame {
                left[f] = 0; right[f] = 0
                continue
            }
            let t = Float(p - Double(i0))
            let a = (i0 % capacity) * 2, b = ((i0 + 1) % capacity) * 2
            left[f] = ring[a] * (1 - t) + ring[b] * t
            right[f] = ring[a + 1] * (1 - t) + ring[b + 1] * t
            readFrame += rate
        }
    }

    /// Core Audio object for this process, used to exclude it from the system tap.
    static func currentProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
