import AppKit
import CoreGraphics
import SwiftUI

/// State shown in the main window; updated by AppDelegate on the main thread.
final class AppModel: ObservableObject {
    @Published var status: StreamStatus = .starting
    @Published var settings = StreamSettings.load()
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var addresses: [String] = []
    @Published var hasAccessibility = InputInjector.isTrusted
    @Published var pairingCode = Pairing.code
    @Published var usbDevices: [String] = []
    @Published var adbAvailable = true
    @Published var pairedOnce = Pairing.pairedOnce
    @Published var qrImage: NSImage?
    private var refreshTimer: Timer?

    /// Steps the user must finish before streaming works (Accessibility is optional, for control only).
    var setupComplete: Bool { hasPermission && hasAccessibility && pairedOnce }

    init() {
        // Keep the checklist live: permissions granted in System Settings tick off without a restart.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func openAccessibilitySettings() {
        InputInjector.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording only takes effect in a fresh process; restart ourselves.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    var onSettingsChange: ((StreamSettings) -> Void)?
    var onDisconnect: (() -> Void)?
    var onRequestPermission: (() -> Void)?

    func regeneratePairingCode() {
        pairingCode = Pairing.regenerate()
        qrImage = PairingQR.image(addresses: addresses, port: port, code: pairingCode)
        onDisconnect?()  // the current phone must re-pair with the new code
    }

    func update(_ change: (inout StreamSettings) -> Void) {
        change(&settings)
        onSettingsChange?(settings)
    }

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != hasPermission { hasPermission = screen }
        let ax = InputInjector.isTrusted
        if ax != hasAccessibility { hasAccessibility = ax }
        let paired = Pairing.pairedOnce
        if paired != pairedOnce { pairedOnce = paired }
        let ips = NetworkInfo.localIPv4Addresses()
        if ips != addresses || qrImage == nil {
            addresses = ips
            qrImage = PairingQR.image(addresses: ips, port: port, code: pairingCode)
        }
    }

    var port: UInt16 {
        if case .waiting(let port) = status { return port }
        return UInt16(StreamServer.preferredPort.rawValue)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !model.setupComplete { setupCard }
            connectCard
            settingsCard
        }
        .padding(22)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isStreaming ? "display.and.arrow.down" : "display")
                .font(.system(size: 28))
                .foregroundStyle(isStreaming ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isStreaming {
                Button("Stop") { model.onDisconnect?() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    // MARK: Setup checklist

    private var setupCard: some View {
        card {
            Text("Set up ScreenBeam").font(.headline)
            Text("Three quick steps. Each one updates here as soon as it's done.")
                .font(.callout).foregroundStyle(.secondary)
            step(1, done: model.hasPermission,
                 title: "Let ScreenBeam see your screen",
                 detail: model.hasPermission
                    ? "Screen Recording is allowed."
                    : "Needed to show your screen on the phone. Turn on ScreenBeam in the list that opens, then click Relaunch.") {
                HStack {
                    Button("Open Settings") { model.onRequestPermission?() }
                    Button("Relaunch") { model.relaunch() }
                }
            }
            step(2, done: model.hasAccessibility,
                 title: "Let your phone control this Mac",
                 detail: model.hasAccessibility
                    ? "Mouse, keyboard and game controls are allowed."
                    : "Needed for the mouse, keyboard and game controls. Optional if you only want to watch or listen.") {
                Button("Open Settings") { model.openAccessibilitySettings() }
            }
            step(3, done: model.pairedOnce,
                 title: "Pair your phone",
                 detail: model.pairedOnce
                    ? "Your phone is paired."
                    : "Open ScreenBeam on your phone, tap Scan QR code, and point it at the code below.") {
                EmptyView()
            }
        }
    }

    private func step<Actions: View>(_ n: Int, done: Bool, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Step \(n), not done")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done { actions() }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Connect

    private var connectCard: some View {
        card {
            HStack(alignment: .top, spacing: 16) {
                if let qr = model.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .padding(6)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Pairing QR code")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your phone").font(.headline)
                    Text("In the ScreenBeam phone app, tap **Scan QR code** and point it here. It pairs and connects in one step.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Code").font(.caption).foregroundStyle(.secondary)
                        Text(model.pairingCode).font(.system(.body, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Button("New code") { model.regeneratePairingCode() }
                            .controlSize(.small)
                            .help("Makes a new code and disconnects the current phone")
                    }
                    if model.addresses.isEmpty {
                        Label("This Mac isn't on Wi-Fi", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
            }
            if !model.usbDevices.isEmpty {
                Label("USB cable connected: the phone will use it automatically", systemImage: "cable.connector")
                    .foregroundStyle(.green).font(.callout)
            }
            DisclosureGroup("Connect manually", isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type one of these addresses in the phone app:")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(model.addresses, id: \.self) { ip in
                        Text("\(ip):\(String(model.port))")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    if !model.adbAvailable {
                        Text("For a USB cable connection, install adb: brew install android-platform-tools")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    // MARK: Settings

    private var settingsCard: some View {
        card {
            Picker("Picture", selection: binding(\.gamingMode)) {
                Text("Smooth (games, video)").tag(true)
                Text("Sharp (reading, work)").tag(false)
            }
            Picker("Mac speakers", selection: binding(\.macSpeakers)) {
                Text("Play on both, in sync").tag(StreamSettings.MacSpeakers.synced)
                Text("Muted (phone only)").tag(StreamSettings.MacSpeakers.muted)
                Text("Normal (no sync)").tag(StreamSettings.MacSpeakers.normal)
            }
            if NSScreen.screens.count > 1 {
                Picker("Display", selection: binding(\.displayID)) {
                    Text("Main Display").tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Bitrate", selection: binding(\.bitrateMbps)) {
                        Text("20 Mbps").tag(20)
                        Text("40 Mbps").tag(40)
                        Text("70 Mbps").tag(70)
                        Text("100 Mbps").tag(100)
                    }
                    Picker("Frame rate", selection: binding(\.fps)) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("Resolution", selection: binding(\.maxHeight)) {
                        Text(model.settings.gamingMode ? "Auto (fit phone)" : "Native").tag(0)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                    }
                    Picker("Codec", selection: binding(\.codec)) {
                        Text("Automatic").tag(StreamSettings.CodecPreference.auto)
                        Text("HEVC").tag(StreamSettings.CodecPreference.hevc)
                        Text("H.264").tag(StreamSettings.CodecPreference.h264)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<StreamSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.update { $0[keyPath: keyPath] = value } })
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var isStreaming: Bool {
        switch model.status {
        case .streaming, .controller, .sound: return true
        default: return false
        }
    }

    private var title: String {
        switch model.status {
        case .starting: return "Starting…"
        case .waiting: return "Waiting for your phone"
        case .streaming(let device, _, _, _, _): return "Streaming to \(device)"
        case .controller(let device): return "\(device) is your controller"
        case .sound(let device): return "Playing sound on \(device)"
        case .failed: return "Couldn't start streaming"
        }
    }

    private var subtitle: String {
        switch model.status {
        case .starting: return ""
        case .waiting(let port): return port == 0 ? "Network unavailable" : "Ready on port \(port)"
        case .streaming(_, let w, let h, let codec, let fps): return "\(w)×\(h) · \(codec) · \(fps) fps"
        case .controller: return "Controller mode · no video sent"
        case .sound: return "Sound only · no video sent"
        case .failed(let message): return message
        }
    }
}
