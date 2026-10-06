import AppKit
import ScreenCaptureKit

// Diagnostic: `ScreenBeam --virtual-display-test 3120 1440` creates a phone-shaped virtual display,
// reports what macOS made of it, and exits.
if let i = CommandLine.arguments.firstIndex(of: "--virtual-display-test") {
    let args = CommandLine.arguments.dropFirst(i + 1).compactMap { Int($0) }
    let w = args.first ?? 3120, h = args.dropFirst().first ?? 1440
    guard let vd = VirtualDisplay(pixelWidth: w, pixelHeight: h, name: "ScreenBeam Test") else {
        print("FAILED: could not create a virtual display"); exit(1)
    }
    Task {
        for attempt in 1...20 {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content?.displays.first(where: { $0.displayID == vd.displayID }) {
                let mode = CGDisplayCopyDisplayMode(vd.displayID)
                print("display \(vd.displayID): \(d.width)x\(d.height) points, " +
                      "mode \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) pixels, " +
                      "bounds \(CGDisplayBounds(vd.displayID)), visible to capture after \(attempt * 100) ms")
                exit(0)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("FAILED: display \(vd.displayID) never appeared to ScreenCaptureKit"); exit(1)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)  // Dock icon + window; menu bar icon stays too
app.run()
