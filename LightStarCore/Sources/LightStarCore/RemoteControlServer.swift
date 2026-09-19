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
    
    /// Broadcast state update to all connected clients.
    public func broadcastStateUpdate(_ state: LightStarState) {
        guard let message = try? RemoteMessage(type: .stateUpdate, content: state) else { return }
        for (_, connection) in connections {
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
        let id = UUID().uuidString
        let connection = ClientConnection(id: id, connection: nwConnection)
        let injector = pointerInjector
        connection.onPointer = { dx, dy, isScroll in
            injector?.applyPointer(deltaX: dx, deltaY: dy, isScroll: isScroll) == true
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
            if let state = getState?() {
                if let response = try? RemoteMessage(type: .stateUpdate, content: state) {
                    connection.send(response)
                }
            }
        default:
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
        
        connection.deviceName = hello.deviceName
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
    
    private func handlePair(_ message: RemoteMessage, connection: ClientConnection) {
        guard let pair = try? message.decode(PairMessage.self) else {
            let error = PairAckMessage(success: false, errorMessage: "Invalid pairing message")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
            return
        }
        
        // Simple pairing: accept any 4-digit code for now
        // In production, display code on Mac and require user to enter it on iPhone
        if pair.pairingCode.count == 4, pair.pairingCode.allSatisfy({ $0.isNumber }) {
            connection.authenticated = true
            let ack = PairAckMessage(success: true, sessionToken: UUID().uuidString)
            if let response = try? RemoteMessage(type: .pairAck, content: ack) {
                connection.send(response)
            }
            updateConnectedClientsList()
            if let state = getState?(), let stateMsg = try? RemoteMessage(type: .stateUpdate, content: state) {
                connection.send(stateMsg)
            }
        } else {
            let error = PairAckMessage(success: false, errorMessage: "Invalid pairing code")
            if let response = try? RemoteMessage(type: .pairAck, content: error) {
                connection.send(response)
            }
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
    
    private var receiveBuffer = Data()
    
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
        connection.send(content: data, completion: .idempotent)
    }
    
    func close() {
        connection.cancel()
    }
    
    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
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
