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
    
    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var discoveredServers: [DiscoveredServer] = []
    @Published public private(set) var currentState: LightStarState?
    @Published public private(set) var requiresPairing = false
    
    public struct DiscoveredServer: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let host: String
        public let port: UInt16
        
        public init(id: String, name: String, host: String, port: UInt16) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
        }
    }
    
    /// Called when the connection state changes.
    public var onStateChange: ((LightStarState) -> Void)?
    
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "lightstar.client", qos: .userInteractive)
    
    private let deviceName: String
    private var connectedServerName: String?
    private var pingTask: Task<Void, Never>?
    
    public init() {
        #if os(iOS)
        self.deviceName = UIDevice.current.name
        #else
        self.deviceName = Host.current().localizedName ?? "Mac"
        #endif
    }
    
    // MARK: - Discovery
    
    public func startDiscovery() {
        stopDiscovery()
        state = .discovering
        discoveredServers = []
        
        let params = NWParameters()
        params.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: kLightStarServiceType, domain: "local."), using: params)
        browser?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                switch newState {
                case .failed(let error):
                    self?.state = .error("Discovery failed: \(error.localizedDescription)")
                case .cancelled:
                    if case .discovering = self?.state {
                        self?.state = .disconnected
                    }
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
        browser?.cancel()
        browser = nil
        if case .discovering = state {
            state = .disconnected
        }
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var servers: [DiscoveredServer] = []
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                let id = "\(name).\(type).\(domain)"
                servers.append(DiscoveredServer(
                    id: id,
                    name: name,
                    host: "", // Will be resolved on connect
                    port: kLightStarDefaultPort
                ))
            }
        }
        discoveredServers = servers
    }
    
    // MARK: - Connection
    
    public func connect(to server: DiscoveredServer) {
        disconnect()
        state = .connecting(server.name)
        connectedServerName = server.name
        
        let endpoint: NWEndpoint
        if server.host.isEmpty {
            endpoint = .service(name: server.name, type: kLightStarServiceType, domain: "local.", interface: nil)
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(server.host), port: NWEndpoint.Port(rawValue: server.port)!)
        }
        
        let params = NWParameters.tcp
        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.handleConnectionStateChange(newState)
            }
        }
        connection?.start(queue: queue)
    }
    
    public func connect(host: String, port: UInt16) {
        let server = DiscoveredServer(id: "\(host):\(port)", name: host, host: host, port: port)
        connect(to: server)
    }
    
    public func disconnect() {
        pingTask?.cancel()
        pingTask = nil
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
            startReceiving()
            sendHello()
        case .failed(let error):
            state = .error(error.localizedDescription)
            disconnect()
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
        guard let data = try? encodeMessage(message) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
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
                handleMessage(message)
            } catch {
                break
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
                state = .error(error.message)
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
        if let msg = try? RemoteMessage(type: .mouseMove, content: MouseMoveMessage(deltaX: deltaX, deltaY: deltaY)) {
            send(msg)
        }
    }
    
    public func sendMouseDown(button: Int = 0) {
        if let msg = try? RemoteMessage(type: .mouseDown, content: MouseButtonMessage(button: button)) {
            send(msg)
        }
    }
    
    public func sendMouseUp(button: Int = 0) {
        if let msg = try? RemoteMessage(type: .mouseUp, content: MouseButtonMessage(button: button)) {
            send(msg)
        }
    }
    
    public func sendRightClick() {
        send(RemoteMessage(type: .rightClick))
    }
    
    public func sendScroll(deltaX: Double, deltaY: Double) {
        if let msg = try? RemoteMessage(type: .scroll, content: ScrollMessage(deltaX: deltaX, deltaY: deltaY)) {
            send(msg)
        }
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
}

#if os(iOS)
import UIKit
#endif
