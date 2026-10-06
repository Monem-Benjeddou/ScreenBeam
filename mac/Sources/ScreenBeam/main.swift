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

// Demo-data render of the window (for checks and README screenshots); see WindowPreview.
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > i + 1 {
    let args = CommandLine.arguments
    let ok = MainActor.assumeIsolated {
        WindowPreview.render(to: args[i + 1], scenario: args.count > i + 2 ? args[i + 2] : "streaming")
    }
    exit(ok ? 0 : 1)
}

// Watchdog process: see Resilience. Waits for the app to exit and reopens it after a crash.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--watchdog", let pid = pid_t(CommandLine.arguments[2]) {
    Resilience.runWatchdog(appPID: pid, bundlePath: CommandLine.arguments[3])
}

// One copy at a time: a second launch asks the running one to show its window, then quits.
let me = ProcessInfo.processInfo.processIdentifier
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

Resilience.installInApp()
Resilience.runDebugTriggers()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)  // Dock icon + window; menu bar icon stays too
app.run()
