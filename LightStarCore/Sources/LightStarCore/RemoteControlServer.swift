#if os(macOS)
import Foundation
import Network

/// Remote control server that runs on macOS to accept connections from iPhone clients.
@MainActor
public final class RemoteControlServer: ObservableObject {
    
    public enum ServerState: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case error(String)
    }
    
    @Published public private(set) var state: ServerState = .stopped
    @Published public private(set) var connectedClients: [String] = []
    @Published public var requirePairing: Bool = false
    
    /// The current pairing code displayed to the user. Nil when no pairing is in progress.
    @Published public private(set) var activePairingCode: String?
    private var pairingCodeExpireTask: Task<Void, Never>?
    
    /// Called when a client sends a control command.
    public var onCommand: ((RemoteMessage, @escaping (RemoteMessage?) -> Void) -> Void)?
    /// Pointer injection off the MainActor. Set by RemoteControlCoordinator.
    public var pointerInjector: MacPointerInjector?
    
    /// Called to get current state for state sync.
    public var getState: (() -> LightStarState)?

    /// Called when the authenticated client list changes.
    public var onClientsChanged: (([String]) -> Void)?
    
    private var listener: NWListener?
    private var connections: [String: ClientConnection] = [:]
    private let queue = DispatchQueue(label: "lightstar.server", qos: .userInteractive)
    private let maxConnections = 10

    /// Global brute-force protection: counts total failed pairing attempts across all connections.
    private var globalFailedPairingAttempts = 0
    private var globalPairingLockoutUntil: Date = .distantPast

    private let macName: String
    
    public init() {
        self.macName = Host.current().localizedName ?? "Mac"
    }
    
    public func start(port: UInt16 = kLightStarDefaultPort) {
        guard case .stopped = state else { return }
        state = .starting
        
        do {
            let params = makeLightStarTCPParameters()
            
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.service = NWListener.Service(
                name: macName,
                type: kLightStarServiceType
            )
            listener?.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    self?.handleListenerStateChange(newState, port: port)
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            listener?.start(queue: queue)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        
        for (_, connection) in connections {
            connection.close()
        }
        connections.removeAll()
        connectedClients = []
        state = .stopped
    }
    
    /// Broadcast state update to all authenticated connected clients.
    public func broadcastStateUpdate(_ state: LightStarState) {
        guard let message = try? RemoteMessage(type: .stateUpdate, content: state) else { return }
        for (_, connection) in connections where connection.authenticated {
            connection.send(message)
        }
    }
    
    // MARK: - Private
    
    private func handleListenerStateChange(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            state = .running(port: port)
        case .failed(let error):
            state = .error(lightStarNetworkErrorMessage(error))
            stop()
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }
    
    private func handleNewConnection(_ nwConnection: NWConnection) {
        guard connections.count < maxConnections else {
            nwConnection.cancel()
            return
        }
        let id = UUID().uuidString
        let connection = ClientConnection(id: id, connection: nwConnection)
        let injector = pointerInjector
        connection.onPointer = { [weak connection] dx, dy, isScroll in
            guard connection?.authenticated == true else { return false }
            return injector?.applyPointer(deltaX: dx, deltaY: dy, isScroll: isScroll) == true
        }
        connection.onMessage = { [weak self] message in
            if injector?.handle(message) == true { return }
            Task { @MainActor in
                self?.handleMessage(message, from: id)
            }
        }
        connection.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.handleDisconnect(id: id)
            }
        }
        connections[id] = connection
        connection.start(queue: queue)
    }
    
    private func handleDisconnect(id: String) {
        if connections[id]?.authenticated == true {
            pointerInjector?.cleanup()
        }
        connections.removeValue(forKey: id)
        updateConnectedClientsList()
    }
    
    private func handleMessage(_ message: RemoteMessage, from clientID: String) {
        guard let connection = connections[clientID] else { return }
        
        switch message.type {
        case .hello:
            handleHello(message, connection: connection)
        case .pair:
            handlePair(message, connection: connection)
        case .ping:
            connection.send(RemoteMessage(type: .pong))
        case .disconnect:
            connection.close()
            connections.removeValue(forKey: clientID)
            updateConnectedClientsList()
        case .getState:
            guard connection.authenticated else { return }
            if let state = getState?() {
                if let response = try? RemoteMessage(type: .stateUpdate, content: state) {
                    connection.send(response)
                }
            }
        default:
            guard connection.authenticated else { return }
            onCommand?(message) { response in
                if let response = response {
                    connection.send(response)
                }
            }
        }
    }
    
    private func handleHello(_ message: RemoteMessage, connection: ClientConnection) {
        guard let hello = try? message.decode(HelloMessage.self) else {
            let error = HelloAckMessage(accepted: false, macName: macName, errorMessage: "Invalid hello message")
            if let response = try? RemoteMessage(type: .helloAck, content: error) {
                connection.send(response)
            }
            return
        }
        
        if hello.protocolVersion != kLightStarProtocolVersion {
            let error = HelloAckMessage(
                accepted: false,
                macName: macName,
                errorMessage: "Protocol version mismatch. Please update your app."
            )
            if let response = try? RemoteMessage(type: .helloAck, content: error) {
                connection.send(response)
            }
            return
        }
        
        connection.deviceName = String(hello.deviceName.prefix(64))
        connection.authenticated = !requirePairing
        
        let ack = HelloAckMessage(
            accepted: true,
            macName: macName,
            requiresPairing: requirePairing && !connection.authenticated
        )
        if let response = try? RemoteMessage(type: .helloAck, content: ack) {
            connection.send(response)
        }
        
        if connection.authenticated {
            updateConnectedClientsList()
            if let state = getState?(), let stateMsg = try? RemoteMessage(type: .stateUpdate, content: state) {
                connection.send(stateMsg)
            }
        }
    }
    
    /// Generate a new pairing code that expires after 60 seconds.
    public func generatePairingCode() -> String {
        pairingCodeExpireTask?.cancel()
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let code = String((0..<6).map { _ in chars.randomElement(using: &rng)! })
        activePairingCode = code
        pairingCodeExpireTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, self.activePairingCode == code else { return }
            self.activePairingCode = nil
        }
        return code
    }
    
    private func handlePair(_ message: RemoteMessage, connection: ClientConnection) {
        // Check server-level global lockout first (prevents parallel connection brute force).
        if Date() < globalPairingLockoutUntil {
            let error = PairAckMessage(success: false, errorMessage: "Too many failed attempts")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
            connection.close()
            return
        }
        guard !connection.pairingLockedOut else {
            let error = PairAckMessage(success: false, errorMessage: "Too many failed attempts")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
            return
        }

        guard let pair = try? message.decode(PairMessage.self) else {
            let error = PairAckMessage(success: false, errorMessage: "Invalid pairing message")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
            return
        }

        guard let expectedCode = activePairingCode,
              pair.pairingCode == expectedCode else {
            connection.failedPairingAttempts += 1
            globalFailedPairingAttempts += 1
            // Per-connection lockout after 3 attempts; global lockout with exponential backoff.
            if connection.failedPairingAttempts >= 3 {
                connection.pairingLockedOut = true
            }
            if globalFailedPairingAttempts >= 5 {
                let backoff = min(300.0, pow(2.0, Double(globalFailedPairingAttempts - 5)))
                globalPairingLockoutUntil = Date().addingTimeInterval(backoff)
            }
            let error = PairAckMessage(success: false, errorMessage: "Invalid pairing code")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
            connection.close()
            return
        }
        
        activePairingCode = nil
        pairingCodeExpireTask?.cancel()
        globalFailedPairingAttempts = 0
        globalPairingLockoutUntil = .distantPast
        connection.authenticated = true
        let ack = PairAckMessage(success: true, sessionToken: UUID().uuidString)
        if let response = try? RemoteMessage(type: .pairAck, content: ack) {
            connection.send(response)
        }
        updateConnectedClientsList()
        if let state = getState?(), let stateMsg = try? RemoteMessage(type: .stateUpdate, content: state) {
            connection.send(stateMsg)
        }
    }
    
    private func updateConnectedClientsList() {
        connectedClients = connections.values
            .filter { $0.authenticated }
            .compactMap { $0.deviceName }
        onClientsChanged?(connectedClients)
    }
}

// MARK: - Client Connection

// @unchecked Sendable because NWConnection callbacks require Sendable
// and we manage thread safety through the serial dispatch queue
private final class ClientConnection: @unchecked Sendable {
    let id: String
    let connection: NWConnection
    var deviceName: String?
    var authenticated = false
    
    var onMessage: ((RemoteMessage) -> Void)?
    var onPointer: ((Double, Double, Bool) -> Bool)?
    var onDisconnect: (() -> Void)?

    var failedPairingAttempts = 0
    var pairingLockedOut = false
    
    private var receiveBuffer = Data()
    private let maxReceiveBufferSize = 2 * 1024 * 1024 // 2MB
    
    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }
    
    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.startReceiving()
            case .failed, .cancelled:
                self?.onDisconnect?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    func send(_ message: RemoteMessage) {
        guard let data = try? encodeMessage(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    
    func close() {
        connection.cancel()
    }
    
    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                guard self.receiveBuffer.count + data.count <= self.maxReceiveBufferSize else {
                    self.receiveBuffer.removeAll()
                    self.onDisconnect?()
                    return
                }
                self.receiveBuffer.append(data)
                self.processBuffer()
            }
            
            if isComplete || error != nil {
                self.onDisconnect?()
            } else {
                self.startReceiving()
            }
        }
    }
    
    private func processBuffer() {
        while receiveBuffer.count >= 4 {
            do {
                if let pointer = try decodePointerFrame(from: receiveBuffer) {
                    receiveBuffer.removeFirst(pointer.consumed)
                    compactBufferIfNeeded()
                    if onPointer?(pointer.deltaX, pointer.deltaY, pointer.isScroll) == true {
                        continue
                    }
                    let type: RemoteMessageType = pointer.isScroll ? .scroll : .mouseMove
                    if let message = try? RemoteMessage(
                        type: type,
                        content: MouseMoveMessage(deltaX: pointer.deltaX, deltaY: pointer.deltaY)
                    ) {
                        onMessage?(message)
                    }
                    continue
                }
                let (message, consumed) = try decodeMessage(from: receiveBuffer)
                receiveBuffer.removeFirst(consumed)
                compactBufferIfNeeded()
                onMessage?(message)
            } catch RemoteProtocolError.insufficientData, RemoteProtocolError.incompleteMessage {
                break
            } catch {
                receiveBuffer.removeAll()
                onDisconnect?()
                return
            }
        }
    }

    private func compactBufferIfNeeded() {
        if receiveBuffer.startIndex != 0 {
            receiveBuffer = Data(receiveBuffer)
        }
    }
}

#endif
