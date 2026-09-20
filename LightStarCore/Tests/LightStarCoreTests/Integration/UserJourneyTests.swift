import XCTest
@testable import LightStarCore

/// End-to-end user journey tests using mock dependencies.
/// Tests the complete flow from user action to system response.
///
/// EXECUTION_CATEGORY: MAC_REQUIRED (needs Swift runtime and macOS frameworks)
final class UserJourneyTests: XCTestCase {
    
    // MARK: - Journey 1: First-Time Setup
    
    /// TEST_ID: J1-001
    /// Tests the complete first-time setup flow with mocks.
    func testFirstTimeSetupJourney() async throws {
        // 1. Create components
        let authenticator = MockSessionAuthenticator()
        let lightingController = MockLightingController()
        
        // 2. Server generates pairing code
        let pairingCode = authenticator.generatePairingCode()
        XCTAssertEqual(pairingCode.count, 6)
        
        // 3. Client sends hello
        let hello = HelloMessage(deviceName: "Test iPhone", deviceType: "iOS")
        let helloMsg = try RemoteMessage(type: .hello, content: hello)
        XCTAssertEqual(helloMsg.type, .hello)
        
        // 4. Server responds with helloAck requiring pairing
        let helloAck = HelloAckMessage(accepted: true, macName: "Test Mac", requiresPairing: true)
        let ackMsg = try RemoteMessage(type: .helloAck, content: helloAck)
        XCTAssertTrue(try ackMsg.decode(HelloAckMessage.self).requiresPairing)
        
        // 5. Client sends pairing code
        let pair = PairMessage(pairingCode: pairingCode)
        let pairMsg = try RemoteMessage(type: .pair, content: pair)
        XCTAssertEqual(try pairMsg.decode(PairMessage.self).pairingCode, pairingCode)
        
        // 6. Server validates and issues token
        let token = authenticator.validatePairingCode(pairingCode, clientID: "test-client")
        XCTAssertNotNil(token, "Valid pairing code should produce session token")
        
        // 7. Server sends pairAck with token
        let pairAck = PairAckMessage(success: true, sessionToken: token)
        let pairAckMsg = try RemoteMessage(type: .pairAck, content: pairAck)
        XCTAssertTrue(try pairAckMsg.decode(PairAckMessage.self).success)
        
        // 8. Verify session is active
        XCTAssertTrue(authenticator.validateSessionToken(token!))
    }
    
    /// TEST_ID: J1-002
    /// Tests failed pairing with wrong code.
    func testFailedPairingJourney() {
        let authenticator = MockSessionAuthenticator()
        let realCode = authenticator.generatePairingCode()

        // Produce a wrong code by rotating the first character — guaranteed != realCode.
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let firstChar = realCode.unicodeScalars.first.map(Character.init) ?? Character("A")
        let nextChar = chars[(chars.firstIndex(of: firstChar).map { ($0 + 1) % chars.count } ?? 1)]
        let wrongCode = String(nextChar) + realCode.dropFirst()

        // Client sends wrong code
        let token = authenticator.validatePairingCode(wrongCode, clientID: "test-client")
        XCTAssertNil(token, "Wrong pairing code should be rejected")

        // Failed attempt should be tracked
        XCTAssertEqual(authenticator.failedAttemptCount(for: "test-client"), 1)
    }
    
    // MARK: - Journey 2: Lighting Control
    
    /// TEST_ID: J2-001
    /// Tests brightness control from iPhone to Mac.
    func testBrightnessControlJourney() throws {
        let lightingController = MockLightingController()
        let authenticator = MockSessionAuthenticator()
        let sessionToken = authenticator.createTestSession()
        
        // 1. Validate session
        XCTAssertTrue(authenticator.validateSessionToken(sessionToken))
        
        // 2. Create brightness command
        let payload = SetBrightnessMessage(brightness: 0.75)
        let message = try RemoteMessage(type: .setBrightness, content: payload)
        
        // 3. Decode and execute
        let decoded = try message.decode(SetBrightnessMessage.self)
        lightingController.setBrightness(decoded.brightness)
        
        // 4. Verify state
        XCTAssertEqual(lightingController.brightness, 0.75, accuracy: 0.001)
        XCTAssertEqual(lightingController.commandCount(ofType: .brightness), 1)
    }
    
    /// TEST_ID: J2-002
    /// Tests power on/off control.
    func testPowerControlJourney() throws {
        let lightingController = MockLightingController()
        
        // Power on
        let powerOn = SetPowerMessage(on: true)
        let onMsg = try RemoteMessage(type: .setPower, content: powerOn)
        lightingController.setPower(on: try onMsg.decode(SetPowerMessage.self).on)
        XCTAssertTrue(lightingController.isOn)
        
        // Power off
        let powerOff = SetPowerMessage(on: false)
        let offMsg = try RemoteMessage(type: .setPower, content: powerOff)
        lightingController.setPower(on: try offMsg.decode(SetPowerMessage.self).on)
        XCTAssertFalse(lightingController.isOn)
        
        // Verify command history
        XCTAssertEqual(lightingController.commandCount(ofType: .power), 2)
    }
    
    /// TEST_ID: J2-003
    /// Tests color change control.
    func testColorControlJourney() throws {
        let lightingController = MockLightingController()
        
        let setColor = SetColorMessage(hue: 0.5, saturation: 0.8)
        let message = try RemoteMessage(type: .setColor, content: setColor)
        let decoded = try message.decode(SetColorMessage.self)
        
        lightingController.setColor(hue: decoded.hue, saturation: decoded.saturation)
        
        XCTAssertEqual(lightingController.hue, 0.5, accuracy: 0.001)
        XCTAssertEqual(lightingController.saturation, 0.8, accuracy: 0.001)
    }
    
    /// TEST_ID: J2-004
    /// Tests effect control.
    func testEffectControlJourney() throws {
        let lightingController = MockLightingController()
        
        // Set effect
        let setEffect = SetEffectMessage(effectID: 0x10)
        let effectMsg = try RemoteMessage(type: .setEffect, content: setEffect)
        lightingController.setEffect(id: try effectMsg.decode(SetEffectMessage.self).effectID)
        XCTAssertEqual(lightingController.effectID, 0x10)
        
        // Set speed
        let setSpeed = SetEffectSpeedMessage(speed: 0.8)
        let speedMsg = try RemoteMessage(type: .setEffectSpeed, content: setSpeed)
        lightingController.setEffectSpeed(try speedMsg.decode(SetEffectSpeedMessage.self).speed)
        XCTAssertEqual(lightingController.effectSpeed, 0.8, accuracy: 0.001)
        
        // Set direction
        let setDir = SetEffectDirectionMessage(forward: false)
        let dirMsg = try RemoteMessage(type: .setEffectDirection, content: setDir)
        lightingController.setEffectDirection(forward: try dirMsg.decode(SetEffectDirectionMessage.self).forward)
        XCTAssertFalse(lightingController.effectForward)
    }
    
    // MARK: - Journey 3: Screen Synchronization
    
    #if os(macOS)
    /// TEST_ID: J3-001
    /// Tests screen sync activation flow.
    @MainActor
    func testScreenSyncJourney() async throws {
        let mockProvider = MockScreenFrameProvider()
        let lightingController = MockLightingController()
        
        // Configure frames
        mockProvider.framesToDeliver = [.pureRed, .pureGreen, .pureBlue]
        mockProvider.frameDelay = 0.01
        
        // Set up frame handler
        var processedColors: [(Double, Double, Double)] = []
        mockProvider.onFrame = { frame in
            processedColors.append((frame.dominantHue, frame.dominantSaturation, frame.dominantBrightness))
            // In real implementation, this would update lighting
            lightingController.setColor(hue: frame.dominantHue, saturation: frame.dominantSaturation)
        }
        
        // Start capture
        try await mockProvider.start()
        XCTAssertTrue(mockProvider.isRunning)
        
        // Wait for frames
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Stop
        await mockProvider.stop()
        XCTAssertFalse(mockProvider.isRunning)
        
        // Verify processing
        XCTAssertGreaterThanOrEqual(processedColors.count, 3)
        XCTAssertGreaterThan(lightingController.commandCount(ofType: .color), 0)
    }
    
    /// TEST_ID: J3-002
    /// Tests protected content detection during sync.
    @MainActor
    func testProtectedContentDuringSync() async throws {
        let mockProvider = MockScreenFrameProvider()
        mockProvider.framesToDeliver = [.normalDesktop, .protectedContent, .normalDesktop]
        mockProvider.frameDelay = 0.01
        
        var detectedProtection = false
        mockProvider.onFrame = { frame in
            if frame.suspectedProtectedContent {
                detectedProtection = true
            }
        }
        
        try await mockProvider.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await mockProvider.stop()
        
        XCTAssertTrue(detectedProtection)
    }
    #endif
    
    // MARK: - Journey 4: Remote Input
    
    #if os(macOS)
    /// TEST_ID: J4-001
    /// Tests trackpad gesture flow.
    func testTrackpadGestureJourney() throws {
        let inputController = MockInputController()
        let authenticator = MockSessionAuthenticator()
        let sessionToken = authenticator.createTestSession()
        
        // Validate session first
        XCTAssertTrue(authenticator.validateSessionToken(sessionToken))
        
        // Send mouse move
        let move = MouseMoveMessage(deltaX: 10, deltaY: -5)
        let moveMsg = try RemoteMessage(type: .mouseMove, content: move)
        let decoded = try moveMsg.decode(MouseMoveMessage.self)
        
        inputController.moveMouse(deltaX: decoded.deltaX, deltaY: decoded.deltaY)
        
        // Verify
        XCTAssertEqual(inputController.currentMouseX, 10)
        XCTAssertEqual(inputController.currentMouseY, -5)
        XCTAssertEqual(inputController.events(ofType: .mouseMove).count, 1)
    }
    
    /// TEST_ID: J4-002
    /// Tests click gesture flow.
    func testClickGestureJourney() throws {
        let inputController = MockInputController()
        
        // Left click (down + up)
        inputController.mouseDown(button: 0)
        XCTAssertTrue(inputController.isLeftMouseDown)
        
        inputController.mouseUp(button: 0)
        XCTAssertFalse(inputController.isLeftMouseDown)
        
        // Right click
        inputController.rightClick()
        
        XCTAssertEqual(inputController.events(ofType: .mouseDown).count, 1)
        XCTAssertEqual(inputController.events(ofType: .mouseUp).count, 1)
        XCTAssertEqual(inputController.events(ofType: .rightClick).count, 1)
    }
    
    /// TEST_ID: J4-003
    /// Tests scroll gesture flow.
    func testScrollGestureJourney() throws {
        let inputController = MockInputController()
        
        let scroll = ScrollMessage(deltaX: 0, deltaY: -20)
        let scrollMsg = try RemoteMessage(type: .scroll, content: scroll)
        let decoded = try scrollMsg.decode(ScrollMessage.self)
        
        inputController.scroll(deltaX: decoded.deltaX, deltaY: decoded.deltaY)
        
        let scrollEvents = inputController.events(ofType: .scroll)
        XCTAssertEqual(scrollEvents.count, 1)
        XCTAssertEqual(scrollEvents[0].parameters["deltaY"], "-20.0")
    }
    
    /// TEST_ID: J4-004
    /// Tests keyboard input flow.
    func testKeyboardInputJourney() throws {
        let inputController = MockInputController()
        
        // Key down
        let keyDown = KeyMessage(keyCode: 0, modifiers: 0) // 'a' key
        let downMsg = try RemoteMessage(type: .keyDown, content: keyDown)
        let decoded = try downMsg.decode(KeyMessage.self)
        
        inputController.keyDown(keyCode: decoded.keyCode, modifiers: CGEventFlags(rawValue: UInt64(decoded.modifiers)))
        XCTAssertTrue(inputController.pressedKeys.contains(0))
        
        // Key up
        inputController.keyUp(keyCode: decoded.keyCode, modifiers: CGEventFlags(rawValue: UInt64(decoded.modifiers)))
        XCTAssertFalse(inputController.pressedKeys.contains(0))
    }
    
    /// TEST_ID: J4-005
    /// Tests text input flow.
    func testTextInputJourney() throws {
        let inputController = MockInputController()
        
        let text = TextInputMessage(text: "Hello World")
        let textMsg = try RemoteMessage(type: .textInput, content: text)
        let decoded = try textMsg.decode(TextInputMessage.self)
        
        inputController.typeText(decoded.text)
        
        XCTAssertEqual(inputController.typedText, "Hello World")
        XCTAssertEqual(inputController.events(ofType: .textInput).count, 1)
    }
    #endif
    
    // MARK: - Journey 5: Connection Failure
    
    /// TEST_ID: J5-001
    /// Tests session cleanup on disconnect.
    func testDisconnectCleanup() {
        let authenticator = MockSessionAuthenticator()
        let sessionToken = authenticator.createTestSession()
        
        // Session active
        XCTAssertTrue(authenticator.validateSessionToken(sessionToken))
        XCTAssertEqual(authenticator.activeSessionCount, 1)
        
        // Disconnect
        authenticator.invalidateSession(sessionToken)
        
        // Session should be invalid
        XCTAssertFalse(authenticator.validateSessionToken(sessionToken))
        XCTAssertEqual(authenticator.activeSessionCount, 0)
    }
    
    /// TEST_ID: J5-002
    /// Tests that stale session is rejected.
    func testStaleSessionRejected() {
        let authenticator = MockSessionAuthenticator()
        let sessionToken = authenticator.createTestSession()
        
        // Invalidate
        authenticator.invalidateSession(sessionToken)
        
        // Attempt to use stale token
        let valid = authenticator.validateSessionToken(sessionToken)
        XCTAssertFalse(valid, "Stale session should be rejected")
    }
    
    /// TEST_ID: J5-003
    /// Tests reconnection requires new session.
    func testReconnectionRequiresNewSession() {
        let authenticator = MockSessionAuthenticator()
        
        // First session
        let token1 = authenticator.createTestSession()
        XCTAssertTrue(authenticator.validateSessionToken(token1))
        
        // Disconnect
        authenticator.invalidateSession(token1)
        
        // Reconnect - old token invalid
        XCTAssertFalse(authenticator.validateSessionToken(token1))
        
        // New session required
        let token2 = authenticator.createTestSession()
        XCTAssertNotEqual(token1, token2)
        XCTAssertTrue(authenticator.validateSessionToken(token2))
    }
    
    // MARK: - Combined Journey Tests
    
    /// TEST_ID: JC-001
    /// Tests complete control flow from connection to lighting change.
    func testCompleteControlFlow() throws {
        let authenticator = MockSessionAuthenticator()
        let lightingController = MockLightingController()
        
        // Setup
        let pairingCode = authenticator.generatePairingCode()
        let sessionToken = authenticator.validatePairingCode(pairingCode, clientID: "iphone")!
        
        // Verify session
        XCTAssertTrue(authenticator.validateSessionToken(sessionToken))
        
        // Control sequence
        lightingController.setPower(on: true)
        lightingController.setBrightness(0.5)
        lightingController.setColor(hue: 0.3, saturation: 0.7)
        lightingController.setEffect(id: 0x05)
        
        // Verify final state
        XCTAssertTrue(lightingController.isOn)
        XCTAssertEqual(lightingController.brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(lightingController.hue, 0.3, accuracy: 0.001)
        XCTAssertEqual(lightingController.effectID, 0x05)
        
        // Verify command history
        XCTAssertEqual(lightingController.commandHistory.count, 4)
    }
    
    #if os(macOS)
    /// TEST_ID: JC-002
    /// Tests input control with authentication.
    func testAuthenticatedInputControl() throws {
        let authenticator = MockSessionAuthenticator()
        let inputController = MockInputController()
        
        // Create session
        let token = authenticator.createTestSession()
        
        // Simulate command - validate session first
        guard authenticator.validateSessionToken(token) else {
            XCTFail("Session should be valid")
            return
        }
        
        // Execute input commands
        inputController.moveMouse(deltaX: 100, deltaY: 50)
        inputController.mouseDown(button: 0)
        inputController.mouseUp(button: 0)
        inputController.typeText("Test")
        
        // Verify all commands executed
        XCTAssertEqual(inputController.eventCount, 4)
        XCTAssertEqual(inputController.currentMouseX, 100)
        XCTAssertEqual(inputController.typedText, "Test")
    }
    #endif
}
