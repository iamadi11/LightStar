import Foundation
@testable import LightStarCore

/// Mock message transport for testing protocol handling.
/// Allows queuing messages and simulating network behavior.
public actor MockMessageTransport: MessageTransport {
    
    // MARK: - State
    
    public private(set) var connected = true
    public private(set) var sentMessages: [RemoteMessage] = []
    private var receiveQueue: [RemoteMessage] = []
    private var receiveError: Error?
    private var receiveContinuation: CheckedContinuation<RemoteMessage, Error>?
    
    // MARK: - Configuration
    
    /// Simulated latency in seconds.
    public var latency: TimeInterval = 0
    
    /// Whether to automatically respond to certain messages.
    public var autoRespond: Bool = false
    
    public init() {}
    
    // MARK: - MessageTransport
    
    public var isConnected: Bool {
        connected
    }
    
    public func send(_ message: RemoteMessage) async throws {
        guard connected else {
            throw TransportError.disconnected
        }
        
        if latency > 0 {
            try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }
        
        sentMessages.append(message)
        
        // Auto-respond to certain messages for convenience
        if autoRespond {
            if let response = autoResponse(for: message) {
                enqueueForReceive(response)
            }
        }
    }
    
    public func receive() async throws -> RemoteMessage {
        guard connected else {
            throw TransportError.disconnected
        }
        
        if let error = receiveError {
            throw error
        }
        
        if !receiveQueue.isEmpty {
            return receiveQueue.removeFirst()
        }
        
        // Wait for a message
        return try await withCheckedThrowingContinuation { continuation in
            self.receiveContinuation = continuation
        }
    }
    
    public func close() {
        connected = false
        receiveContinuation?.resume(throwing: TransportError.disconnected)
        receiveContinuation = nil
    }
    
    // MARK: - Test Control
    
    /// Queue a message to be received.
    public func enqueueForReceive(_ message: RemoteMessage) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: message)
        } else {
            receiveQueue.append(message)
        }
    }
    
    /// Set an error to be thrown on next receive.
    public func setReceiveError(_ error: Error?) {
        receiveError = error
        if let error = error, let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(throwing: error)
        }
    }
    
    /// Simulate disconnection.
    public func simulateDisconnect() {
        close()
    }
    
    /// Reconnect.
    public func reconnect() {
        connected = true
        receiveError = nil
    }
    
    /// Reset all state.
    public func reset() {
        connected = true
        sentMessages.removeAll()
        receiveQueue.removeAll()
        receiveError = nil
        receiveContinuation = nil
    }
    
    /// Get sent messages of a specific type.
    public func sentMessages(ofType type: RemoteMessageType) -> [RemoteMessage] {
        sentMessages.filter { $0.type == type }
    }
    
    /// Get last sent message.
    public var lastSentMessage: RemoteMessage? {
        sentMessages.last
    }
    
    // MARK: - Auto Response
    
    private func autoResponse(for message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .ping:
            return try? RemoteMessage(type: .pong, content: EmptyMessage())
        case .hello:
            return try? RemoteMessage(type: .helloAck, content: HelloAckMessage(serverName: "MockServer", serverVersion: "1.0", requiresPairing: true))
        default:
            return nil
        }
    }
}

// MARK: - Transport Errors

public enum TransportError: Error, Equatable {
    case disconnected
    case timeout
    case invalidMessage
    case connectionRefused
}

// MARK: - Helper Messages

public struct EmptyMessage: Codable, Sendable {}
