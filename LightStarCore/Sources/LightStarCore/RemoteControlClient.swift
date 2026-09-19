import Foundation
import Network

/// Remote control client that runs on iOS to connect to Mac servers.
@MainActor
public final class RemoteControlClient: ObservableObject {
    
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case discovering
        case connecting(String)
        case authenticating
        case connected(String)
        case error(String)
    }
    
    @Published public private(set) var state: ConnectionState = .disconnected {
        didSet { onClientStateChange?(state) }
    }
    @Published public private(set) var discoveredServers: [DiscoveredServer] = []
    @Published public private(set) var currentState: LightStarState?
    @Published public private(set) var requiresPairing = false
    @Published public var notice: String?
    
    public struct DiscoveredServer: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        
        public init(id: String, name: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
        }
    }
    
    /// Called when the Mac pushes a light-state snapshot.
    public var onStateChange: ((LightStarState) -> Void)?
    /// Called when Bonjour discovery results change.
    public var onServersChanged: (([DiscoveredServer]) -> Void)?
    /// Called whenever the client connection state changes.
    public var onClientStateChange: ((ConnectionState) -> Void)?
    
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "lightstar.client", qos: .userInteractive)
    nonisolated(unsafe) private let pointerChannel: PointerChannel
    
    private let deviceName: String
    private var connectedServerName: String?
    private var pingTask: Task<Void, Never>?
    
    public init() {
        #if os(iOS)
        self.deviceName = UIDevice.current.name
        #else
        self.deviceName = Host.current().localizedName ?? "Mac"
        #endif
        self.pointerChannel = PointerChannel(queue: queue)
    }
    
    // MARK: - Discovery
    
    public func startDiscovery() {
        if case .discovering = state, browser != nil { return }
        stopBrowser()
        state = .discovering
        discoveredServers = []
        
        let params = makeLightStarBrowseParameters()
        browser = NWBrowser(for: .bonjour(type: kLightStarServiceType, domain: nil), using: params)
        browser?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                switch newState {
                case .failed(let error):
                    self?.state = .error("Discovery failed: \(lightStarNetworkErrorMessage(error))")
                default:
                    break
                }
            }
        }
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }
        browser?.start(queue: queue)
    }
    
    public func stopDiscovery() {
        let wasDiscovering = { if case .discovering = self.state { return true }; return false }()
        stopBrowser()
        if wasDiscovering {
            state = .disconnected
        }
    }

    private func stopBrowser() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var servers: [DiscoveredServer] = []
        for result in results {
            let name: String
            switch result.endpoint {
            case .service(let serviceName, _, _, _):
                name = serviceName
            case .hostPort(let host, let port):
                name = "\(host):\(port)"
            default:
                continue
            }
            servers.append(DiscoveredServer(id: name, name: name, endpoint: result.endpoint))
        }
        discoveredServers = servers
        onServersChanged?(servers)
        if case .discovering = state, let first = servers.first {
            connect(to: first)
        }
    }
    
    public func connect(to server: DiscoveredServer) {
        pingTask?.cancel()
        pingTask = nil
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        currentState = nil
        requiresPairing = false
        state = .connecting(server.name)
        connectedServerName = server.name
        
        let params = makeLightStarTCPParameters()
        connection = NWConnection(to: server.endpoint, using: params)
        pointerChannel.attach(connection)
        connection?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.handleConnectionStateChange(newState)
            }
        }
        connection?.start(queue: queue)
    }
    
    public func connect(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        connect(to: DiscoveredServer(id: "\(host):\(port)", name: host, endpoint: endpoint))
    }
    
    public func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        pointerChannel.reset()
        stopBrowser()
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        state = .disconnected
        currentState = nil
        requiresPairing = false
        connectedServerName = nil
    }
    
    private func handleConnectionStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            stopBrowser()
            startReceiving()
            sendHello()
        case .failed(let error):
            pingTask?.cancel()
            pingTask = nil
            connection?.cancel()
            connection = nil
            pointerChannel.reset()
            receiveBuffer = Data()
            requiresPairing = false
            connectedServerName = nil
            currentState = nil
            state = .error(lightStarNetworkErrorMessage(error))
        case .cancelled:
            if case .connected = state {
                state = .disconnected
            }
        default:
            break
        }
    }
    
    // MARK: - Messaging
    
    private func sendHello() {
        state = .authenticating
        let hello = HelloMessage(deviceName: deviceName, deviceType: "iOS")
        if let message = try? RemoteMessage(type: .hello, content: hello) {
            send(message)
        }
    }
    
    public func sendPairingCode(_ code: String) {
        let pair = PairMessage(pairingCode: code)
        if let message = try? RemoteMessage(type: .pair, content: pair) {
            send(message)
        }
    }
    
    public func send(_ message: RemoteMessage) {
        pointerChannel.send(message)
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let data = data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
                
                if isComplete || error != nil {
                    self.disconnect()
                } else {
                    self.startReceiving()
                }
            }
        }
    }
    
    private func processBuffer() {
        while receiveBuffer.count >= 4 {
            do {
                let (message, consumed) = try decodeMessage(from: receiveBuffer)
                receiveBuffer.removeFirst(consumed)
                if receiveBuffer.startIndex != 0 {
                    receiveBuffer = Data(receiveBuffer)
                }
                handleMessage(message)
            } catch RemoteProtocolError.insufficientData, RemoteProtocolError.incompleteMessage {
                break
            } catch {
                receiveBuffer.removeAll()
                disconnect()
                return
            }
        }
    }
    
    private func handleMessage(_ message: RemoteMessage) {
        switch message.type {
        case .helloAck:
            handleHelloAck(message)
        case .pairAck:
            handlePairAck(message)
        case .pong:
            break
        case .stateUpdate:
            handleStateUpdate(message)
        case .error:
            if let error = try? message.decode(ErrorMessage.self) {
                if case .connected = state {
                    notice = error.message
                } else {
                    state = .error(error.message)
                }
            }
        default:
            break
        }
    }
    
    private func handleHelloAck(_ message: RemoteMessage) {
        guard let ack = try? message.decode(HelloAckMessage.self) else { return }
        
        if !ack.accepted {
            state = .error(ack.errorMessage ?? "Connection rejected")
            disconnect()
            return
        }
        
        if ack.requiresPairing {
            requiresPairing = true
            state = .authenticating
        } else {
            requiresPairing = false
            state = .connected(ack.macName)
            startPingTimer()
            requestState()
        }
    }
    
    private func handlePairAck(_ message: RemoteMessage) {
        guard let ack = try? message.decode(PairAckMessage.self) else { return }
        
        if ack.success {
            requiresPairing = false
            state = .connected(connectedServerName ?? "Mac")
            startPingTimer()
            requestState()
        } else {
            state = .error(ack.errorMessage ?? "Pairing failed")
        }
    }
    
    private func handleStateUpdate(_ message: RemoteMessage) {
        guard let newState = try? message.decode(LightStarState.self) else { return }
        currentState = newState
        onStateChange?(newState)
    }
    
    private func startPingTimer() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, case .connected = self.state else { break }
                self.send(RemoteMessage(type: .ping))
            }
        }
    }
    
    // MARK: - Control Commands
    
    public func requestState() {
        send(RemoteMessage(type: .getState))
    }
    
    public func setPower(_ on: Bool) {
        if let msg = try? RemoteMessage(type: .setPower, content: SetPowerMessage(on: on)) {
            send(msg)
        }
    }
    
    public func setBrightness(_ brightness: Double) {
        if let msg = try? RemoteMessage(type: .setBrightness, content: SetBrightnessMessage(brightness: brightness)) {
            send(msg)
        }
    }
    
    public func setColor(hue: Double, saturation: Double) {
        if let msg = try? RemoteMessage(type: .setColor, content: SetColorMessage(hue: hue, saturation: saturation)) {
            send(msg)
        }
    }
    
    public func setColorTemperature(_ temperature: Double) {
        if let msg = try? RemoteMessage(type: .setColorTemperature, content: SetColorTemperatureMessage(temperature: temperature)) {
            send(msg)
        }
    }
    
    public func setEffect(id: UInt8) {
        if let msg = try? RemoteMessage(type: .setEffect, content: SetEffectMessage(effectID: id)) {
            send(msg)
        }
    }
    
    public func setEffectSpeed(_ speed: Double) {
        if let msg = try? RemoteMessage(type: .setEffectSpeed, content: SetEffectSpeedMessage(speed: speed)) {
            send(msg)
        }
    }
    
    public func setEffectDirection(forward: Bool) {
        if let msg = try? RemoteMessage(type: .setEffectDirection, content: SetEffectDirectionMessage(forward: forward)) {
            send(msg)
        }
    }
    
    public func setSyncMode(_ mode: String) {
        if let msg = try? RemoteMessage(type: .setSyncMode, content: SetSyncModeMessage(mode: mode)) {
            send(msg)
        }
    }
    
    public func selectDisplay(_ displayID: UInt32?) {
        if let msg = try? RemoteMessage(type: .selectDisplay, content: SelectDisplayMessage(displayID: displayID)) {
            send(msg)
        }
    }
    
    // MARK: - Mac Input Control
    
    public func sendMouseMove(deltaX: Double, deltaY: Double) {
        pointerChannel.addMove(deltaX: deltaX, deltaY: deltaY)
    }

    /// Gyro / background samples: accumulate on the network queue, no MainActor hop.
    nonisolated public func addMouseDelta(deltaX: Double, deltaY: Double) {
        pointerChannel.addMove(deltaX: deltaX, deltaY: deltaY)
    }
    
    public func sendMouseDown(button: Int = 0, clickCount: Int = 1) {
        if let msg = try? RemoteMessage(type: .mouseDown, content: MouseButtonMessage(button: button, clickCount: clickCount)) {
            send(msg)
        }
    }
    
    public func sendMouseUp(button: Int = 0, clickCount: Int = 1) {
        if let msg = try? RemoteMessage(type: .mouseUp, content: MouseButtonMessage(button: button, clickCount: clickCount)) {
            send(msg)
        }
    }
    
    public func sendRightClick() {
        send(RemoteMessage(type: .rightClick))
    }
    
    public func sendScroll(deltaX: Double, deltaY: Double) {
        pointerChannel.addScroll(deltaX: deltaX, deltaY: deltaY)
    }
    
    public func sendHotkey(keyCode: UInt16, modifiers: UInt32 = 0) {
        sendMacChord(keyCode: keyCode, modifiers: modifiers)
    }

    public func sendMacAction(_ action: MacSystemAction) {
        if let msg = try? RemoteMessage(type: .macAction, content: MacActionMessage(action: action)) {
            send(msg)
        }
    }

    private func sendMacChord(keyCode: UInt16, modifiers: UInt32) {
        if modifiers & RemoteModifier.command != 0 { sendKeyDown(keyCode: 0x37) }
        if modifiers & RemoteModifier.shift != 0 { sendKeyDown(keyCode: 0x38) }
        if modifiers & RemoteModifier.option != 0 { sendKeyDown(keyCode: 0x3A) }
        if modifiers & RemoteModifier.control != 0 { sendKeyDown(keyCode: 0x3B) }
        sendKeyDown(keyCode: keyCode, modifiers: modifiers)
        sendKeyUp(keyCode: keyCode, modifiers: modifiers)
        if modifiers & RemoteModifier.control != 0 { sendKeyUp(keyCode: 0x3B) }
        if modifiers & RemoteModifier.option != 0 { sendKeyUp(keyCode: 0x3A) }
        if modifiers & RemoteModifier.shift != 0 { sendKeyUp(keyCode: 0x38) }
        if modifiers & RemoteModifier.command != 0 { sendKeyUp(keyCode: 0x37) }
    }
    
    public func sendKeyDown(keyCode: UInt16, modifiers: UInt32 = 0) {
        if let msg = try? RemoteMessage(type: .keyDown, content: KeyMessage(keyCode: keyCode, modifiers: modifiers)) {
            send(msg)
        }
    }
    
    public func sendKeyUp(keyCode: UInt16, modifiers: UInt32 = 0) {
        if let msg = try? RemoteMessage(type: .keyUp, content: KeyMessage(keyCode: keyCode, modifiers: modifiers)) {
            send(msg)
        }
    }
    
    public func sendTextInput(_ text: String) {
        if let msg = try? RemoteMessage(type: .textInput, content: TextInputMessage(text: text)) {
            send(msg)
        }
    }
    
    public func sendMediaKey(_ key: MediaKeyMessage.MediaKey) {
        if let msg = try? RemoteMessage(type: .mediaKey, content: MediaKeyMessage(key: key)) {
            send(msg)
        }
    }

    public func connectStrip() {
        send(RemoteMessage(type: .connectStrip))
    }

    public func disconnectStrip() {
        send(RemoteMessage(type: .disconnectStrip))
    }

    public func sendWriteFrame(_ bytes: [UInt8]) {
        if let msg = try? RemoteMessage(type: .writeFrame, content: WriteFrameMessage(bytes: bytes)) {
            send(msg)
        }
    }
}

/// Sends pointer frames on the Network queue so gyro samples never wait for SwiftUI.
private final class PointerChannel: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NWConnection?
    private var moveX = 0.0
    private var moveY = 0.0
    private var scrollX = 0.0
    private var scrollY = 0.0
    private var flushQueued = false

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func attach(_ connection: NWConnection?) {
        lock.lock()
        self.connection = connection
        if connection == nil {
            moveX = 0
            moveY = 0
            scrollX = 0
            scrollY = 0
            flushQueued = false
        }
        lock.unlock()
    }

    func reset() {
        attach(nil)
    }

    func addMove(deltaX: Double, deltaY: Double) {
        lock.lock()
        moveX += deltaX
        moveY += deltaY
        let shouldFlush = !flushQueued
        if shouldFlush { flushQueued = true }
        lock.unlock()
        if shouldFlush { scheduleFlush() }
    }

    func addScroll(deltaX: Double, deltaY: Double) {
        lock.lock()
        scrollX += deltaX
        scrollY += deltaY
        let shouldFlush = !flushQueued
        if shouldFlush { flushQueued = true }
        lock.unlock()
        if shouldFlush { scheduleFlush() }
    }

    func send(_ message: RemoteMessage) {
        let work = { [weak self] in
            self?.flushAccumulators()
            self?.writeJSON(message)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    private func scheduleFlush() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            flushAccumulators()
        } else {
            queue.async { [weak self] in self?.flushAccumulators() }
        }
    }

    private func flushAccumulators() {
        lock.lock()
        let mx = moveX
        let my = moveY
        let sx = scrollX
        let sy = scrollY
        moveX = 0
        moveY = 0
        scrollX = 0
        scrollY = 0
        flushQueued = false
        let connection = self.connection
        lock.unlock()

        if mx != 0 || my != 0 {
            writePointer(connection, deltaX: mx, deltaY: my, isScroll: false)
        }
        if sx != 0 || sy != 0 {
            writePointer(connection, deltaX: sx, deltaY: sy, isScroll: true)
        }

        lock.lock()
        let more = moveX != 0 || moveY != 0 || scrollX != 0 || scrollY != 0
        if more { flushQueued = true }
        lock.unlock()
        if more {
            queue.async { [weak self] in self?.flushAccumulators() }
        }
    }

    private func writePointer(_ connection: NWConnection?, deltaX: Double, deltaY: Double, isScroll: Bool) {
        guard let connection else { return }
        connection.send(content: encodePointerFrame(deltaX: deltaX, deltaY: deltaY, isScroll: isScroll), completion: .idempotent)
    }

    private func writeJSON(_ message: RemoteMessage) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection, let data = try? encodeMessage(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

#if os(iOS)
import UIKit
#endif
