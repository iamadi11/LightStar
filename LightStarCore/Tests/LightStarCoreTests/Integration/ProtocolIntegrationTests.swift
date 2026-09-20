import XCTest
@testable import LightStarCore

/// Integration tests for the remote control protocol.
/// Tests message handling, session management, and error cases.
///
/// EXECUTION_CATEGORY: MAC_REQUIRED (needs Swift runtime)
final class ProtocolIntegrationTests: XCTestCase {
    
    // MARK: - Message Validation Tests
    
    /// TEST_ID: P001
    /// Type 255 is the defined `.error` case, not an unknown tag.
    func testInvalidMessageTypeHandling() throws {
        let invalidJSON = """
        {"type":255,"payload":"","timestamp":0}
        """.data(using: .utf8)!
        
        // Should decode without throwing but type is .error
        let message = try JSONDecoder().decode(RemoteMessage.self, from: invalidJSON)
        XCTAssertEqual(message.type, .error)
    }
    
    /// TEST_ID: P002
    /// Tests that malformed JSON payloads throw appropriate errors.
    func testMalformedJSONPayload() throws {
        let message = RemoteMessage(type: .setBrightness, payload: "not json".data(using: .utf8)!)
        
        XCTAssertThrowsError(try message.decode(SetBrightnessMessage.self)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
    
    /// TEST_ID: P003
    /// Tests boundary values for brightness.
    func testBrightnessBoundaryValues() throws {
        let testCases: [(Double, Bool)] = [
            (0.0, true),    // min valid
            (1.0, true),    // max valid
            (0.5, true),    // mid valid
            (-0.1, true),   // negative (should encode, validation at higher level)
            (1.1, true),    // above max (should encode, validation at higher level)
        ]
        
        for (value, shouldEncode) in testCases {
            let payload = SetBrightnessMessage(brightness: value)
            if shouldEncode {
                let message = try RemoteMessage(type: .setBrightness, content: payload)
                let decoded = try message.decode(SetBrightnessMessage.self)
                XCTAssertEqual(decoded.brightness, value, accuracy: 0.0001, "Failed for value: \(value)")
            }
        }
    }
    
    /// TEST_ID: P004
    /// Tests color hue boundary values (0-1 representing 0-360 degrees).
    func testColorHueBoundaryValues() throws {
        let testCases: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        
        for hue in testCases {
            let payload = SetColorMessage(hue: hue, saturation: 1.0)
            let message = try RemoteMessage(type: .setColor, content: payload)
            let decoded = try message.decode(SetColorMessage.self)
            XCTAssertEqual(decoded.hue, hue, accuracy: 0.0001)
        }
    }
    
    /// TEST_ID: P005
    /// Tests effect ID range (0x01-0xFF).
    func testEffectIDRange() throws {
        let testIDs: [UInt8] = [0x01, 0x10, 0x80, 0xFF]
        
        for id in testIDs {
            let payload = SetEffectMessage(effectID: id)
            let message = try RemoteMessage(type: .setEffect, content: payload)
            let decoded = try message.decode(SetEffectMessage.self)
            XCTAssertEqual(decoded.effectID, id)
        }
    }
    
    /// TEST_ID: P006
    /// Tests sync mode string values.
    func testSyncModeValues() throws {
        let validModes = ["Off", "Video", "Audio", "Video+Audio"]
        
        for mode in validModes {
            let payload = SetSyncModeMessage(mode: mode)
            let message = try RemoteMessage(type: .setSyncMode, content: payload)
            let decoded = try message.decode(SetSyncModeMessage.self)
            XCTAssertEqual(decoded.mode, mode)
        }
    }
    
    /// TEST_ID: P007
    /// Tests mouse delta values including negative and zero.
    func testMouseDeltaValues() throws {
        let testCases: [(Double, Double)] = [
            (0, 0),
            (10, 10),
            (-10, -10),
            (0.5, -0.5),
            (1000, 1000),   // Large movement
            (-1000, -1000), // Large negative
        ]
        
        for (dx, dy) in testCases {
            let payload = MouseMoveMessage(deltaX: dx, deltaY: dy)
            let message = try RemoteMessage(type: .mouseMove, content: payload)
            let decoded = try message.decode(MouseMoveMessage.self)
            XCTAssertEqual(decoded.deltaX, dx, accuracy: 0.0001)
            XCTAssertEqual(decoded.deltaY, dy, accuracy: 0.0001)
        }
    }
    
    /// TEST_ID: P008
    /// Tests key message with various modifier combinations.
    func testKeyModifierCombinations() throws {
        let modifierCombinations: [UInt32] = [
            0,              // No modifiers
            0x00020000,     // Shift
            0x00100000,     // Control
            0x00080000,     // Option
            0x00100000 | 0x00020000, // Control+Shift
        ]
        
        for modifiers in modifierCombinations {
            let payload = KeyMessage(keyCode: 0, modifiers: modifiers)
            let message = try RemoteMessage(type: .keyDown, content: payload)
            let decoded = try message.decode(KeyMessage.self)
            XCTAssertEqual(decoded.modifiers, modifiers)
        }
    }
    
    /// TEST_ID: P009
    /// Tests text input with various character sets.
    func testTextInputCharacterSets() throws {
        let testStrings = [
            "Hello",
            "Hello World!",
            "123456",
            "Special: @#$%^&*()",
            "Unicode: 日本語 中文 한국어",
            "Emoji: 😀🎉🚀",
            "",  // Empty string
            String(repeating: "a", count: 1000), // Long string
        ]
        
        for text in testStrings {
            let payload = TextInputMessage(text: text)
            let message = try RemoteMessage(type: .textInput, content: payload)
            let decoded = try message.decode(TextInputMessage.self)
            XCTAssertEqual(decoded.text, text)
        }
    }
    
    /// TEST_ID: P010
    /// Tests all media key types.
    func testAllMediaKeyTypes() throws {
        let keys: [MediaKeyMessage.MediaKey] = [
            .playPause, .nextTrack, .previousTrack,
            .volumeUp, .volumeDown, .mute,
            .brightnessUp, .brightnessDown
        ]
        
        for key in keys {
            let payload = MediaKeyMessage(key: key)
            let message = try RemoteMessage(type: .mediaKey, content: payload)
            let decoded = try message.decode(MediaKeyMessage.self)
            XCTAssertEqual(decoded.key, key)
        }
    }

    func testMacSystemActionTypes() throws {
        let actions: [MacSystemAction] = [
            .spotlight, .missionControl, .applicationWindows, .desktop, .launchpad, .lockScreen,
            .undo, .cut, .copy, .paste, .selectAll, .emoji,
            .screenshot, .screenshotSelection, .spaceLeft, .spaceRight, .centerPointer, .wakeDisplay
        ]
        for action in actions {
            let message = try RemoteMessage(type: .macAction, content: MacActionMessage(action: action))
            let decoded = try message.decode(MacActionMessage.self)
            XCTAssertEqual(decoded.action, action)
        }
    }
    
    // MARK: - State Message Tests
    
    /// TEST_ID: P011
    /// Tests LightStarState with all optional fields.
    func testLightStarStateFullyPopulated() throws {
        let displays = [
            DisplayInfo(id: 1, name: "Main Display"),
            DisplayInfo(id: 2, name: "External Display")
        ]
        let syncColor = ColorInfo(hue: 0.5, saturation: 0.8, brightness: 0.9)
        
        let state = LightStarState(
            isConnected: true,
            isOn: true,
            brightness: 0.75,
            colorHue: 0.5,
            colorSaturation: 0.8,
            colorTemperature: 4000,
            syncMode: "Video",
            effectID: 0x05,
            effectSpeed: 0.6,
            effectForward: false,
            selectedDisplayID: 1,
            availableDisplays: displays,
            syncColor: syncColor,
            protectedContentDetected: true
        )
        
        let message = try RemoteMessage(type: .stateUpdate, content: state)
        let decoded = try message.decode(LightStarState.self)
        
        XCTAssertEqual(decoded.isConnected, true)
        XCTAssertEqual(decoded.isOn, true)
        XCTAssertEqual(decoded.brightness, 0.75, accuracy: 0.0001)
        XCTAssertEqual(decoded.effectID, 0x05)
        XCTAssertEqual(decoded.effectForward, false)
        XCTAssertEqual(decoded.availableDisplays.count, 2)
        XCTAssertEqual(decoded.syncColor?.hue, 0.5)
        XCTAssertEqual(decoded.protectedContentDetected, true)
    }
    
    /// TEST_ID: P012
    /// Tests LightStarState with minimal fields.
    func testLightStarStateMinimal() throws {
        let state = LightStarState(
            isConnected: false,
            isOn: false,
            brightness: 0,
            colorHue: 0,
            colorSaturation: 0,
            colorTemperature: 0,
            syncMode: "Off"
        )
        
        let message = try RemoteMessage(type: .stateUpdate, content: state)
        let decoded = try message.decode(LightStarState.self)
        
        XCTAssertEqual(decoded.isConnected, false)
        XCTAssertNil(decoded.effectID)
        XCTAssertNil(decoded.syncColor)
        XCTAssertTrue(decoded.availableDisplays.isEmpty)
    }
    
    // MARK: - Error Message Tests
    
    /// TEST_ID: P013
    /// Tests error message encoding/decoding.
    func testErrorMessage() throws {
        let error = ErrorMessage(code: 401, message: "Unauthorized")
        let message = try RemoteMessage(type: .error, content: error)
        let decoded = try message.decode(ErrorMessage.self)
        
        XCTAssertEqual(decoded.code, 401)
        XCTAssertEqual(decoded.message, "Unauthorized")
    }
    
    // MARK: - Framing Edge Cases
    
    /// TEST_ID: P014
    /// Tests that zero-length payload is handled.
    func testZeroLengthPayload() throws {
        let message = RemoteMessage(type: .ping, payload: Data())
        let encoded = try encodeMessage(message)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertTrue(decoded.payload.isEmpty)
    }
    
    /// TEST_ID: P015
    /// Tests large message encoding (stress test).
    func testLargeMessageEncoding() throws {
        let largeText = String(repeating: "X", count: 10_000)
        let payload = TextInputMessage(text: largeText)
        let message = try RemoteMessage(type: .textInput, content: payload)
        let encoded = try encodeMessage(message)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        let decodedPayload = try decoded.decode(TextInputMessage.self)
        XCTAssertEqual(decodedPayload.text, largeText)
    }
    
    /// TEST_ID: P016
    /// Tests decoding with extra trailing data (should only consume one message).
    func testTrailingDataIgnored() throws {
        let msg1 = try encodeMessage(RemoteMessage(type: .ping))
        var data = msg1
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF]) // Garbage
        
        let (decoded, consumed) = try decodeMessage(from: data)
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(consumed, msg1.count)
    }

    func testDecodeMessageFromUnalignedBuffer() throws {
        let encoded = try encodeMessage(RemoteMessage(type: .ping))
        var padded = Data([0xAB])
        padded.append(encoded)
        let unaligned = Data(padded.dropFirst())
        let (decoded, consumed) = try decodeMessage(from: unaligned)
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(consumed, encoded.count)
    }

    func testDecodeMessageAfterRemoveFirst() throws {
        let encoded = try encodeMessage(RemoteMessage(type: .hello))
        var buffer = Data([0xDE, 0xAD])
        buffer.append(encoded)
        buffer.removeFirst(2)
        let (decoded, consumed) = try decodeMessage(from: buffer)
        XCTAssertEqual(decoded.type, .hello)
        XCTAssertEqual(consumed, encoded.count)
    }

    func testDecodeMessageRejectsZeroLength() {
        XCTAssertThrowsError(try decodeMessage(from: Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .invalidLength)
        }
    }

    func testDecodeMessageRejectsInvalidLength() {
        let bogus = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        XCTAssertThrowsError(try decodeMessage(from: bogus)) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .invalidLength)
        }
    }

    func testDecodeMessageRejectsOneByteOverPayloadCapWithoutAllocatingBody() {
        var length = (kLightStarMaxMessagePayloadBytes + 1).bigEndian
        let prefix = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(try decodeMessage(from: prefix)) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .invalidLength)
        }
    }

    func testDecodeMessageWaitsForIncompletePayload() {
        var length = UInt32(10).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(Data(repeating: 0x7B, count: 3))
        XCTAssertThrowsError(try decodeMessage(from: frame)) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .incompleteMessage)
        }
    }

    func testDecodePointerFrameWaitsWhenLengthIsPointerButBytesAreShort() {
        var length = UInt32(kPointerFramePayloadLength).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(contentsOf: [kPointerFrameMagic, 0, 0, 0])
        XCTAssertThrowsError(try decodeMessage(from: frame)) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .incompleteMessage)
        }
    }

    func testLengthNineWithoutPointerMagicFallsThroughToJSON() {
        var length = UInt32(kPointerFramePayloadLength).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(Data(repeating: 0x7B, count: Int(kPointerFramePayloadLength)))
        XCTAssertThrowsError(try decodeMessage(from: frame)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testUnknownMessageTypeFailsToDecode() {
        let invalidJSON = """
        {"type":153,"payload":"","timestamp":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteMessage.self, from: invalidJSON))
    }
    
    // MARK: - Connection Message Tests
    
    /// TEST_ID: P017
    /// Tests hello message with protocol version.
    func testHelloWithProtocolVersion() throws {
        let hello = HelloMessage(protocolVersion: 1, deviceName: "iPhone 15", deviceType: "iOS")
        let message = try RemoteMessage(type: .hello, content: hello)
        let decoded = try message.decode(HelloMessage.self)
        
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.deviceName, "iPhone 15")
        XCTAssertEqual(decoded.deviceType, "iOS")
    }
    
    /// TEST_ID: P018
    /// Tests pairing message.
    func testPairingMessage() throws {
        // PairMessage does not validate format; generation does.
        let pair = PairMessage(pairingCode: "A2B3C4")
        let message = try RemoteMessage(type: .pair, content: pair)
        let decoded = try message.decode(PairMessage.self)

        XCTAssertEqual(decoded.pairingCode, "A2B3C4")
        XCTAssertEqual(decoded.pairingCode.count, kLightStarPairingCodeLength)
    }
    
    /// TEST_ID: P019
    /// Tests pairing ack with session token.
    func testPairingAckWithToken() throws {
        let ack = PairAckMessage(success: true, sessionToken: "abc123-token")
        let message = try RemoteMessage(type: .pairAck, content: ack)
        let decoded = try message.decode(PairAckMessage.self)
        
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.sessionToken, "abc123-token")
        XCTAssertNil(decoded.errorMessage)
    }
    
    /// TEST_ID: P020
    /// Tests pairing ack with error.
    func testPairingAckWithError() throws {
        let ack = PairAckMessage(success: false, sessionToken: nil, errorMessage: "Invalid code")
        let message = try RemoteMessage(type: .pairAck, content: ack)
        let decoded = try message.decode(PairAckMessage.self)
        
        XCTAssertFalse(decoded.success)
        XCTAssertNil(decoded.sessionToken)
        XCTAssertEqual(decoded.errorMessage, "Invalid code")
    }

    func testWriteFrameRoundTrip() throws {
        let frame: [UInt8] = [0xBC, 0x01, 0x01, 0x01, 0x55]
        let payload = WriteFrameMessage(bytes: frame)
        let message = try RemoteMessage(type: .writeFrame, content: payload)
        let decoded = try message.decode(WriteFrameMessage.self)
        XCTAssertEqual(Array(decoded.bytes), frame)
        XCTAssertEqual(message.type, .writeFrame)
    }
}
