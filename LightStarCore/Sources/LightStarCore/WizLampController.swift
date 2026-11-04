#if os(macOS)
import Foundation
import Darwin

public enum WizLampState: Equatable, Sendable {
    case stopped
    case searching
    case following(String)
    case notFound
    /// Every probe was refused by macOS: Local Network access is off for LightStar.
    case blocked
}

/// WiZ lamp on the LAN (Philips Gradient Floor Lamp). Follows the strip like the
/// Mi lamp, and also takes WiZ scenes and per-segment colour. UDP only, no
/// pairing; local control must be allowed in the WiZ app.
@MainActor
@Observable
public final class WizLampController {
    nonisolated public static let macDefaultsKey = "wizLampMAC"
    nonisolated public static let hostDefaultsKey = "wizLampHost"

    public private(set) var state: WizLampState = .stopped
    /// Last segment colours sent from LightStar. Firmware cannot report them.
    public private(set) var segments: [WizRGB] = Array(repeating: .off, count: 7)
    public var onFollowing: (() -> Void)?
    public var onStateChange: (() -> Void)?

    private let engine = WizEngine()
    private var started = false

    public init() {
        engine.setHandler { [weak self] event in
            Task { @MainActor in
                guard let self, self.started else { return }
                let changed = event != self.state
                self.state = event
                guard changed else { return }
                self.onStateChange?()
                if case .following = event { self.onFollowing?() }
            }
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        state = .searching
        engine.start()
    }

    /// Look for the lightbar again, e.g. after it was unplugged or changed IP.
    public func searchAgain() {
        stop()
        start()
    }

    public func stop() {
        guard started else { return }
        started = false
        state = .stopped
        engine.stop()
    }

    public func submit(_ update: YeelightMirrorUpdate) {
        engine.mirror(update)
    }

    public func setScene(_ id: Int) {
        engine.choose(.scene(id))
    }

    /// One colour per segment; `.off` turns that segment dark.
    public func setSegments(_ colors: [WizRGB]) {
        segments = colors
        engine.choose(.segments(colors))
    }

    /// Sync frames (screen gradient or VU meter). While they flow the bar's
    /// single colour and brightness are held back; nil hands the lamp back.
    public func stream(_ zones: [WizRGB]?) {
        engine.stream(zones)
    }

    /// Re-send after the widths or slot change, since the lamp holds no layout.
    public func setLayout(_ layout: WizSegmentLayout) {
        layout.save()
        engine.relayout(layout)
    }

    /// Drop saved widths and go back to the count the lamp reports.
    public func resetLayout() {
        UserDefaults.standard.removeObject(forKey: WizSegmentLayout.defaultsKey)
        engine.relayout(.stored)
    }
}

private final class WizEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lightstar.wiz", qos: .userInitiated)
    private var handler: (@Sendable (WizLampState) -> Void)?
    private var running = false
    private var generation = 0
    private var socket = WizSocket()
    private var found: [WizDevice] = []
    private var device: WizDevice?
    private var desired = WizPilot()
    /// What the lamp shows when sync is not streaming to it.
    private var resting = WizPilot()
    private var streaming = false
    private var sent = WizPilot()
    private var layout = WizSegmentLayout.stored
    private var lastSend = Date.distantPast
    /// Link health: last setPilot sent, last datagram back, last getPilot ping.
    private var lastCommand = Date.distantPast
    private var lastReply = Date.distantPast
    private var lastPing = Date.distantPast
    /// Probes macOS let out during the current search.
    private var probesSent = 0
    private var flushScheduled = false
    /// ~30 fps; the firmware takes more but screen sync does not need it.
    private let interval: TimeInterval = 1.0 / 30

    func setHandler(_ handler: @escaping @Sendable (WizLampState) -> Void) {
        queue.async { self.handler = handler }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.socket.open(queue: self.queue) { [weak self] data, host in
                self?.received(data, from: host)
            }
            self.search()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.generation += 1
            self.flushScheduled = false
            self.socket.close()
            self.device = nil
            self.sent = WizPilot()
            self.streaming = false
            self.desired = self.resting
        }
    }

    func mirror(_ update: YeelightMirrorUpdate) {
        queue.async {
            self.resting.apply(update)
            if self.streaming {
                // Power still follows the bar; colour belongs to the stream.
                if case .power(let on) = update { self.desired.power = on }
            } else {
                self.desired = self.resting
            }
            self.flush()
        }
    }

    func choose(_ mode: WizMode) {
        queue.async {
            self.resting.power = true
            self.resting.mode = mode
            if !self.streaming { self.desired = self.resting }
            self.flush()
        }
    }

    func stream(_ zones: [WizRGB]?) {
        queue.async {
            if let zones {
                self.streaming = true
                self.desired.mode = .segments(zones)
                self.desired.dimming = 100
            } else {
                guard self.streaming else { return }
                self.streaming = false
                self.desired = self.resting
            }
            self.flush()
        }
    }

    func relayout(_ layout: WizSegmentLayout) {
        queue.async {
            self.layout = layout
            self.sent.mode = nil
            self.flush()
        }
    }

    /// Asks the last known address directly (instant when nothing changed) and
    /// broadcasts for a lightbar that moved, several times: right after launch
    /// macOS refuses the first packets ("No route to host") while its Local
    /// Network check settles, so one probe is not enough. The saved lightbar is
    /// taken the moment it answers; anything else at the end of the window.
    private func search() {
        guard running else { return }
        handler?(.searching)
        found.removeAll()
        probesSent = 0
        let session = generation
        for delay in [0, 0.3, 0.6, 1.0, 1.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.running, self.generation == session, self.device == nil else { return }
                if let host = UserDefaults.standard.string(forKey: WizLampController.hostDefaultsKey),
                   self.socket.send(WizCommand.systemConfig, to: host) {
                    self.probesSent += 1
                }
                if self.socket.send(WizCommand.systemConfig, to: "255.255.255.255") {
                    self.probesSent += 1
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finishSearch(session)
        }
    }

    private func finishSearch(_ session: Int) {
        guard running, generation == session, device == nil else { return }
        let saved = UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey)
        guard let choice = WizDiscovery.choose(found, savedMAC: saved) else {
            handler?(probesSent == 0 ? .blocked : .notFound)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.running, self.generation == session, self.device == nil else { return }
                self.search()
            }
            return
        }
        connect(choice)
    }

    private func connect(_ choice: WizDevice) {
        UserDefaults.standard.set(choice.mac, forKey: WizLampController.macDefaultsKey)
        UserDefaults.standard.set(choice.host, forKey: WizLampController.hostDefaultsKey)
        device = choice
        sent = WizPilot()
        lastReply = Date()
        handler?(.following(choice.displayName))
        socket.send(WizCommand.modelConfig, to: choice.host)
        flush()
        heartbeat(generation)
    }

    private func heartbeat(_ session: Int) {
        guard running, generation == session, let device else { return }
        let now = Date()
        switch WizLink.action(now: now, lastCommand: lastCommand, lastReply: lastReply, lastPing: lastPing) {
        case .none:
            break
        case .resend:
            sent = WizPilot()
            flush()
        case .ping:
            lastPing = now
            socket.send(WizCommand.pilot, to: device.host)
        case .lost:
            // Keep `desired`; it is sent again once the lightbar is back.
            self.device = nil
            sent = WizPilot()
            search()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.heartbeat(session)
        }
    }

    private func received(_ data: Data, from host: String) {
        guard running else { return }
        if let device, host == device.host {
            lastReply = Date()
            guard let count = WizDiscovery.segmentCount(data),
                  count != UserDefaults.standard.integer(forKey: WizSegmentLayout.countDefaultsKey) else { return }
            UserDefaults.standard.set(count, forKey: WizSegmentLayout.countDefaultsKey)
            layout = WizSegmentLayout.stored
            sent.mode = nil
            flush()
            return
        }
        guard device == nil, let lamp = WizDiscovery.parse(data, host: host),
              !found.contains(where: { $0.mac == lamp.mac }) else { return }
        found.append(lamp)
        if lamp.mac == UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey) {
            finishSearch(generation)
        }
    }

    private func flush() {
        guard running, let device else { return }
        guard Date().timeIntervalSince(lastSend) >= interval else {
            scheduleFlush()
            return
        }
        let messages = WizFlush.messages(desired: desired, sent: sent, layout: layout, mac: device.mac)
        guard !messages.isEmpty else { return }
        for (data, next) in messages {
            socket.send(data, to: device.host)
            sent = next
        }
        lastSend = Date()
        lastCommand = lastSend
    }

    private func scheduleFlush() {
        guard running, !flushScheduled else { return }
        flushScheduled = true
        let session = generation
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.running, self.generation == session else { return }
            self.flush()
        }
    }
}

/// One broadcast-capable UDP socket for discovery and control. Replies come back
/// from the lamp's port 38899 to whatever port we sent from.
private final class WizSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var onData: ((Data, String) -> Void)?

    func open(queue: DispatchQueue, onData: @escaping (Data, String) -> Void) {
        close()
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        self.onData = onData
        fd = socketFD
        let src = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        src.setEventHandler { [weak self] in self?.read() }
        src.setCancelHandler { Darwin.close(socketFD) }
        source = src
        src.resume()
    }

    func close() {
        source?.cancel()
        source = nil
        fd = -1
        onData = nil
    }

    /// False when macOS refused the packet (e.g. Local Network access off).
    @discardableResult
    func send(_ data: Data, to host: String) -> Bool {
        guard fd >= 0, !data.isEmpty else { return false }
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = WizCommand.port.bigEndian
        guard inet_pton(AF_INET, host, &dest.sin_addr) == 1 else { return false }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent >= 0
    }

    private func read() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            }
        }
        guard count > 0 else { return }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = from.sin_addr
        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return }
        onData?(Data(buffer[0..<count]), String(cString: text))
    }
}
#endif
