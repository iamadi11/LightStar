import Foundation

/// Protocol version for compatibility checking.
public let kLightStarProtocolVersion: UInt16 = 1

/// Bonjour service type for LightStar remote control.
public let kLightStarServiceType = "_lightstar._tcp"

/// Default port for the control server.
public let kLightStarDefaultPort: UInt16 = 19384

// MARK: - Message Types

/// Message type identifiers for the LightStar remote protocol.
public enum RemoteMessageType: UInt8, Codable, Sendable {
    // Connection
    case hello = 0x01
    case helloAck = 0x02
    case pair = 0x03
    case pairAck = 0x04
    case ping = 0x05
    case pong = 0x06
    case disconnect = 0x07
    
    // State queries
    case getState = 0x10
    case stateUpdate = 0x11
    
    // Light control
    case setPower = 0x20
    case setBrightness = 0x21
    case setColor = 0x22
    case setColorTemperature = 0x23
    case setEffect = 0x24
    case setEffectSpeed = 0x25
    case setEffectDirection = 0x26
    case setSyncMode = 0x27
    case selectDisplay = 0x28
    
    // Mac control (input)
    case mouseMove = 0x30
    case mouseDown = 0x31
    case mouseUp = 0x32
    case rightClick = 0x33
    case scroll = 0x34
    case keyDown = 0x35
    case keyUp = 0x36
    case textInput = 0x37
    case mediaKey = 0x38
    
    // Diagnostics
    case getDiagnostics = 0x40
    case diagnosticsUpdate = 0x41
    
    // Error
    case error = 0xFF
}

// MARK: - Message Structures

/// Base wrapper for all protocol messages.
public struct RemoteMessage: Codable, Sendable {
    public let type: RemoteMessageType
    public let payload: Data
    public let timestamp: TimeInterval
    
    public init(type: RemoteMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
        self.timestamp = Date().timeIntervalSince1970
    }
    
    public init<T: Encodable>(type: RemoteMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
        self.timestamp = Date().timeIntervalSince1970
    }
    
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Connection Messages

public struct HelloMessage: Codable, Sendable {
    public let protocolVersion: UInt16
    public let deviceName: String
    public let deviceType: String  // "macOS" or "iOS"
    
    public init(protocolVersion: UInt16 = kLightStarProtocolVersion, deviceName: String, deviceType: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceType = deviceType
    }
}

public struct HelloAckMessage: Codable, Sendable {
    public let accepted: Bool
    public let macName: String
    public let requiresPairing: Bool
    public let errorMessage: String?
    
    public init(accepted: Bool, macName: String, requiresPairing: Bool = false, errorMessage: String? = nil) {
        self.accepted = accepted
        self.macName = macName
        self.requiresPairing = requiresPairing
        self.errorMessage = errorMessage
    }
}

public struct PairMessage: Codable, Sendable {
    public let pairingCode: String
    
    public init(pairingCode: String) {
        self.pairingCode = pairingCode
    }
}

public struct PairAckMessage: Codable, Sendable {
    public let success: Bool
    public let sessionToken: String?
    public let errorMessage: String?
    
    public init(success: Bool, sessionToken: String? = nil, errorMessage: String? = nil) {
        self.success = success
        self.sessionToken = sessionToken
        self.errorMessage = errorMessage
    }
}

// MARK: - State Messages

public struct LightStarState: Codable, Sendable {
    public let isConnected: Bool
    public let isOn: Bool
    public let brightness: Double
    public let colorHue: Double
    public let colorSaturation: Double
    public let colorTemperature: Double
    public let syncMode: String
    public let effectID: UInt8?
    public let effectSpeed: Double
    public let effectForward: Bool
    public let selectedDisplayID: UInt32?
    public let availableDisplays: [DisplayInfo]
    public let syncColor: ColorInfo?
    public let protectedContentDetected: Bool
    
    public init(
        isConnected: Bool,
        isOn: Bool,
        brightness: Double,
        colorHue: Double,
        colorSaturation: Double,
        colorTemperature: Double,
        syncMode: String,
        effectID: UInt8? = nil,
        effectSpeed: Double = 0.5,
        effectForward: Bool = true,
        selectedDisplayID: UInt32? = nil,
        availableDisplays: [DisplayInfo] = [],
        syncColor: ColorInfo? = nil,
        protectedContentDetected: Bool = false
    ) {
        self.isConnected = isConnected
        self.isOn = isOn
        self.brightness = brightness
        self.colorHue = colorHue
        self.colorSaturation = colorSaturation
        self.colorTemperature = colorTemperature
        self.syncMode = syncMode
        self.effectID = effectID
        self.effectSpeed = effectSpeed
        self.effectForward = effectForward
        self.selectedDisplayID = selectedDisplayID
        self.availableDisplays = availableDisplays
        self.syncColor = syncColor
        self.protectedContentDetected = protectedContentDetected
    }
}

public struct DisplayInfo: Codable, Sendable, Identifiable {
    public let id: UInt32
    public let name: String
    
    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ColorInfo: Codable, Sendable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double
    
    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

// MARK: - Control Messages

public struct SetPowerMessage: Codable, Sendable {
    public let on: Bool
    public init(on: Bool) { self.on = on }
}

public struct SetBrightnessMessage: Codable, Sendable {
    public let brightness: Double
    public init(brightness: Double) { self.brightness = brightness }
}

public struct SetColorMessage: Codable, Sendable {
    public let hue: Double
    public let saturation: Double
    public init(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
    }
}

public struct SetColorTemperatureMessage: Codable, Sendable {
    public let temperature: Double
    public init(temperature: Double) { self.temperature = temperature }
}

public struct SetEffectMessage: Codable, Sendable {
    public let effectID: UInt8
    public init(effectID: UInt8) { self.effectID = effectID }
}

public struct SetEffectSpeedMessage: Codable, Sendable {
    public let speed: Double
    public init(speed: Double) { self.speed = speed }
}

public struct SetEffectDirectionMessage: Codable, Sendable {
    public let forward: Bool
    public init(forward: Bool) { self.forward = forward }
}

public struct SetSyncModeMessage: Codable, Sendable {
    public let mode: String
    public init(mode: String) { self.mode = mode }
}

public struct SelectDisplayMessage: Codable, Sendable {
    public let displayID: UInt32?
    public init(displayID: UInt32?) { self.displayID = displayID }
}

// MARK: - Input Messages (Mac Control)

public struct MouseMoveMessage: Codable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct MouseButtonMessage: Codable, Sendable {
    public let button: Int  // 0=left, 1=right, 2=middle
    public init(button: Int = 0) { self.button = button }
}

public struct ScrollMessage: Codable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct KeyMessage: Codable, Sendable {
    public let keyCode: UInt16
    public let modifiers: UInt32  // CGEventFlags
    public init(keyCode: UInt16, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct TextInputMessage: Codable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct MediaKeyMessage: Codable, Sendable {
    public enum MediaKey: String, Codable, Sendable {
        case playPause, nextTrack, previousTrack
        case volumeUp, volumeDown, mute
        case brightnessUp, brightnessDown
    }
    public let key: MediaKey
    public init(key: MediaKey) { self.key = key }
}

// MARK: - Error Messages

public struct ErrorMessage: Codable, Sendable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Message Framing

/// Encodes a message for network transmission with length prefix.
public func encodeMessage(_ message: RemoteMessage) throws -> Data {
    let encoded = try JSONEncoder().encode(message)
    var length = UInt32(encoded.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(encoded)
    return data
}

/// Decodes a message from network data (expects length-prefixed frame).
public func decodeMessage(from data: Data) throws -> (RemoteMessage, Int) {
    guard data.count >= 4 else {
        throw NSError(domain: "RemoteProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "Insufficient data for length prefix"])
    }
    let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let totalLength = Int(length) + 4
    guard data.count >= totalLength else {
        throw NSError(domain: "RemoteProtocol", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incomplete message"])
    }
    let messageData = data.subdata(in: 4..<totalLength)
    let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
    return (message, totalLength)
}
