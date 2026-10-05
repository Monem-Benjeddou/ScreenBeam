import AVFoundation
import CoreMedia

/// Converts ScreenCaptureKit's float audio into the wire format: u64 pts µs + interleaved s16le stereo.
/// Uncompressed PCM is ~1.5 Mbps, trivial on a LAN or USB, and adds no codec delay.
enum AudioPacker {
    static func pack(_ sb: CMSampleBuffer) -> Data? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)
        else { return nil }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let frames = CMSampleBufferGetNumSamples(sb)
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var out = Data(capacity: 8 + frames * 4)
        out.appendBE(VideoEncoder.micros(CMSampleBufferGetPresentationTimeStamp(sb)))
        var pcm = [Int16](repeating: 0, count: frames * 2)

        func sample(_ channel: Int, _ frame: Int) -> Float {
            let ch = min(channel, channels - 1)
            if interleaved {
                guard let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                return p[frame * channels + ch]
            }
            guard ch < buffers.count, let p = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            return p[frame]
        }
        for f in 0..<frames {
            for c in 0..<2 {
                let v = max(-1, min(1, sample(c, f)))
                pcm[f * 2 + c] = Int16(v * 32767).littleEndian
            }
        }
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }
}
