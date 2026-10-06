import SystemConfiguration
import Foundation

/// 6-digit code the phone must present. Protects the Mac's screen and input from anyone else on the Wi-Fi.
enum Pairing {
    /// The Mac's name as set in System Settings. Local lookup (unlike Host.current(), which can
    /// block for seconds on DNS).
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
    }

    private static let key = "pairingCode"

    static var code: String {
        if let c = UserDefaults.standard.string(forKey: key), c.count == 6 { return c }
        return regenerate()
    }

    @discardableResult
    static func regenerate() -> String {
        let c = String(format: "%06d", Int.random(in: 0..<1_000_000))
        UserDefaults.standard.set(c, forKey: key)
        return c
    }

    /// True once any phone has paired successfully (drives the setup checklist).
    static var pairedOnce: Bool { UserDefaults.standard.bool(forKey: "pairedOnce") }

    static func matches(_ candidate: String) -> Bool {
        let expected = Array(code.utf8), given = Array(candidate.utf8)
        guard expected.count == given.count else { return false }
        let ok = zip(expected, given).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0  // constant-time compare
        if ok && !pairedOnce { UserDefaults.standard.set(true, forKey: "pairedOnce") }
        return ok
    }
}

import AppKit
import CoreImage

/// QR code the phone scans to pair and connect in one step:
/// screenbeam://pair?name=<Mac name>&ips=<a,b>&port=<port>&code=<6 digits>
enum PairingQR {
    static func payload(addresses: [String], port: UInt16, code: String) -> String {
        var c = URLComponents()
        c.scheme = "screenbeam"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "name", value: Pairing.computerName),
            URLQueryItem(name: "ips", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        return c.string ?? ""
    }

    static func image(addresses: [String], port: UInt16, code: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload(addresses: addresses, port: port, code: code).utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
