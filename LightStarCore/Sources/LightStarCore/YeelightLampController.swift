#if os(macOS)
import Foundation
import Network
import Darwin

public enum YeelightLampState: Equatable, Sendable {
    case stopped
    case searching
    case connecting(String)
    case following(String)
    case notFound
    case failed(String)
}

/// Follows the strip over the Yeelight LAN protocol. Network work stays off the
/// Bluetooth write path; a full send queue cannot stall the bar.
@MainActor
@Observable
public final class YeelightLampController {
    public static let enabledDefaultsKey = "yeelightMirrorEnabled"

    public private(set) var state: YeelightLampState = .stopped
    /// Fired once the lamp can take colour. The app pushes the current strip state.
    public var onFollowing: (() -> Void)?

    private let engine = YeelightEngine()
    private var started = false

    public init() {
        engine.setHandler { [weak self] event in
            Task { @MainActor in
                guard let self, self.started else { return }
                switch event {
                case .searching:
                    self.state = .searching
                case .connecting(let name):
                    self.state = .connecting(name)
                case .following(let name):
                    let first = self.state != .following(name)
                    self.state = .following(name)
                    if first { self.onFollowing?() }
                case .notFound:
                    self.state = .notFound
                case .failed(let message):
                    self.state = .failed(message)
                }
            }
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        state = .searching
        engine.start()
    }

    public func stop() {
        guard started else { return }
        started = false
        state = .stopped
        engine.stop()
    }

    public func submit(_ update: YeelightMirrorUpdate) {
        engine.submit(update)
    }
}

private enum YeelightEngineEvent: Sendable {
    case searching
    case connecting(String)
    case following(String)
    case notFound
    case failed(String)
}

private final class YeelightEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lightstar.yeelight", qos: .userInitiated)
    private var handler: (@Sendable (YeelightEngineEvent) -> Void)?
    private var running = false
    private var generation = 0
    private var found: [String: YeelightAdvertisement] = [:]
    private var device: YeelightAdvertisement?
    private var desired = YeelightMirrorState()
    private var sent = YeelightMirrorState()
    private var control: NWConnection?
    private var musicListener: NWListener?
    private var music: NWConnection?
    private var musicReady = false
    private var supportsHSV = true
    private var lastSend = Date.distantPast
    private var commandID = 1
    private var flushScheduled = false
    private var browser = YeelightBrowser()

    func setHandler(_ handler: @escaping @Sendable (YeelightEngineEvent) -> Void) {
        queue.async { self.handler = handler }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.emit(.searching)
            self.search()
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.running = false
            self.flushScheduled = false
            let control = self.control
            self.send(commands: [.musicOff], forceControl: true)
            self.browser.stop()
            self.music?.cancel()
            self.music = nil
            self.musicListener?.cancel()
            self.musicListener = nil
            self.musicReady = false
            self.control = nil
            self.device = nil
            self.queue.asyncAfter(deadline: .now() + 0.2) {
                control?.cancel()
            }
        }
    }

    func submit(_ update: YeelightMirrorUpdate) {
        queue.async {
            guard self.running else { return }
            self.desired.apply(update)
            self.flush()
            self.scheduleFlush()
        }
    }

    private func search() {
        guard running else { return }
        let session = generation
        found.removeAll()
        browser.start(queue: queue) { [weak self] advertisement in
            self?.found[advertisement.id] = advertisement
        }
        browser.probe()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.generation == session else { return }
            self.browser.stop()
            self.finishSearch()
        }
    }

    private func finishSearch() {
        guard control == nil else { return }
        let saved = UserDefaults.standard.string(forKey: "yeelightLampId")
        guard let choice = YeelightDiscovery.choose(Array(found.values), savedID: saved) else {
            emit(.notFound)
            let session = generation
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.running, self.generation == session, self.control == nil else { return }
                self.search()
            }
            return
        }
        UserDefaults.standard.set(choice.id, forKey: "yeelightLampId")
        openControl(choice)
    }

    private func openControl(_ device: YeelightAdvertisement) {
        teardownConnections()
        self.device = device
        supportsHSV = device.supportsHSV
        sent = YeelightMirrorState()
        emit(.connecting(device.displayName))
        guard let port = NWEndpoint.Port(rawValue: device.port) else {
            emit(.failed("Lamp port is invalid"))
            return
        }
        let session = generation
        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port, using: .tcp)
        control = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.controlUpdated(state, session: session, device: device)
            }
        }
        connection.start(queue: queue)
    }

    private func controlUpdated(_ state: NWConnection.State, session: Int, device: YeelightAdvertisement) {
        guard running, generation == session else { return }
        switch state {
        case .ready:
            receive(control)
            if device.supportsMusic, let host = YeelightLocalAddress.ipv4(toward: device.host) {
                startMusicListener(host: host, session: session, name: device.displayName)
            } else {
                musicReady = false
                emit(.following(device.displayName))
                flush()
            }
        case .failed:
            let current = generation
            generation += 1
            musicReady = false
            teardownConnections()
            emit(.searching)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.running, self.generation == current + 1 else { return }
                self.search()
            }
        default:
            break
        }
    }

    private func startMusicListener(host: String, session: Int, name: String) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            musicListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    guard let self, self.running, self.generation == session, self.music == nil else {
                        connection.cancel()
                        return
                    }
                    self.music = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        self?.queue.async {
                            guard let self, self.generation == session else { return }
                            if case .ready = state {
                                self.musicReady = true
                                self.receive(connection)
                                self.emit(.following(name))
                                self.flush()
                            } else if case .failed = state {
                                self.musicReady = false
                                self.music?.cancel()
                                self.music = nil
                            }
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    guard let self, self.running, self.generation == session else { return }
                    if case .ready = state, let port = listener.port?.rawValue {
                        self.send(commands: [.musicOn(host: host, port: port)], forceControl: true)
                        self.queue.asyncAfter(deadline: .now() + 1.5) {
                            guard self.running, self.generation == session, !self.musicReady else { return }
                            self.emit(.following(name))
                            self.flush()
                        }
                    } else if case .failed = state {
                        self.musicReady = false
                        self.emit(.following(name))
                        self.flush()
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            musicReady = false
            emit(.following(name))
            flush()
        }
    }

    private func flush() {
        guard running, control != nil else { return }
        let interval: TimeInterval = musicReady ? 0.15 : 1.0
        guard Date().timeIntervalSince(lastSend) >= interval else { return }
        let batch = YeelightFlush.commands(
            desired: desired,
            sent: sent,
            supportsHSV: supportsHSV,
            musicMode: musicReady
        )
        guard !batch.isEmpty else { return }
        send(commands: batch, forceControl: false)
        lastSend = Date()
        if !musicReady { scheduleFlush() }
    }

    private func scheduleFlush() {
        guard running, !flushScheduled else { return }
        flushScheduled = true
        let session = generation
        queue.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.running, self.generation == session else { return }
            self.flush()
        }
    }

    private func send(commands: [YeelightWireCommand], forceControl: Bool) {
        let socket = (!forceControl && musicReady) ? music : control
        guard let socket else { return }
        var payload = Data()
        for command in commands {
            guard let line = YeelightCommand.encode(id: commandID, command) else { continue }
            commandID += 1
            payload.append(Data(line.utf8))
            switch command {
            case .power(let on):
                sent.power = on
            case .hsv(let hue, let saturation):
                sent.hue = Double(hue) / 360
                sent.saturation = Double(saturation) / 100
            case .rgb:
                sent.hue = desired.hue
                sent.saturation = desired.saturation
            case .brightness(let value):
                sent.brightness = Double(value) / 100
            case .musicOn, .musicOff:
                break
            }
        }
        guard !payload.isEmpty else { return }
        socket.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func receive(_ connection: NWConnection?) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, self.running else { return }
                if let data, let text = String(data: data, encoding: .utf8), text.contains("quota exceeded") {
                    self.musicReady = false
                }
                if error == nil, !isComplete {
                    self.receive(connection)
                }
            }
        }
    }

    private func teardown() {
        browser.stop()
        teardownConnections()
        device = nil
        musicReady = false
    }

    private func teardownConnections() {
        music?.cancel()
        music = nil
        musicListener?.cancel()
        musicListener = nil
        control?.cancel()
        control = nil
        musicReady = false
    }

    private func emit(_ event: YeelightEngineEvent) {
        handler?(event)
    }
}

private final class YeelightBrowser: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var onAdvertisement: ((YeelightAdvertisement) -> Void)?

    func start(queue: DispatchQueue, onAdvertisement: @escaping (YeelightAdvertisement) -> Void) {
        stop()
        self.onAdvertisement = onAdvertisement
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(socketFD)
            return
        }
        fd = socketFD
        let src = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        src.setEventHandler { [weak self] in self?.read() }
        src.setCancelHandler { close(socketFD) }
        source = src
        src.resume()
    }

    func probe() {
        guard fd >= 0 else { return }
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n"
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1982).bigEndian
        _ = inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
        _ = message.withCString { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, strlen(bytes), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
        onAdvertisement = nil
    }

    private func read() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8),
              let advertisement = YeelightDiscovery.parse(text) else { return }
        onAdvertisement?(advertisement)
    }
}

enum YeelightLocalAddress {
    static func ipv4(toward host: String) -> String? {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}
#endif
