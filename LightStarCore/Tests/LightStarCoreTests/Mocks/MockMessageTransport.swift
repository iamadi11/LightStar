import Foundation
@testable import LightStarCore

/// Mock message transport for testing protocol handling.
/// Single-threaded test helper; `@unchecked Sendable` matches other mocks.
public final class MockMessageTransport: MessageTransport, @unchecked Sendable {

    public private(set) var connected = true
    public private(set) var sentMessages: [RemoteMessage] = []
    private var receiveQueue: [RemoteMessage] = []
    private var receiveError: Error?
    private var receiveContinuation: CheckedContinuation<RemoteMessage, Error>?

    public var latency: TimeInterval = 0
    public var autoRespond: Bool = false

    public init() {}

    public var isConnected: Bool { connected }

    public func send(_ message: RemoteMessage) async throws {
        guard connected else { throw TransportError.disconnected }
        if latency > 0 {
            try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }
        sentMessages.append(message)
        if autoRespond, let response = autoResponse(for: message) {
            enqueueForReceive(response)
        }
    }

    public func receive() async throws -> RemoteMessage {
        try await withCheckedThrowingContinuation { continuation in
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
            receiveContinuation = continuation
        }
    }

    public func close() {
        connected = false
        let pending = receiveContinuation
        receiveContinuation = nil
        pending?.resume(throwing: TransportError.disconnected)
    }

    public func enqueueForReceive(_ message: RemoteMessage) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: message)
        } else {
            receiveQueue.append(message)
        }
    }

    public func setReceiveError(_ error: Error?) {
        receiveError = error
        if let error, let pending = receiveContinuation {
            receiveContinuation = nil
            pending.resume(throwing: error)
        }
    }

    public func simulateDisconnect() { close() }

    public func reconnect() {
        connected = true
        receiveError = nil
    }

    public func reset() {
        connected = true
        sentMessages.removeAll()
        receiveQueue.removeAll()
        receiveError = nil
        receiveContinuation = nil
    }

    public func sentMessages(ofType type: RemoteMessageType) -> [RemoteMessage] {
        sentMessages.filter { $0.type == type }
    }

    public var lastSentMessage: RemoteMessage? { sentMessages.last }

    private func autoResponse(for message: RemoteMessage) -> RemoteMessage? {
        switch message.type {
        case .ping:
            return try? RemoteMessage(type: .pong, content: EmptyMessage())
        case .hello:
            return try? RemoteMessage(
                type: .helloAck,
                content: HelloAckMessage(accepted: true, macName: "MockServer", requiresPairing: true)
            )
        default:
            return nil
        }
    }
}

public enum TransportError: Error, Equatable {
    case disconnected
    case timeout
    case invalidMessage
    case connectionRefused
}

public struct EmptyMessage: Codable, Sendable {}
