import Foundation

// MARK: - Testable Protocol Abstractions

/// Protocol for lighting control operations.
/// Allows mocking BLE communication in tests.
public protocol LightingController: AnyObject, Sendable {
    func setPower(on: Bool)
    func setBrightness(_ value: Double)
    func setColor(hue: Double, saturation: Double)
    func setColorTemperature(_ value: Double)
    func setEffect(id: UInt8)
    func setEffectSpeed(_ value: Double)
    func setEffectDirection(forward: Bool)
}

/// Protocol for session authentication.
/// Allows testing authentication logic independently.
public protocol SessionAuthenticator: Sendable {
    /// Generate a new pairing code for display.
    func generatePairingCode() -> String
    
    /// Validate a pairing code attempt.
    /// - Parameters:
    ///   - code: The code provided by the client
    ///   - clientID: Identifier for rate limiting
    /// - Returns: Session token if valid, nil if invalid
    func validatePairingCode(_ code: String, clientID: String) -> String?
    
    /// Validate an existing session token.
    func validateSessionToken(_ token: String) -> Bool
    
    /// Invalidate a session.
    func invalidateSession(_ token: String)
    
    /// Check if a client is rate-limited.
    func isRateLimited(clientID: String) -> Bool
}

/// Protocol for remote input control.
/// Allows mocking input injection in tests.
#if os(macOS)
import CoreGraphics

public protocol RemoteInputController: Sendable {
    func moveMouse(deltaX: Double, deltaY: Double)
    func mouseDown(button: Int)
    func mouseUp(button: Int)
    func rightClick()
    func scroll(deltaX: Double, deltaY: Double)
    func keyDown(keyCode: UInt16, modifiers: CGEventFlags)
    func keyUp(keyCode: UInt16, modifiers: CGEventFlags)
    func typeText(_ text: String)
}
#endif

/// Protocol for network message transport.
/// Allows testing protocol handling without real network.
public protocol MessageTransport: Sendable {
    func send(_ message: RemoteMessage) async throws
    func receive() async throws -> RemoteMessage
    func close()
    var isConnected: Bool { get }
}

/// Protocol for service discovery.
/// Allows mocking Bonjour discovery in tests.
public protocol ServiceDiscovery: Sendable {
    func startDiscovery()
    func stopDiscovery()
    var discoveredServices: [DiscoveredService] { get }
    var onServiceFound: ((DiscoveredService) -> Void)? { get set }
    var onServiceLost: ((String) -> Void)? { get set }
}

/// Discovered service information.
public struct DiscoveredService: Sendable, Equatable, Identifiable {
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

// MARK: - Test Result Types

/// Result of a command execution for testing.
public struct CommandExecutionResult: Sendable, Equatable {
    public let commandType: RemoteMessageType
    public let timestamp: Date
    public let success: Bool
    public let errorMessage: String?
    
    public init(commandType: RemoteMessageType, timestamp: Date = Date(), success: Bool = true, errorMessage: String? = nil) {
        self.commandType = commandType
        self.timestamp = timestamp
        self.success = success
        self.errorMessage = errorMessage
    }
}

/// Recorded lighting command for test verification.
public struct RecordedLightingCommand: Sendable, Equatable {
    public enum CommandType: String, Sendable {
        case power, brightness, color, colorTemperature, effect, effectSpeed, effectDirection
    }
    
    public let type: CommandType
    public let timestamp: Date
    public let parameters: [String: String]
    
    public init(type: CommandType, timestamp: Date = Date(), parameters: [String: String] = [:]) {
        self.type = type
        self.timestamp = timestamp
        self.parameters = parameters
    }
}

/// Recorded input event for test verification.
public struct RecordedInputEvent: Sendable, Equatable {
    public enum EventType: String, Sendable {
        case mouseMove, mouseDown, mouseUp, rightClick, scroll, keyDown, keyUp, textInput
    }
    
    public let type: EventType
    public let timestamp: Date
    public let parameters: [String: String]
    
    public init(type: EventType, timestamp: Date = Date(), parameters: [String: String] = [:]) {
        self.type = type
        self.timestamp = timestamp
        self.parameters = parameters
    }
}
