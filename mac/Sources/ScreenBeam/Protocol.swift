import Foundation

/// Wire protocol shared with the Android app.
/// Every message: [u8 type][u32 big-endian payload length][payload].
enum MessageType: UInt8 {
    // phone -> mac
    case hello = 1            // "SBM1", u8 version, u8 codecMask, u32 maxW, u32 maxH, u16 nameLen, name, u8 pinLen, pin (v3), u8 flags (v4: 1 = no video, 2 = wants audio, 4 = sound-only mode)
    case keyframeRequest = 2  // empty
    case ping = 3             // u64 opaque timestamp
    case ack = 4              // u64 pts µs of a frame the phone has put on screen (protocol v2+)
    case audioHello = 5       // "SBA1", u8 pinLen, pin -- opens the dedicated audio connection (v6+)
    case audioLatency = 6     // u16 ms: phone's playout delay from receipt to speaker (on the audio connection)

    // phone -> mac remote input (v3+, paired phones only)
    case mouseMove = 20       // i16 dx, i16 dy (points, relative)
    case mouseMoveAbsolute = 21 // u16 x, u16 y (0...65535 across the streamed display)
    case mouseButton = 22     // u8 button (0 left, 1 right, 2 middle), u8 down
    case scroll = 23          // i16 dx, i16 dy (pixels)
    case key = 24             // u16 macOS virtual key code, u8 down
    case text = 25            // UTF-8 text to type

    // mac -> phone
    case config = 10          // u8 codec, u32 w, u32 h, u8 count, (u32 len, NAL)* -- parameter sets, no start codes
    case frame = 11           // u8 flags (1 = keyframe), u64 pts µs, Annex-B access unit
    case pong = 12            // echoes ping payload
    case error = 13           // u8 code (1 = retry, 2 = stop, 3 = pairing code needed), UTF-8 message
    case stats = 14           // u16 end-to-end latency ms, u32 bitrate kbps, u16 encoded fps, u16 skipped fps
    case audio = 15           // u64 pts µs, PCM s16le stereo 48 kHz
    case ready = 16           // hello accepted (lets controller-only phones know they're live)
    case audioLowLatency = 17 // u32 sample rate, PCM s16le stereo (Core Audio tap, v5+ phones)
    /// A message for the person holding the phone (UTF-8); the session continues. Older phones ignore it.
    case notice = 18
}

enum Wire {
    static let magic: [UInt8] = Array("SBM1".utf8)
    static let maxIncomingPayload = 64 * 1024

    enum ErrorCode: UInt8 { case retry = 1, stop = 2, pairing = 3 }

    static func errorPayload(_ message: String, code: ErrorCode) -> Data {
        var d = Data([code.rawValue])
        d.append(Data(message.utf8))
        return d
    }

    static func header(_ type: MessageType, length: Int) -> Data {
        var d = Data(capacity: 5)
        d.append(type.rawValue)
        d.appendBE(UInt32(length))
        return d
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

/// Minimal big-endian reader over a byte array.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var v: T = 0
        for i in 0..<size { v = (v << 8) | T(bytes[offset + i]) }
        offset += size
        return v
    }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
}

struct ClientHello {
    let version: UInt8
    let codecMask: UInt8   // bit 0 = H.264, bit 1 = HEVC
    let maxWidth: Int
    let maxHeight: Int
    let deviceName: String
    let pairingCode: String
    let flags: UInt8
    let screenWidth: Int
    let screenHeight: Int

    /// No video: the phone is a controller (Pad mode) and/or a speaker (Sound mode).
    var controllerOnly: Bool { flags & 1 != 0 }
    var wantsAudio: Bool { flags & 2 != 0 }
    var soundOnly: Bool { flags & 4 != 0 }
    /** v7: the phone is a second screen (a virtual display), not a mirror of an existing one. */
    var extendDisplay: Bool { flags & 8 != 0 }

    var supportsHEVC: Bool { codecMask & 0b10 != 0 }
    var supportsH264: Bool { codecMask & 0b01 != 0 }
    /// v2 phones acknowledge every displayed frame, which enables latency-bounded flow control.
    var sendsAcks: Bool { version >= 2 }

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard r.take(4) == Wire.magic,
              let version = r.u8(), version >= 1,
              let mask = r.u8(),
              let w = r.uint(UInt32.self),
              let h = r.uint(UInt32.self)
        else { return nil }
        self.version = version
        codecMask = mask
        maxWidth = Int(w)
        maxHeight = Int(h)
        if let len = r.uint(UInt16.self), let name = r.take(Int(len)) {
            deviceName = String(decoding: name, as: UTF8.self)
        } else {
            deviceName = "Phone"
        }
        if let len = r.u8(), let pin = r.take(Int(len)) {
            pairingCode = String(decoding: pin, as: UTF8.self)
        } else {
            pairingCode = ""
        }
        flags = r.u8() ?? 0
        // v7+: the phone's screen in pixels, sizing the virtual display for extended mode.
        screenWidth = r.uint(UInt16.self).map(Int.init) ?? 0
        screenHeight = r.uint(UInt16.self).map(Int.init) ?? 0
    }
}
