import XCTest
@testable import LightStarCore

/// Security tests for the remote control system.
/// These tests verify security requirements. Some are EXPECTED TO FAIL
/// against the current implementation due to known security weaknesses.
///
/// EXECUTION_CATEGORY: MAC_REQUIRED (needs Swift runtime)
final class SecurityTests: XCTestCase {
    
    // MARK: - Authentication Tests
    
    /// TEST_ID: S001
    /// Tests that the mock authenticator rejects invalid pairing codes.
    /// This test demonstrates CORRECT behavior that the real implementation should have.
    func testInvalidPairingCodeRejected() {
        let auth = MockSessionAuthenticator()
        let validCode = auth.generatePairingCode()
        
        // Try invalid code
        let token = auth.validatePairingCode("0000", clientID: "client1")
        XCTAssertNil(token, "Invalid pairing code should be rejected")
        
        // Valid code should still work
        let validToken = auth.validatePairingCode(validCode, clientID: "client1")
        XCTAssertNotNil(validToken, "Valid pairing code should be accepted")
    }
    
    /// TEST_ID: S002
    /// Tests rate limiting after multiple failed attempts.
    /// This demonstrates CORRECT behavior for the real implementation.
    func testRateLimitingAfterFailedAttempts() {
        let auth = MockSessionAuthenticator()
        auth.maxFailedAttempts = 3
        let _ = auth.generatePairingCode()
        
        // Exhaust attempts
        for i in 0..<3 {
            let token = auth.validatePairingCode("wrong\(i)", clientID: "attacker")
            XCTAssertNil(token)
        }
        
        // Should now be rate limited
        XCTAssertTrue(auth.isRateLimited(clientID: "attacker"))
        
        // Even correct code should fail during rate limit
        let correctCode = auth.generatePairingCode()
        let token = auth.validatePairingCode(correctCode, clientID: "attacker")
        XCTAssertNil(token, "Rate-limited client should be rejected")
    }
    
    /// TEST_ID: S003
    /// Tests pairing code expiration.
    func testPairingCodeExpiration() {
        let auth = MockSessionAuthenticator()
        auth.codeValidityDuration = 0.1 // 100ms
        let code = auth.generatePairingCode()
        
        // Wait for expiration
        Thread.sleep(forTimeInterval: 0.2)
        
        let token = auth.validatePairingCode(code, clientID: "client1")
        XCTAssertNil(token, "Expired pairing code should be rejected")
    }
    
    /// TEST_ID: S004
    /// Tests session token validation.
    func testSessionTokenValidation() {
        let auth = MockSessionAuthenticator()
        
        // Create valid session
        let validToken = auth.createTestSession()
        XCTAssertTrue(auth.validateSessionToken(validToken))
        
        // Invalid token should fail
        XCTAssertFalse(auth.validateSessionToken("invalid-token"))
        XCTAssertFalse(auth.validateSessionToken(""))
    }
    
    /// TEST_ID: S005
    /// Tests session invalidation.
    func testSessionInvalidation() {
        let auth = MockSessionAuthenticator()
        let token = auth.createTestSession()
        
        XCTAssertTrue(auth.validateSessionToken(token))
        auth.invalidateSession(token)
        XCTAssertFalse(auth.validateSessionToken(token))
    }
    
    /// TEST_ID: S006
    /// Tests that different clients have separate rate limiting.
    func testSeparateRateLimitingPerClient() {
        let auth = MockSessionAuthenticator()
        auth.maxFailedAttempts = 2
        let _ = auth.generatePairingCode()
        
        // Client A exhausts attempts
        for _ in 0..<2 {
            _ = auth.validatePairingCode("wrong", clientID: "clientA")
        }
        
        // Client A should be rate limited
        XCTAssertTrue(auth.isRateLimited(clientID: "clientA"))
        
        // Client B should NOT be rate limited
        XCTAssertFalse(auth.isRateLimited(clientID: "clientB"))
    }
    
    // MARK: - Protocol Security Tests
    
    /// TEST_ID: S007
    /// Tests that message timestamps are present (for replay detection).
    func testMessageTimestampsPresent() throws {
        let message = RemoteMessage(type: .ping)
        XCTAssertGreaterThan(message.timestamp, 0)
        
        // Timestamp should be recent
        let now = Date().timeIntervalSince1970
        XCTAssertLessThan(abs(message.timestamp - now), 1.0, "Timestamp should be current")
    }
    
    /// TEST_ID: S008
    /// Tests oversized message handling.
    /// The protocol must reject frames larger than 1 MB to prevent memory exhaustion.
    func testOversizedMessageHandling() throws {
        // Build a frame with length field claiming 2 MB (> the 1 MB protocol limit)
        let oversizeLength = UInt32(2_000_000)
        var lengthBE = oversizeLength.bigEndian
        var frame = Data(bytes: &lengthBE, count: 4)
        // Pad just enough bytes so the decoder has the full declared length
        frame.append(Data(repeating: 0x41, count: Int(oversizeLength)))

        XCTAssertThrowsError(try decodeMessage(from: frame)) { error in
            if let protoError = error as? RemoteProtocolError {
                XCTAssertEqual(protoError, .invalidLength,
                               "Oversized frame must be rejected with invalidLength")
            }
        }
    }
    
    /// TEST_ID: S009
    /// Tests that pairing codes are not predictable.
    func testPairingCodeRandomness() {
        let auth = MockSessionAuthenticator()
        var codes = Set<String>()
        
        for _ in 0..<100 {
            let code = auth.generatePairingCode()
            codes.insert(code)
        }
        
        // Should have high uniqueness (collisions very unlikely)
        XCTAssertGreaterThan(codes.count, 95, "Pairing codes should be random")
    }
    
    /// TEST_ID: S010
    /// Tests that session tokens are not predictable.
    func testSessionTokenRandomness() {
        let auth = MockSessionAuthenticator()
        var tokens = Set<String>()
        
        for _ in 0..<100 {
            let token = auth.createTestSession()
            tokens.insert(token)
        }
        
        // All tokens should be unique
        XCTAssertEqual(tokens.count, 100, "Session tokens must be unique")
    }
    
    // MARK: - Input Validation Tests
    
    /// TEST_ID: S011
    /// Tests that extreme mouse delta values are sanitised by encodePointerFrame.
    /// Non-finite inputs must be clamped to 0; finite overflow must be clamped to ±32767/10.
    func testExtremeMouseDeltas() throws {
        let clampMax = Double(Int16.max) / 10.0   // 3276.7

        let cases: [(dx: Double, dy: Double, expectFinite: Bool)] = [
            (.greatestFiniteMagnitude, 0,    true),
            (0, .greatestFiniteMagnitude,    true),
            (-.greatestFiniteMagnitude, 0,   true),
            (.nan,      0,                   true),  // NaN → 0
            (.infinity, 0,                   true),  // Infinity → clamped
        ]

        for (dx, dy, expectFinite) in cases {
            let frame = encodePointerFrame(deltaX: dx, deltaY: dy, isScroll: false)
            XCTAssertEqual(frame.count, kPointerFrameLength,
                           "Frame must be exactly \(kPointerFrameLength) bytes")
            if expectFinite {
                let decoded = try XCTUnwrap(try decodePointerFrame(from: frame))
                XCTAssertTrue(decoded.deltaX.isFinite && decoded.deltaY.isFinite,
                              "Decoded deltas must be finite, got (\(decoded.deltaX), \(decoded.deltaY))")
                XCTAssertLessThanOrEqual(abs(decoded.deltaX), clampMax)
                XCTAssertLessThanOrEqual(abs(decoded.deltaY), clampMax)
            }
        }
    }
    
    /// TEST_ID: S012
    /// Tests that non-UTF-8 bytes in a text-input payload are rejected by the decoder.
    func testMalformedTextInput() throws {
        // Raw bytes that are not valid UTF-8 and not valid JSON — must not decode.
        let invalidUTF8 = Data([0xFF, 0xFE, 0x00, 0x01])
        XCTAssertThrowsError(try JSONDecoder().decode(TextInputMessage.self, from: invalidUTF8),
                             "Malformed UTF-8 payload must not produce a TextInputMessage")

        // Valid JSON but with an embedded NUL — should decode to a string (JSON spec allows it).
        let nullEmbedded = #"{"text":"\u0000\u0001\u0002"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(TextInputMessage.self, from: nullEmbedded)
        XCTAssertEqual(msg.text.unicodeScalars.first?.value, 0,
                       "Control characters in text must be preserved as decoded, not stripped")
    }
    
    // MARK: - Mock Lighting Controller Security Tests
    
    /// TEST_ID: S013
    /// Tests that mock lighting controller bounds-checks values.
    func testLightingControllerBoundsChecking() {
        let controller = MockLightingController()
        
        // Set out-of-bounds brightness
        controller.setBrightness(2.0)
        XCTAssertEqual(controller.brightness, 1.0, "Brightness should be clamped to max")
        
        controller.setBrightness(-0.5)
        XCTAssertEqual(controller.brightness, 0.0, "Brightness should be clamped to min")
        
        // Set out-of-bounds color
        controller.setColor(hue: 1.5, saturation: -0.1)
        XCTAssertEqual(controller.hue, 1.0, "Hue should be clamped to max")
        XCTAssertEqual(controller.saturation, 0.0, "Saturation should be clamped to min")
    }
    
    // MARK: - Connection Security Tests
    
    /// TEST_ID: S014
    /// Tests multiple active sessions are tracked separately.
    func testMultipleActiveSessions() {
        let auth = MockSessionAuthenticator()
        
        let token1 = auth.createTestSession()
        let token2 = auth.createTestSession()
        let token3 = auth.createTestSession()
        
        XCTAssertEqual(auth.activeSessionCount, 3)
        
        auth.invalidateSession(token1)
        XCTAssertEqual(auth.activeSessionCount, 2)
        XCTAssertFalse(auth.validateSessionToken(token1))
        XCTAssertTrue(auth.validateSessionToken(token2))
        XCTAssertTrue(auth.validateSessionToken(token3))
    }
    
    /// TEST_ID: S015
    /// Tests that failed attempt count is tracked correctly.
    func testFailedAttemptTracking() {
        let auth = MockSessionAuthenticator()
        let _ = auth.generatePairingCode()
        
        XCTAssertEqual(auth.failedAttemptCount(for: "testClient"), 0)
        
        _ = auth.validatePairingCode("wrong1", clientID: "testClient")
        XCTAssertEqual(auth.failedAttemptCount(for: "testClient"), 1)
        
        _ = auth.validatePairingCode("wrong2", clientID: "testClient")
        XCTAssertEqual(auth.failedAttemptCount(for: "testClient"), 2)
        
        // Different client should have zero failures
        XCTAssertEqual(auth.failedAttemptCount(for: "otherClient"), 0)
    }
}

// MARK: - Documentation: Known Security Weaknesses

/*
 KNOWN SECURITY ISSUES IN CURRENT IMPLEMENTATION
 (As documented in security-remediation-plan.md)
 
 1. Fake Pairing Authentication (CRITICAL)
    - Server accepts ANY 4-digit code
    - No verification against displayed code
    - Tests S001-S003 document expected behavior
 
 2. No TLS/Transport Encryption (CRITICAL)
    - All messages sent in plaintext
    - Session tokens visible on network
    - No certificate validation
 
 3. No Rate Limiting (HIGH)
    - Unlimited pairing attempts allowed
    - No connection throttling
    - Tests S002, S006 document expected behavior
 
 4. No Replay Protection (MEDIUM)
    - Message timestamps not validated
    - No sequence numbers
    - Test S007 documents expected behavior
 
 5. No Message Size Limits (MEDIUM)
    - Large messages could exhaust memory
    - Test S008 documents expected behavior
 
 6. Input Injection Without Validation (HIGH)
    - Keyboard/mouse input not sanitized
    - Could execute arbitrary key sequences
*/
