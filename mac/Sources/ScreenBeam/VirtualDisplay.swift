import CoreGraphics
import Foundation
import VirtualDisplayBridge

/// A virtual monitor shaped like the phone, so the phone can be a second screen instead of a mirror.
///
/// macOS has no public API for this; CGVirtualDisplay is the private CoreGraphics class that
/// display utilities and Chromium's tests use. The display exists for as long as this object does.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    private let display: CGVirtualDisplay

    /// `pixelWidth` × `pixelHeight` is the phone's screen in landscape.
    init?(pixelWidth: Int, pixelHeight: Int, name: String) {
        let w = max(640, pixelWidth) & ~1, h = max(360, pixelHeight) & ~1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "ScreenBeam.virtual-display")
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        // About 460 ppi, a typical large phone.
        descriptor.sizeInMillimeters = CGSize(width: Double(w) / 460 * 25.4, height: Double(h) / 460 * 25.4)
        // Fixed IDs: macOS remembers where the user put this display and puts it back there next time.
        descriptor.vendorID = 0x5342
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in Log.write("virtual display: terminated by the system") }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            Log.write("virtual display: could not be created")
            return nil
        }

        // Retina modes, all the phone's shape. The first is the default: about 2.4 pixels per point,
        // so text is a readable size on a phone. Bigger or smaller text: System Settings → Displays.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [2.4, 2.0, 3.0].map { scale in
            CGVirtualDisplayMode(width: UInt32(Double(w) / scale) & ~1,
                                 height: UInt32(Double(h) / scale) & ~1, refreshRate: 60)
        }
        guard display.apply(settings) else {
            Log.write("virtual display: settings rejected")
            return nil
        }
        self.display = display
        displayID = display.displayID
        self.pixelWidth = w
        self.pixelHeight = h
        Log.write("virtual display \(displayID) created for \(w)x\(h) pixels")
    }

    deinit {
        Log.write("virtual display \(displayID) removed")
    }
}
