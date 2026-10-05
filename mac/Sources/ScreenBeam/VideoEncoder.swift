import CoreMedia
import Foundation
import VideoToolbox

enum VideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2

    var name: String { self == .hevc ? "HEVC" : "H.264" }
    var cmType: CMVideoCodecType { self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }
}

enum EncoderError: LocalizedError {
    case sessionCreate(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreate(let s): return "Could not start the hardware video encoder (error \(s))."
        }
    }
}

/// Hardware encoder tuned for screen content: real-time, no B-frames, keyframes on demand.
/// `encode` and `requestKeyframe` must be called from one serial queue.
final class VideoEncoder {
    let codec: VideoCodec
    let width: Int
    let height: Int
    private let fps: Int
    private let bitrate: Int
    /// Force each frame out of the encoder before the next one. The hardware otherwise keeps a
    /// ~9 frame pipeline (≈150 ms on an M1 Pro); flushing trades peak throughput for latency.
    private let flushEachFrame: Bool

    /// Called on a VideoToolbox thread. `config` is set on keyframes (parameter sets payload).
    var onEncoded: ((_ config: Data?, _ frame: Data, _ isKeyframe: Bool) -> Void)?

    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private(set) var lowLatencyMode = false

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int, flushEachFrame: Bool) throws {
        self.flushEachFrame = flushEachFrame
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        try buildSession()
    }

    deinit { invalidate() }

    func requestKeyframe() { forceKeyframe = true }

    /// Adjusts the target bitrate on the fly (adaptive quality); takes effect within a frame or two.
    func setBitrate(_ bps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [Int(Double(bps) / 8.0 * 1.5), 1] as CFArray)
    }

    /// The pts in µs as sent on the wire (and echoed back in acks).
    static func micros(_ pts: CMTime) -> UInt64 {
        pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if session == nil { try? buildSession() }
        guard let session else { return }

        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            forceKeyframe = false
        }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
        if status == noErr && flushEachFrame {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        }
        if status == kVTInvalidSessionErr {
            // Happens after sleep / GPU resets: rebuild and restart with a keyframe.
            NSLog("ScreenBeam: encoder session invalidated, rebuilding")
            invalidate()
            forceKeyframe = true
        }
    }

    // MARK: - Session

    private func buildSession() throws {
        let hw = kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true, hw: true],
            [hw: true],
            [:],
        ]
        var lastStatus: OSStatus = noErr
        for (i, spec) in specs.enumerated() {
            var s: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codec.cmType, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if lastStatus == noErr, let s {
                session = s
                lowLatencyMode = i == 0
                Log.write("encoder \(codec.name) \(width)x\(height) created, lowLatencyRateControl=\(i == 0)")
                configure(s)
                VTCompressionSessionPrepareToEncodeFrames(s)
                forceKeyframe = true
                return
            }
        }
        throw EncoderError.sessionCreate(lastStatus)
    }

    private func configure(_ s: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if st != noErr { NSLog("ScreenBeam: encoder property \(key) not applied (\(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        let burstBytes = Int(Double(bitrate) / 8.0 * 1.5)
        set(kVTCompressionPropertyKey_DataRateLimits, [burstBytes, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
        // Tag colors so the phone decodes with the same matrix the capture used.
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    // MARK: - Output

    private func emit(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        var config: Data?
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            config = configPayload(fmt)
        }
        guard let frame = framePayload(sb, isKey: isKey) else { return }
        onEncoded?(config, frame, isKey)
    }

    private func configPayload(_ fmt: CMFormatDescription) -> Data? {
        var sets: [Data] = []
        var count = 0
        var index = 0
        repeat {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st: OSStatus
            if codec == .hevc {
                st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard st == noErr, let ptr else { return nil }
            sets.append(Data(bytes: ptr, count: size))
            index += 1
        } while index < count

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        var d = Data()
        d.append(codec.rawValue)
        d.appendBE(UInt32(dims.width))
        d.appendBE(UInt32(dims.height))
        d.append(UInt8(sets.count))
        for s in sets {
            d.appendBE(UInt32(s.count))
            d.append(s)
        }
        return d
    }

    /// Converts the AVCC (length-prefixed) sample into an Annex-B access unit.
    private func framePayload(_ sb: CMSampleBuffer, isKey: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return nil }
        var avcc = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &avcc) == noErr else {
            return nil
        }

        let ptsMicros = Self.micros(CMSampleBufferGetPresentationTimeStamp(sb))

        var out = Data(capacity: total + 64)
        out.append(isKey ? 1 : 0)
        out.appendBE(ptsMicros)
        var i = 0
        while i + 4 <= total {
            let len = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            guard len > 0, i + len <= total else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: avcc[i..<i + len])
            i += len
        }
        return out
    }
}
