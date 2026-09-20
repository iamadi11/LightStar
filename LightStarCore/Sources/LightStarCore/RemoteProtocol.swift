import Foundation

/// Protocol version for compatibility checking.
public let kLightStarProtocolVersion: UInt16 = 1

/// Bonjour service type for LightStar remote control.
public let kLightStarServiceType = "_lightstar._tcp"

/// Default port for the control server.
public let kLightStarDefaultPort: UInt16 = 19384

/// Length of generated pairing codes (alphanumeric, excluding ambiguous characters).
public let kLightStarPairingCodeLength = 6

/// Alphabet used by `RemoteControlServer.generatePairingCode()` (no 0/1/I/O).
public let kLightStarPairingCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

/// Maximum JSON payload length accepted by `decodeMessage` (1 MiB).
public let kLightStarMaxMessagePayloadBytes: UInt32 = 1_048_576

/// Maximum TCP reassembly buffer used by client and server receive loops (2 MiB).
public let kLightStarMaxReceiveBufferBytes = 2 * 1024 * 1024

/// Same overflow check as the TCP receive loops: equal-to-max is allowed.
public func receiveBufferWouldOverflow(
    currentCount: Int,
    incomingCount: Int,
    maxCount: Int = kLightStarMaxReceiveBufferBytes
) -> Bool {
    currentCount + incomingCount > maxCount
}

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
    case connectStrip = 0x29
    case disconnectStrip = 0x2A
    case writeFrame = 0x2B
    
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
    case macAction = 0x39
    
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

public struct LightStarState: Codable, Sendable, Equatable {
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
    public let trackpad: MacTrackpadPrefs?
    
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
        protectedContentDetected: Bool = false,
        trackpad: MacTrackpadPrefs? = nil
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
        self.trackpad = trackpad
    }
}

/// macOS Trackpad pane values, mirrored onto the iPhone remote.
public struct MacTrackpadPrefs: Codable, Sendable, Equatable {
    public var tapToClick: Bool
    public var twoFingerSecondaryClick: Bool
    public var threeFingerDrag: Bool
    public var naturalScrolling: Bool
    /// Apple `com.apple.trackpad.scaling` (0...3). Acceleration uses this, not a second multiplier.
    public var pointerSpeed: Double
    public var doubleClickThreshold: Double
    public var threeFingerHorizSwipe: Bool?
    public var threeFingerVertSwipe: Bool?

    public init(
        tapToClick: Bool,
        twoFingerSecondaryClick: Bool,
        threeFingerDrag: Bool,
        naturalScrolling: Bool,
        pointerSpeed: Double,
        doubleClickThreshold: Double,
        threeFingerHorizSwipe: Bool? = nil,
        threeFingerVertSwipe: Bool? = nil
    ) {
        self.tapToClick = tapToClick
        self.twoFingerSecondaryClick = twoFingerSecondaryClick
        self.threeFingerDrag = threeFingerDrag
        self.naturalScrolling = naturalScrolling
        self.pointerSpeed = pointerSpeed
        self.doubleClickThreshold = doubleClickThreshold
        self.threeFingerHorizSwipe = threeFingerHorizSwipe
        self.threeFingerVertSwipe = threeFingerVertSwipe
    }
}

public struct DisplayInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UInt32
    public let name: String
    
    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ColorInfo: Codable, Sendable, Equatable {
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

public struct WriteFrameMessage: Codable, Sendable {
    public let bytes: Data
    public init(bytes: [UInt8]) { self.bytes = Data(bytes) }
    public init(bytes: Data) { self.bytes = bytes }
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
    public let clickCount: Int?
    public init(button: Int = 0, clickCount: Int? = nil) {
        self.button = button
        self.clickCount = clickCount
    }
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

/// CGEventFlags bits used by the iPhone remote.
public enum RemoteModifier {
    public static let command: UInt32 = 0x100000
    public static let shift: UInt32 = 0x20000
    public static let option: UInt32 = 0x80000
    public static let control: UInt32 = 0x40000
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

public enum MacSystemAction: String, Codable, Sendable {
    case spotlight, missionControl, applicationWindows, desktop, launchpad, lockScreen
    case undo, cut, copy, paste, selectAll, emoji
    case screenshot, screenshotSelection
    case spaceLeft, spaceRight
    case centerPointer
    case wakeDisplay
}

public struct MacActionMessage: Codable, Sendable {
    public let action: MacSystemAction
    public init(action: MacSystemAction) { self.action = action }
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

enum RemoteProtocolError: Error, Equatable {
    case insufficientData
    case incompleteMessage
    case invalidLength
}

/// Encodes a message for network transmission with length prefix.
public func encodeMessage(_ message: RemoteMessage) throws -> Data {
    let encoded = try JSONEncoder().encode(message)
    var length = UInt32(encoded.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(encoded)
    return data
}

/// 13-byte pointer frame: 4-byte length + `0xB1` + kind + int16 dx/dy × 10.
/// `{` never collides with `0xB1`, so this sits beside JSON frames on the same TCP stream.
public let kPointerFrameMagic: UInt8 = 0xB1
public let kPointerFramePayloadLength = 9
public let kPointerFrameLength = 13

public func encodePointerFrame(deltaX: Double, deltaY: Double, isScroll: Bool) -> Data {
    var length = UInt32(kPointerFramePayloadLength).bigEndian
    var data = Data(bytes: &length, count: 4)
    var payload = Data(count: kPointerFramePayloadLength)
    payload[0] = kPointerFrameMagic
    payload[1] = isScroll ? 1 : 0
    var x = pointerDeltaToInt16(deltaX).littleEndian
    var y = pointerDeltaToInt16(deltaY).littleEndian
    payload.replaceSubrange(2..<4, with: Data(bytes: &x, count: 2))
    payload.replaceSubrange(4..<6, with: Data(bytes: &y, count: 2))
    data.append(payload)
    return data
}

/// Maps a pointer delta to the on-wire ×10 Int16 without trapping on huge finite values.
func pointerDeltaToInt16(_ value: Double) -> Int16 {
    guard value.isFinite else { return 0 }
    let scaled = value * 10
    guard scaled.isFinite else { return value > 0 ? .max : .min }
    let rounded = scaled.rounded()
    if rounded >= Double(Int16.max) { return .max }
    if rounded <= Double(Int16.min) { return .min }
    return Int16(rounded)
}

public func decodePointerFrame(from data: Data) throws -> (deltaX: Double, deltaY: Double, isScroll: Bool, consumed: Int)? {
    guard data.count >= 4 else { throw RemoteProtocolError.insufficientData }
    return try data.withUnsafeBytes { buf in
        let length = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        guard length == kPointerFramePayloadLength else { return nil }
        guard buf.count >= kPointerFrameLength else { throw RemoteProtocolError.incompleteMessage }
        guard buf[4] == kPointerFrameMagic else { return nil }
        let x = Int16(littleEndian: buf.loadUnaligned(fromByteOffset: 6, as: Int16.self))
        let y = Int16(littleEndian: buf.loadUnaligned(fromByteOffset: 8, as: Int16.self))
        return (Double(x) / 10.0, Double(y) / 10.0, buf[5] != 0, kPointerFrameLength)
    }
}

/// Decodes a message from network data (expects length-prefixed frame).
public func decodeMessage(from data: Data) throws -> (RemoteMessage, Int) {
    if let pointer = try decodePointerFrame(from: data) {
        let type: RemoteMessageType = pointer.isScroll ? .scroll : .mouseMove
        let payload = try JSONEncoder().encode(
            MouseMoveMessage(deltaX: pointer.deltaX, deltaY: pointer.deltaY)
        )
        return (RemoteMessage(type: type, payload: payload), pointer.consumed)
    }
    return try data.withUnsafeBytes { buf in
        guard buf.count >= 4 else { throw RemoteProtocolError.insufficientData }
        let length = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        guard length > 0, length <= kLightStarMaxMessagePayloadBytes else { throw RemoteProtocolError.invalidLength }
        let totalLength = Int(length) + 4
        guard buf.count >= totalLength else { throw RemoteProtocolError.incompleteMessage }
        let messageData = Data(buf[4..<totalLength])
        let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
        return (message, totalLength)
    }
}
