import AudioToolbox
import CoreAudio
import Foundation

/// Low-latency system audio via a Core Audio process tap (macOS 14.2+).
/// ScreenCaptureKit's audio arrives ~55 ms late in 20 ms chunks; a tap delivers each hardware
/// I/O cycle (a few ms) as it happens. Packets: u32 sample rate + interleaved s16le stereo.
@available(macOS 14.2, *)
final class SystemAudioTap {
    /// Called on the tap's real-time queue with a ready-to-send payload.
    var onPacket: ((Data) -> Void)?
    /// Called on the tap's queue with interleaved float stereo (for the Mac's synced playback).
    var onFloatStereo: ((UnsafePointer<Float>, Int) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "screenbeam.audiotap", qos: .userInteractive)
    private var format = AudioStreamBasicDescription()
    // Diagnostics (tap queue only): packets and peak level, logged every 5 s.
    private var statPackets = 0
    private var statPeak: Int16 = 0
    private var statSince = Date()

    enum TapError: Error { case failed(String, OSStatus) }

    /// `muteMac` silences normal output while tapping (the Mac then plays nothing, or our synced copy).
    /// `exclude` keeps processes out of the tap: ScreenBeam's own synced playback must not loop back.
    func start(muteMac: Bool, exclude: [AudioObjectID] = []) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "ScreenBeam"
        description.isPrivate = true
        description.muteBehavior = muteMac ? .mutedWhenTapped : .unmuted

        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ScreenBeam Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // Small I/O cycles = small packets = low latency (256 frames ≈ 5 ms at 48 kHz).
        var frames: UInt32 = 256
        address.mSelector = kAudioDevicePropertyBufferFrameSize
        address.mScope = kAudioObjectPropertyScopeGlobal
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.handle(input)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
        Log.write("audio tap started: flags=\(format.mFormatFlags) bits=\(format.mBitsPerChannel) \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, \(frames)-frame cycles")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private var rawCallbacks = 0
    private var rawLogged = false

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        rawCallbacks += 1
        if !rawLogged && rawCallbacks >= 200 {
            rawLogged = true
            let sizes = buffers.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
            Log.write("audio tap raw: \(rawCallbacks) callbacks, \(buffers.count) buffers [\(sizes)], flags=\(format.mFormatFlags) bits=\(format.mBitsPerChannel)")
        }
        guard let first = buffers.first, first.mDataByteSize > 0,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { return }
        let channels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let frames = interleaved ? Int(first.mDataByteSize) / 4 / channels : Int(first.mDataByteSize) / 4

        var out = Data(capacity: 4 + frames * 4)
        out.appendBE(UInt32(format.mSampleRate))
        var pcm = [Int16](repeating: 0, count: frames * 2)
        var stereo = [Float](repeating: 0, count: frames * 2)
        for c in 0..<2 {
            let ch = min(c, channels - 1)
            let buffer = interleaved ? buffers[0] : buffers[min(ch, buffers.count - 1)]
            guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames {
                let v = interleaved ? p[f * channels + ch] : p[f]
                stereo[f * 2 + c] = v
                pcm[f * 2 + c] = Int16(max(-1, min(1, v)) * 32767).littleEndian
            }
        }
        if let onFloatStereo { stereo.withUnsafeBufferPointer { onFloatStereo($0.baseAddress!, frames) } }
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        statPackets += 1
        statPeak = max(statPeak, pcm.map { $0 == .min ? .max : abs($0) }.max() ?? 0)
        if Date().timeIntervalSince(statSince) > 5 {
            Log.write("audio tap: \(statPackets) packets/5s, \(frames) frames each, peak \(statPeak)\(statPeak == 0 ? " (silent: playing nothing, or permission missing)" : "")")
            statPackets = 0; statPeak = 0; statSince = Date()
        }
        onPacket?(out)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw TapError.failed(step, status)
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.failed("default output", status) }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.failed("output uid", status) }
        return uid as String
    }
}
