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

/// A WiZ light seen on the network.
public struct WizLight: Equatable, Sendable, Identifiable {
    public var mac: String
    public var host: String
    /// Nil until the light reports its model.
    public var gradient: Bool?
    public var enabled: Bool
    public var connected: Bool
    /// Where a plain bulb stands around the screen for screen sync.
    public var side: LampGradient.Side = .whole
    public var id: String { mac }
    public var name: String {
        let kind = gradient == false ? "WiZ light" : "Lightbar"
        return "\(kind) · \(mac.suffix(4).uppercased())"
    }
}

/// WiZ lights on the LAN (the Philips Gradient Floor Lamp and any other WiZ
/// light the user switches on). They follow the strip, and take WiZ scenes,
/// per-segment colour, sync and effects. UDP only, no pairing; local control
/// must be allowed in the WiZ app.
@MainActor
@Observable
public final class WizLampController {
    nonisolated public static let macDefaultsKey = "wizLampMAC"
    nonisolated public static let hostDefaultsKey = "wizLampHost"
    /// MACs of the lights to drive; absent until the user picks.
    nonisolated public static let enabledDefaultsKey = "wizEnabledLights"
    /// Last address of each light, for an instant reconnect.
    nonisolated public static let hostsDefaultsKey = "wizLightHosts"
    /// White part of colours: 0 warm-white LEDs … 1 cool-white LEDs.
    nonisolated public static let whiteToneDefaultsKey = "lightbarWhiteTone"

    public private(set) var state: WizLampState = .stopped
    /// Every WiZ light found, with whether LightStar drives it.
    public private(set) var lights: [WizLight] = []
    /// Last segment colours sent from LightStar. Firmware cannot report them.
    public private(set) var segments: [WizRGB] = Array(repeating: .off, count: 7)
    /// The scene or segment colours chosen for the lightbar, until a plain
    /// colour replaces them. Saved into presets.
    public private(set) var look: LightbarLook?
    public var onFollowing: (() -> Void)?
    public var onStateChange: (() -> Void)?

    private let engine = WizEngine()
    private var started = false

    public init() {
        engine.setHandler { [weak self] event in
            Task { @MainActor in
                guard let self, self.started else { return }
                switch event {
                case .lights(let lights):
                    self.lights = lights
                case .state(let state):
                    let changed = state != self.state
                    self.state = state
                    guard changed else { return }
                    self.onStateChange?()
                    if case .following = state { self.onFollowing?() }
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

    /// Look for the lights again, e.g. after one was unplugged or changed IP.
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

    /// Drive this light or leave it alone.
    public func setLight(_ mac: String, enabled: Bool) {
        engine.setLight(mac, enabled: enabled)
    }

    public func setWhiteTone(_ tone: Double) {
        UserDefaults.standard.set(tone, forKey: Self.whiteToneDefaultsKey)
        engine.setWhiteTone(tone)
    }

    public func setSide(_ side: LampGradient.Side, for mac: String) {
        engine.setSide(side, for: mac)
    }

    /// Mac asleep, locked, or on the screensaver: every WiZ light off until it's back.
    public func setAway(_ away: Bool) {
        engine.setAway(away)
    }

    /// Edge colours for plain bulbs while screen sync runs; nil when it stops.
    public func streamSides(_ sides: [LampGradient.Side: WizRGB]?) {
        engine.streamSides(sides)
    }

    public func submit(_ update: YeelightMirrorUpdate) {
        if case .color = update { look = nil }
        engine.mirror(update)
    }

    public func setScene(_ id: Int) {
        look = LightbarLook(scene: id)
        engine.choose(.scene(id))
    }

    /// One colour per segment; `.off` turns that segment dark.
    public func setSegments(_ colors: [WizRGB]) {
        segments = colors
        look = LightbarLook(segments: colors.map { [$0.r, $0.g, $0.b] })
        engine.choose(.segments(colors))
    }

    /// Sync frames (screen gradient or VU meter). While they flow the bar's
    /// single colour and brightness are held back; nil hands the lamp back.
    /// With a placement the zones fill only that stretch of the bar.
    public func stream(_ zones: [WizRGB]?, placement: LampGradient.Placement? = nil) {
        engine.stream(zones, placement: placement)
    }

    /// Re-send after the widths or slot change, since the lamp holds no layout.
    public func setLayout(_ layout: WizSegmentLayout) {
        layout.save()
        engine.relayout()
    }

    /// Drop saved widths and go back to the count each light reports.
    public func resetLayout() {
        UserDefaults.standard.removeObject(forKey: WizSegmentLayout.defaultsKey)
        engine.relayout()
    }
}

private enum WizEvent: Sendable {
    case state(WizLampState)
    case lights([WizLight])
}

/// One connected light: what it was last sent, its shape, and link health.
private struct WizLinkState {
    var device: WizDevice
    var sent = WizPilot()
    var gradient: Bool?
    var segments: Int?
    var lastCommand = Date.distantPast
    var lastReply = Date()
    var lastPing = Date.distantPast
}

private final class WizEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lightstar.wiz", qos: .userInitiated)
    private var handler: (@Sendable (WizEvent) -> Void)?
    private var running = false
    private var generation = 0
    private var socket = WizSocket()
    /// Every light that has answered, by MAC.
    private var discovered: [String: WizDevice] = [:]
    private var links: [String: WizLinkState] = [:]
    private var desired = WizPilot()
    /// What the lights show when sync is not streaming to them.
    private var resting = WizPilot()
    private var streaming = false
    private var sides: [LampGradient.Side: WizRGB]?
    private var away = false
    private var whiteTone = UserDefaults.standard.object(forKey: WizLampController.whiteToneDefaultsKey) as? Double ?? 1
    private var lastSend = Date.distantPast
    /// Probes macOS let out during the current search.
    private var probesSent = 0
    private var searching = false
    private var flushScheduled = false
    /// ~30 fps; the firmware takes more but screen sync does not need it.
    private let interval: TimeInterval = 1.0 / 30

    func setHandler(_ handler: @escaping @Sendable (WizEvent) -> Void) {
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
            self.heartbeat(self.generation)
            self.rediscover(self.generation)
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.generation += 1
            self.flushScheduled = false
            self.searching = false
            self.socket.close()
            self.links.removeAll()
            self.streaming = false
            self.sides = nil
            self.desired = self.resting
            self.publishLights()
        }
    }

    func setLight(_ mac: String, enabled on: Bool) {
        queue.async {
            var set = self.enabled
            if on { set.insert(mac) } else { set.remove(mac) }
            UserDefaults.standard.set(Array(set).sorted(), forKey: WizLampController.enabledDefaultsKey)
            if on, let device = self.discovered[mac], self.links[mac] == nil {
                self.connect(device)
            } else if !on {
                self.links[mac] = nil
                self.publishState()
            }
            self.publishLights()
        }
    }

    func setWhiteTone(_ tone: Double) {
        queue.async {
            self.whiteTone = tone
            self.resendAll()
        }
    }

    func setSide(_ side: LampGradient.Side, for mac: String) {
        queue.async {
            LampGradient.setSide(side, for: mac)
            self.publishLights()
            self.resendAll()
        }
    }

    func setAway(_ on: Bool) {
        queue.async {
            guard self.away != on else { return }
            self.away = on
            // Back from away: send power and colour again, whatever was sent before.
            if !on { for mac in self.links.keys { self.links[mac]?.sent = WizPilot() } }
            self.flush()
        }
    }

    func streamSides(_ sides: [LampGradient.Side: WizRGB]?) {
        queue.async {
            self.sides = sides
            if self.streaming { self.flush() }
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

    func stream(_ zones: [WizRGB]?, placement: LampGradient.Placement?) {
        queue.async {
            if let zones {
                self.streaming = true
                if let placement {
                    self.desired.mode = .gradient(zones, placement: placement)
                } else {
                    self.desired.mode = .segments(zones)
                }
                self.desired.dimming = 100
            } else {
                guard self.streaming else { return }
                self.streaming = false
                self.desired = self.resting
            }
            self.flush()
        }
    }

    func relayout() {
        queue.async { self.resendAll() }
    }

    // MARK: Discovery

    /// Lights to drive: the user's choice, else the lightbar used before.
    private var enabled: Set<String> {
        WizDiscovery.enabledLights(
            found: Array(discovered.keys),
            stored: UserDefaults.standard.array(forKey: WizLampController.enabledDefaultsKey) as? [String],
            saved: UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey)
        )
    }

    private var savedHosts: [String: String] {
        var hosts = UserDefaults.standard.dictionary(forKey: WizLampController.hostsDefaultsKey) as? [String: String] ?? [:]
        if hosts.isEmpty, let mac = UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey),
           let host = UserDefaults.standard.string(forKey: WizLampController.hostDefaultsKey) {
            hosts[mac] = host
        }
        return hosts
    }

    /// Asks each known address directly (instant when nothing changed) and
    /// broadcasts for lights that moved, several times: right after launch
    /// macOS refuses the first packets ("No route to host") while its Local
    /// Network check settles, so one probe is not enough. An enabled light is
    /// taken the moment it answers; the window's end decides the rest.
    private func search() {
        guard running, !searching else { return }
        searching = true
        if links.isEmpty { handler?(.state(.searching)) }
        probesSent = 0
        let session = generation
        for delay in [0, 0.3, 0.6, 1.0, 1.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.running, self.generation == session, self.searching else { return }
                self.probe()
            }
        }
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finishSearch(session)
        }
    }

    private func probe() {
        for host in savedHosts.values where socket.send(WizCommand.systemConfig, to: host) { probesSent += 1 }
        if socket.send(WizCommand.systemConfig, to: "255.255.255.255") { probesSent += 1 }
    }

    private func finishSearch(_ session: Int) {
        guard running, generation == session, searching else { return }
        searching = false
        // First run: nothing chosen yet, so take the first light that answered.
        for mac in enabled where links[mac] == nil {
            if let device = discovered[mac] { connect(device) }
        }
        guard links.isEmpty else { return }
        handler?(.state(probesSent == 0 ? .blocked : .notFound))
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running, self.generation == session, self.links.isEmpty else { return }
            self.search()
        }
    }

    /// Every 30 s: a broadcast picks up lights switched on later, back after
    /// a power cut, or moved to a new address.
    private func rediscover(_ session: Int) {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.running, self.generation == session else { return }
            if !self.searching { self.probe() }
            self.rediscover(session)
        }
    }

    private func connect(_ device: WizDevice) {
        var hosts = savedHosts
        hosts[device.mac] = device.host
        UserDefaults.standard.set(hosts, forKey: WizLampController.hostsDefaultsKey)
        if links.isEmpty || UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey) == nil {
            UserDefaults.standard.set(device.mac, forKey: WizLampController.macDefaultsKey)
            UserDefaults.standard.set(device.host, forKey: WizLampController.hostDefaultsKey)
        }
        links[device.mac] = WizLinkState(device: device)
        socket.send(WizCommand.modelConfig, to: device.host)
        publishState()
        publishLights()
        flush()
    }

    private func publishState() {
        guard running else { return }
        if links.isEmpty {
            handler?(.state(.searching))
            if !searching { search() }
            return
        }
        let name: String
        if links.count == 1, let link = links.values.first {
            name = link.gradient == false ? "WiZ light" : "Lightbar"
        } else {
            name = "\(links.count) WiZ lights"
        }
        handler?(.state(.following(name)))
    }

    private func publishLights() {
        let on = enabled
        let lights = discovered.values.map { device in
            WizLight(mac: device.mac, host: device.host, gradient: links[device.mac]?.gradient,
                     enabled: on.contains(device.mac), connected: links[device.mac] != nil,
                     side: LampGradient.side(for: device.mac))
        }.sorted { $0.mac < $1.mac }
        handler?(.lights(lights))
    }

    // MARK: Link health

    private func heartbeat(_ session: Int) {
        guard running, generation == session else { return }
        let now = Date()
        var lost: [String] = []
        for (mac, link) in links {
            switch WizLink.action(now: now, lastCommand: link.lastCommand, lastReply: link.lastReply, lastPing: link.lastPing) {
            case .none:
                break
            case .resend:
                links[mac]?.sent = WizPilot()
            case .ping:
                links[mac]?.lastPing = now
                socket.send(WizCommand.pilot, to: link.device.host)
            case .lost:
                lost.append(mac)
            }
        }
        // A lost light is dropped and found again by the next search or sweep;
        // `desired` stays, so it gets the current state when it is back.
        for mac in lost { links[mac] = nil }
        if !lost.isEmpty { publishState(); publishLights() }
        flush()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.heartbeat(session)
        }
    }

    private func received(_ data: Data, from host: String) {
        guard running else { return }
        if let mac = links.first(where: { $0.value.device.host == host })?.key {
            links[mac]?.lastReply = Date()
            guard let model = WizDiscovery.modelConfig(data) else { return }
            links[mac]?.gradient = model.gradient
            links[mac]?.segments = model.segments
            // The first lightbar's count sets how many colours sync makes.
            if let count = model.segments, mac == UserDefaults.standard.string(forKey: WizLampController.macDefaultsKey),
               count != UserDefaults.standard.integer(forKey: WizSegmentLayout.countDefaultsKey) {
                UserDefaults.standard.set(count, forKey: WizSegmentLayout.countDefaultsKey)
            }
            links[mac]?.sent.mode = nil
            publishState()
            publishLights()
            flush()
            return
        }
        guard let device = WizDiscovery.parse(data, host: host) else { return }
        let known = discovered[device.mac]
        discovered[device.mac] = device
        if links[device.mac] != nil {
            links[device.mac]?.device = device     // moved to a new address
            links[device.mac]?.lastReply = Date()
            return
        }
        if known == nil { publishLights() }
        if enabled.contains(device.mac) { connect(device) }
    }

    // MARK: Sending

    /// Saved widths apply to every gradient light; otherwise each light gets
    /// even widths for the segment count it reports.
    private func layout(for link: WizLinkState) -> WizSegmentLayout {
        let stored = WizSegmentLayout.stored
        guard UserDefaults.standard.array(forKey: WizSegmentLayout.defaultsKey) == nil, let count = link.segments else {
            return stored
        }
        return WizSegmentLayout(widths: WizSegmentLayout.even(segments: count, steps: WizSegmentLayout.zones), slot: stored.slot)
    }

    private func resendAll() {
        for mac in links.keys { links[mac]?.sent.mode = nil }
        flush()
    }

    private func flush() {
        guard running, !links.isEmpty else { return }
        guard Date().timeIntervalSince(lastSend) >= interval else {
            scheduleFlush()
            return
        }
        var sentAny = false
        for (mac, link) in links {
            var want = desired
            if away {
                want.power = false
            } else if streaming, link.gradient == false, let colour = sides?[LampGradient.side(for: mac)] {
                want.mode = .color(colour)
            }
            let messages = WizFlush.messages(desired: want, sent: link.sent, layout: layout(for: link),
                                             mac: mac, gradientCapable: link.gradient ?? true, whiteTone: whiteTone)
            guard !messages.isEmpty else { continue }
            for (data, next) in messages {
                socket.send(data, to: link.device.host)
                links[mac]?.sent = next
            }
            links[mac]?.lastCommand = Date()
            sentAny = true
        }
        if sentAny { lastSend = Date() }
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
