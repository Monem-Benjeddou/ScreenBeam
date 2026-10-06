import Foundation
import Network

/// TCP server advertised over Bonjour. Serves one phone at a time; a new phone replaces the old one.
/// All state lives on `queue`; callbacks fire on `queue`.
final class StreamServer {
    static let preferredPort: NWEndpoint.Port = 7878
    static let serviceType = "_screenbeam._tcp"

    var onClientReady: ((ClientHello) -> Void)?
    var onClientGone: (() -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    /// A frame (by pts µs) reached the phone's screen.
    var onAck: ((UInt64) -> Void)?
    /// Phone's measured audio playout delay in ms (for syncing the Mac's speakers).
    var onPhoneAudioLatency: ((Int) -> Void)?
    /// Remote mouse/keyboard input from the paired phone.
    var onInput: ((MessageType, Data) -> Void)?
    /// Returns true if the phone's pairing code is correct.
    var validatePairing: ((String) -> Bool)?
    /// Listening port (0 while not listening). Fired on `queue`.
    var onListening: ((UInt16) -> Void)?

    /// Bytes allowed in flight before frames are dropped (set from the bitrate).
    var congestionLimit = 2_000_000

    let queue = DispatchQueue(label: "screenbeam.net", qos: .userInteractive)
    private var listener: NWListener?
    private var client: Client?                         // the phone currently viewing
    /// Second connection from the same phone carrying only audio, so sound never queues behind video.
    private var audioClient: Client?
    private var connections: [ObjectIdentifier: Client] = [:]  // keeps every open socket alive
    private var heartbeat: DispatchSourceTimer?

    func start() {
        queue.async {
            self.listen(on: Self.preferredPort)
        }
    }

    func disconnectClient() {
        queue.async { self.client?.close(reason: "Disconnected from the Mac.", code: .stop) }
    }

    func send(config: Data?, frame: Data, isKeyframe: Bool) {
        queue.async {
            guard let c = self.client, c.isReady else { return }

            if c.waitingForKeyframe {
                guard isKeyframe, c.inFlight < self.congestionLimit else {
                    if isKeyframe { c.keyframeRequested = false }  // dropped it; ask again once drained
                    return
                }
                c.waitingForKeyframe = false
            } else if c.inFlight > self.congestionLimit {
                // Network can't keep up: drop until we can resync on a fresh keyframe.
                c.waitingForKeyframe = true
                c.keyframeRequested = false
                return
            }

            if let config { c.send(.config, config) }
            c.send(.frame, frame)
        }
    }

    /// Audio skips the video flow control; it's small, and gaps are worse than a few ms of extra queue.
    func sendAudio(_ payload: Data, type: MessageType = .audio) {
        queue.async {
            if let a = self.audioClient, a.isReady {
                // Dedicated channel: only drop if the phone stopped reading (>200 ms queued).
                if a.inFlight < 40_000 { a.send(type, payload) }
                return
            }
            guard let c = self.client, c.isReady, c.inFlight < self.congestionLimit else { return }
            c.send(type, payload)
        }
    }

    func sendStats(latencyMs: Int, bitrateKbps: Int, fps: Int, skipped: Int) {
        var d = Data()
        d.appendBE(UInt16(clamping: latencyMs))
        d.appendBE(UInt32(clamping: bitrateKbps))
        d.appendBE(UInt16(clamping: fps))
        d.appendBE(UInt16(clamping: skipped))
        queue.async { if let c = self.client, c.isReady { c.send(.stats, d) } }
    }

    func sendError(_ message: String) {
        queue.async { self.client?.send(.error, Wire.errorPayload(message, code: .retry)) }
    }

    func sendNotice(_ message: String) {
        queue.async { self.client?.send(.notice, Data(message.utf8)) }
    }

    // MARK: - Listener

    private func listen(on port: NWEndpoint.Port) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            NSLog("ScreenBeam: cannot listen on \(port): \(error)")
            retryListen(after: port)
            return
        }
        let name = Pairing.computerName
        listener.service = NWListener.Service(name: name, type: Self.serviceType)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.onListening?(listener.port?.rawValue ?? 0)
            case .failed(let error):
                NSLog("ScreenBeam: listener failed: \(error)")
                listener.cancel()
                self.listener = nil
                self.onListening?(0)
                self.retryListen(after: port)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func retryListen(after failedPort: NWEndpoint.Port) {
        // Preferred port taken: fall back to any port (Bonjour still finds us), else retry later.
        if failedPort == Self.preferredPort {
            listen(on: .any)
        } else {
            queue.asyncAfter(deadline: .now() + 2) { self.listen(on: Self.preferredPort) }
        }
    }

    private func accept(_ conn: NWConnection) {
        let c = Client(connection: conn, queue: queue)
        c.onMessage = { [weak self, weak c] type, payload in
            guard let self, let c else { return }
            self.handle(type: type, payload: payload, from: c)
        }
        c.onDrained = { [weak self, weak c] in
            guard let self, let c, self.client === c else { return }
            if c.waitingForKeyframe, !c.keyframeRequested, c.inFlight < self.congestionLimit / 2 {
                c.keyframeRequested = true
                self.onKeyframeNeeded?()
            }
        }
        c.onClose = { [weak self, weak c] in
            guard let self, let c else { return }
            self.connections[ObjectIdentifier(c)] = nil
            if self.connections.isEmpty {
                self.heartbeat?.cancel()
                self.heartbeat = nil
            }
            if self.audioClient === c { self.audioClient = nil }
            guard self.client === c else { return }
            self.client = nil
            self.audioClient?.close(reason: nil)
            self.audioClient = nil
            self.onClientGone?()
        }
        connections[ObjectIdentifier(c)] = c
        if heartbeat == nil { startHeartbeat() }  // only while someone is connected
        c.start()
    }

    // MARK: Pairing throttle: a 6-digit code must not be guessable by trying them all.

    private var pairingFailures: [String: (count: Int, lockedUntil: Date)] = [:]

    private func pairingLocked(_ c: Client) -> Bool {
        guard let f = pairingFailures[c.peer] else { return false }
        return f.lockedUntil > Date()
    }

    private func recordPairingFailure(_ c: Client) {
        var f = pairingFailures[c.peer] ?? (0, .distantPast)
        f.count += 1
        if f.count >= 5 {
            // 1 min after 5 wrong codes, doubling for each further wrong code (max 1 h).
            let minutes = min(60.0, pow(2.0, Double(f.count - 5)))
            f.lockedUntil = Date().addingTimeInterval(minutes * 60)
            Log.write("pairing: \(f.count) wrong codes from \(c.peer); refusing it for \(Int(minutes)) min")
        }
        pairingFailures[c.peer] = f
    }

    private func handle(type: UInt8, payload: Data, from c: Client) {
        switch MessageType(rawValue: type) {
        case .hello:
            guard let hello = ClientHello(payload) else {
                c.close(reason: "Incompatible app version. Update ScreenBeam on both devices.", code: .stop)
                return
            }
            guard hello.version >= 3 else {
                c.close(reason: "Update the ScreenBeam app on your phone.", code: .stop)
                return
            }
            guard !pairingLocked(c) else {
                c.close(reason: "Too many wrong pairing codes. Wait a minute, then try again.", code: .pairing)
                return
            }
            guard validatePairing?(hello.pairingCode) ?? false else {
                recordPairingFailure(c)
                Log.write("rejected \(hello.deviceName): wrong pairing code")
                c.close(reason: hello.pairingCode.isEmpty ? "Enter the pairing code shown on your Mac."
                                                          : "Wrong pairing code. Check the code on your Mac.",
                        code: .pairing)
                return
            }
            if let old = client, old !== c {
                client = nil
                old.close(reason: "Another device started viewing this Mac.", code: .stop)
            }
            c.isReady = true
            c.send(.ready, Data())
            c.waitingForKeyframe = true
            c.keyframeRequested = true  // a fresh session always starts with a keyframe
            client = c
            onClientReady?(hello)
        case .audioLatency:
            guard audioClient === c, payload.count >= 2 else { return }
            var r = ByteReader(payload)
            if let ms = r.uint(UInt16.self) { onPhoneAudioLatency?(Int(ms)) }
        case .audioHello:
            var r = ByteReader(payload)
            guard !pairingLocked(c), r.take(4) == Array("SBA1".utf8), let len = r.u8(), let pin = r.take(Int(len)),
                  validatePairing?(String(decoding: pin, as: UTF8.self)) ?? false, client != nil
            else {
                c.close(reason: nil)
                return
            }
            audioClient?.close(reason: nil)
            c.isReady = true
            audioClient = c
            Log.write("audio channel open")
        case .keyframeRequest:
            guard client === c else { return }
            c.waitingForKeyframe = true
            c.keyframeRequested = true
            onKeyframeNeeded?()
        case .ping:
            c.send(.pong, payload)
        case .ack:
            guard client === c, payload.count == 8 else { return }
            var r = ByteReader(payload)
            if let pts = r.uint(UInt64.self) { onAck?(pts) }
        case .mouseMove, .mouseMoveAbsolute, .mouseButton, .scroll, .key, .text:
            guard client === c else { return }
            onInput?(MessageType(rawValue: type)!, payload)
        default:
            break
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for c in self.connections.values where Date().timeIntervalSince(c.lastHeard) > 8 {
                c.close(reason: "Connection timed out.", code: .retry)
            }
        }
        t.resume()
        heartbeat = t
    }
}

/// One phone connection: framed receive loop + send accounting for backpressure.
private final class Client {
    let connection: NWConnection
    let queue: DispatchQueue
    var isReady = false
    var waitingForKeyframe = true
    var keyframeRequested = false
    private(set) var inFlight = 0
    private(set) var lastHeard = Date()
    private var closed = false

    var onMessage: ((UInt8, Data) -> Void)?
    var onDrained: (() -> Void)?
    var onClose: (() -> Void)?

    /// Remote address, for the pairing throttle (USB phones all show up as 127.0.0.1).
    let peer: String

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        if case .hostPort(let host, _) = connection.endpoint {
            peer = "\(host)"
        } else {
            peer = "\(connection.endpoint)"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(reason: nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func send(_ type: MessageType, _ payload: Data) {
        guard !closed else { return }
        let size = 5 + payload.count
        inFlight += size
        connection.batch {
            connection.send(content: Wire.header(type, length: payload.count), completion: .idempotent)
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.inFlight -= size
                if error != nil {
                    self.close(reason: nil)
                } else {
                    self.onDrained?()
                }
            })
        }
    }

    func close(reason: String?, code: Wire.ErrorCode = .retry) {
        guard !closed else { return }
        // Skip silent handshake drops: the phone probes the USB link every couple of seconds.
        if isReady || reason != nil {
            Log.write("connection closed (\(isReady ? "session" : "handshake")): \(reason ?? "dropped"), \(inFlight) bytes unsent")
        }
        if let reason {
            // Best effort: tell the phone why before hanging up.
            let msg = Wire.errorPayload(reason, code: code)
            var d = Wire.header(.error, length: msg.count)
            d.append(msg)
            connection.send(content: d, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
            queue.asyncAfter(deadline: .now() + 1) { [connection] in connection.cancel() }
        } else {
            connection.cancel()
        }
        closed = true
        onClose?()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == 5 else {
                self.close(reason: nil)
                return
            }
            var r = ByteReader(data)
            let type = r.u8()!
            let length = Int(r.uint(UInt32.self)!)
            guard length <= Wire.maxIncomingPayload else {
                self.close(reason: "Protocol error.", code: .stop)
                return
            }
            self.lastHeard = Date()
            if length == 0 {
                self.onMessage?(type, Data())
                if isComplete { self.close(reason: nil) } else { self.receiveHeader() }
            } else {
                self.receiveBody(type: type, length: length)
            }
        }
    }

    private func receiveBody(type: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == length else {
                self.close(reason: nil)
                return
            }
            self.lastHeard = Date()
            self.onMessage?(type, data)
            if isComplete { self.close(reason: nil) } else { self.receiveHeader() }
        }
    }
}
