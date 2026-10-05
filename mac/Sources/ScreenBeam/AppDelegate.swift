import AppKit
import CoreGraphics
import SwiftUI

/// Main window + menu bar UI. Everything here runs on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = StreamController()
    private let usb = UsbBridge()
    private var statusItem: NSStatusItem!
    private var status: StreamStatus = .starting
    private let model = AppModel()
    private var window: NSWindow?
    private var restartWork: DispatchWorkItem?

    private var settings: StreamSettings { model.settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        Log.write("launched \(Bundle.main.bundlePath), preflight=\(CGPreflightScreenCaptureAccess())")
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        controller.onStatus = { [weak self] status in
            guard let self else { return }
            self.status = status
            self.model.status = status
            if case .waiting(let port) = status { self.usb.updatePort(port) }
            self.model.refresh()
            self.updateIcon()
        }
        model.onSettingsChange = { [weak self] in self?.controller.update($0) }
        model.onDisconnect = { [weak self] in self?.controller.disconnect() }
        model.onRequestPermission = { [weak self] in self?.openPrivacySettings() }
        model.refresh()
        showWindow()

        usb.onDevicesChanged = { [weak self] devices in self?.model.usbDevices = devices }
        usb.start(port: UInt16(StreamServer.preferredPort.rawValue))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.model.adbAvailable = self.usb.adbPath != nil
        }
        controller.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep serving the phone; reopen from the Dock or the menu bar icon
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model)))
            w.title = "ScreenBeam"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func environmentChanged() {
        // Debounce: display reconfiguration fires several notifications in a row.
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.controller.restartIfStreaming() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch status {
        case .streaming: symbol = "display.and.arrow.down"
        case .controller: symbol = "gamecontroller"
        case .sound: symbol = "speaker.wave.2"
        case .failed: symbol = "exclamationmark.triangle"
        default: symbol = "display"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenBeam")
        image?.isTemplate = true
        button.image = image
        if status.isActive {
            button.contentTintColor = .systemGreen
        } else {
            button.contentTintColor = nil
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch status {
        case .starting:
            menu.addItem(info("Starting…"))
        case .waiting(let port):
            menu.addItem(info("Waiting for your phone"))
            if port == 0 {
                menu.addItem(info("Network unavailable"))
            } else {
                let ips = NetworkInfo.localIPv4Addresses()
                if ips.isEmpty {
                    menu.addItem(info("Not connected to Wi-Fi"))
                }
                for ip in ips { menu.addItem(info("Address: \(ip):\(port)")) }
            }
        case .streaming(let device, let w, let h, let codec, let fps):
            menu.addItem(info("Streaming to \(device)"))
            menu.addItem(info("\(w)×\(h) · \(codec) · \(fps) fps · \(settings.bitrateMbps) Mbps"))
        case .controller(let device):
            menu.addItem(info("\(device) is your controller"))
        case .sound(let device):
            menu.addItem(info("Playing sound on \(device)"))
        case .failed(let message):
            menu.addItem(info("Error"))
            let item = info(message)
            item.toolTip = message
            menu.addItem(item)
        }

        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(.separator())
            menu.addItem(action("Grant Screen Recording Permission…", #selector(openPrivacySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(submenu("Mode", [
            option("Gaming · lowest latency", tag: 1, selected: settings.gamingMode, #selector(pickMode(_:))),
            option("Quality · sharpest text", tag: 0, selected: !settings.gamingMode, #selector(pickMode(_:))),
        ]))
        menu.addItem(submenu("Display", displayOptions()))
        menu.addItem(submenu("Quality", [
            ("Balanced · 20 Mbps", 20), ("High · 40 Mbps", 40),
            ("Very High · 70 Mbps", 70), ("Maximum · 100 Mbps", 100),
        ].map { option($0.0, tag: $0.1, selected: settings.bitrateMbps == $0.1, #selector(pickBitrate(_:))) }))
        menu.addItem(submenu("Frame Rate", [30, 60].map {
            option("\($0) fps", tag: $0, selected: settings.fps == $0, #selector(pickFPS(_:)))
        }))
        menu.addItem(submenu("Resolution", [("Native", 0), ("1440p", 1440), ("1080p", 1080)].map {
            option($0.0, tag: $0.1, selected: settings.maxHeight == $0.1, #selector(pickResolution(_:)))
        }))
        menu.addItem(submenu("Codec", [
            ("Automatic", StreamSettings.CodecPreference.auto),
            ("HEVC", .hevc), ("H.264", .h264),
        ].map { option($0.0, tag: $0.1.rawValue, selected: settings.codec == $0.1, #selector(pickCodec(_:))) }))

        if status.isActive {
            menu.addItem(.separator())
            menu.addItem(action("Disconnect Phone", #selector(disconnect)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Show Window", #selector(showWindow)))
        menu.addItem(withTitle: "Quit ScreenBeam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func displayOptions() -> [NSMenuItem] {
        var items = [option("Main Display", tag: 0, selected: settings.displayID == 0, #selector(pickDisplay(_:)))]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = number.uint32Value
            items.append(option(screen.localizedName, tag: Int(id), selected: settings.displayID == id,
                                #selector(pickDisplay(_:))))
        }
        return items
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func option(_ title: String, tag: Int, selected: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.tag = tag
        item.state = selected ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }

    // MARK: - Actions

    private func apply(_ change: (inout StreamSettings) -> Void) {
        model.update(change)
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) { apply { $0.displayID = UInt32(sender.tag) } }
    @objc private func pickBitrate(_ sender: NSMenuItem) { apply { $0.bitrateMbps = sender.tag } }
    @objc private func pickMode(_ sender: NSMenuItem) { apply { $0.gamingMode = sender.tag == 1 } }
    @objc private func pickFPS(_ sender: NSMenuItem) { apply { $0.fps = sender.tag } }
    @objc private func pickResolution(_ sender: NSMenuItem) { apply { $0.maxHeight = sender.tag } }
    @objc private func pickCodec(_ sender: NSMenuItem) {
        apply { $0.codec = StreamSettings.CodecPreference(rawValue: sender.tag) ?? .auto }
    }

    @objc private func disconnect() { controller.disconnect() }

    @objc func openPrivacySettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum NetworkInfo {
    /// IPv4 addresses of active Wi-Fi / Ethernet interfaces.
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ptr.pointee.ifa_name).hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
