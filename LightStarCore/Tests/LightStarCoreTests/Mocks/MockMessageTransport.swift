import Foundation
@testable import LightStarCore

/// Mock message transport for testing protocol handling.
/// Allows queuing messages and simulating network behavior.
public final class MockMessageTransport: MessageTransport, @unchecked Sendable {

    // MARK: - State

    public private(set) var connected = true
    public private(set) var sentMessages: [RemoteMessage] = []
    private var receiveQueue: [RemoteMessage] = []
    private var receiveError: Error?
    private var receiveContinuation: CheckedContinuation<RemoteMessage, Error>?
    private let lock = NSLock()

    // MARK: - Configuration

    /// Simulated latency in seconds.
    public var latency: TimeInterval = 0

    /// Whether to automatically respond to certain messages.
    public var autoRespond: Bool = false

    public init() {}

    // MARK: - MessageTransport

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    public func send(_ message: RemoteMessage) async throws {
        lock.lock()
        let isConnectedNow = connected
        let delay = latency
        let shouldAutoRespond = autoRespond
        lock.unlock()

        guard isConnectedNow else {
            throw TransportError.disconnected
        }

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        lock.lock()
        sentMessages.append(message)
        lock.unlock()

        if shouldAutoRespond, let response = autoResponse(for: message) {
            enqueueForReceive(response)
        }
    }

    public func receive() async throws -> RemoteMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            guard connected else {
                continuation.resume(throwing: TransportError.disconnected)
                return
            }
            if let error = receiveError {
                continuation.resume(throwing: error)
                return
            }
            if !receiveQueue.isEmpty {
                continuation.resume(returning: receiveQueue.removeFirst())
                return
            }
            self.receiveContinuation = continuation
        }
    }

    public func close() {
        lock.lock()
        connected = false
        let pending = receiveContinuation
        receiveContinuation = nil
        lock.unlock()
        pending?.resume(throwing: TransportError.disconnected)
    }

    // MARK: - Test Control

    /// Queue a message to be received.
    public func enqueueForReceive(_ message: RemoteMessage) {
        lock.lock()
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            lock.unlock()
            continuation.resume(returning: message)
        } else {
            receiveQueue.append(message)
            lock.unlock()
        }
    }

    /// Set an error to be thrown on next receive.
    public func setReceiveError(_ error: Error?) {
        lock.lock()
        receiveError = error
        let pending = receiveContinuation
        if error != nil {
            receiveContinuation = nil
        }
        lock.unlock()
        if let error, let pending {
            pending.resume(throwing: error)
        }
    }

    /// Simulate disconnection.
    public func simulateDisconnect() {
        close()
    }

    /// Reconnect.
    public func reconnect() {
        lock.lock()
        connected = true
        receiveError = nil
        lock.unlock()
    }

    /// Reset all state.
    public func reset() {
        lock.lock()
        connected = true
        sentMessages.removeAll()
        receiveQueue.removeAll()
        receiveError = nil
        receiveContinuation = nil
        lock.unlock()
    }

    /// Get sent messages of a specific type.
    public func sentMessages(ofType type: RemoteMessageType) -> [RemoteMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages.filter { $0.type == type }
    }

    /// Get last sent message.
    public var lastSentMessage: RemoteMessage? {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages.last
    }

    // MARK: - Auto Response

    private func autoResponse(for message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .ping:
            return try? RemoteMessage(type: .pong, content: EmptyMessage())
        case .hello:
            return try? RemoteMessage(type: .helloAck, content: HelloAckMessage(accepted: true, macName: "MockServer", requiresPairing: true))
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
