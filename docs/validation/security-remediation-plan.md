# LightStar Security Remediation Plan

> Generated: September 2026  
> **Revalidated: 2026-09-21**  
> Status: PARTIALLY SUPERSEDED — fake pairing (item 1) is **implemented** in production  
> Verification: Pairing/lockout unit tests exist; Mac hardware not run on Linux agents

---

## Issue Ranking by Severity

| Rank | Issue | Severity | CVSS-like | Current State (2026-09-21) | Fix Complexity |
|------|-------|----------|-----------|----------------------------|----------------|
| 1 | Fake pairing (any 4-digit code accepted) | — | — | **FIXED** — exact `activePairingCode` match, PD-002 6-char alphabet, expiry + lockouts | Done |
| 2 | No transport encryption | HIGH | 8.5 | Still plaintext TCP; **PD-001** forbids TLS-by-default without ADR | Medium |
| 3 | No authentication after pairing | MEDIUM | 6.0 | In-memory `authenticated`; `sessionToken` unused on later frames | Low |
| 4 | No rate limiting | LOW | 3.0 | **Partial** — pairing lockouts present | Done/monitor |
| 5 | No replay protection | MEDIUM | 6.5 | No timestamps validated | Medium |
| 6 | No input validation | MEDIUM | 5.5 | Bounded in places; not exhaustive | Low |
| 7 | No message size limits | LOW | 3.0 | Payload / receive buffer caps exist | Mostly done |
| 8 | Remote input without confirmation | MEDIUM | 5.0 | Immediate upon authenticated connect | Medium |
| 9 | No secure credential storage | LOW | 4.0 | Not implemented | Medium |
| 10 | Bonjour service exposure | LOW | 3.5 | Always advertised when remote on | Low |
| 11 | No session expiration | LOW | 3.0 | In-memory until disconnect | Low |

---

## Remediation 1: Real Pairing — COMPLETE

### Current State

Production compares against `activePairingCode` (6-char PD-002 alphabet) with lockouts. The historical accept-any snippet is **removed**:

```swift
// REMOVED — obsolete; do not restore
if pair.pairingCode.count == 4, pair.pairingCode.allSatisfy({ $0.isNumber }) {
    connection.authenticated = true
```

**Historical problem**: Accepted ANY 4-digit numeric code without verification. **No longer true.**

### Required Implementation

```swift
// Server side
@MainActor
public final class RemoteControlServer {
    @Published public private(set) var currentPairingCode: String?
    @Published public private(set) var pairingCodeExpiry: Date?
    
    private var failedAttempts: [String: (count: Int, lockoutUntil: Date?)] = [:]
    
    /// Generate a new pairing code and display it to the user
    public func generatePairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        currentPairingCode = code
        pairingCodeExpiry = Date().addingTimeInterval(120) // 2 minutes
        
        // Auto-clear after expiry
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if currentPairingCode == code {
                currentPairingCode = nil
                pairingCodeExpiry = nil
            }
        }
        return code
    }
    
    private func handlePair(_ message: RemoteMessage, connection: ClientConnection) {
        guard let pair = try? message.decode(PairMessage.self) else {
            sendPairError(connection, "Invalid message format")
            return
        }
        
        // Rate limiting check
        let clientIP = connection.remoteAddress
        if let lockout = failedAttempts[clientIP]?.lockoutUntil, lockout > Date() {
            sendPairError(connection, "Too many attempts. Try again later.")
            return
        }
        
        // Verify code matches AND hasn't expired
        guard let expectedCode = currentPairingCode,
              let expiry = pairingCodeExpiry,
              Date() < expiry,
              pair.pairingCode == expectedCode else {
            recordFailedAttempt(clientIP)
            sendPairError(connection, "Invalid or expired pairing code")
            return
        }
        
        // Success - clear code, authenticate
        currentPairingCode = nil
        pairingCodeExpiry = nil
        failedAttempts[clientIP] = nil
        connection.authenticated = true
        // ... send success
    }
    
    private func recordFailedAttempt(_ clientIP: String) {
        var record = failedAttempts[clientIP] ?? (count: 0, lockoutUntil: nil)
        record.count += 1
        if record.count >= 3 {
            record.lockoutUntil = Date().addingTimeInterval(60) // 1 minute lockout
        }
        failedAttempts[clientIP] = record
    }
}
```

### UI Requirement

Mac app must display the pairing code prominently when pairing is requested.

### Testing Required

- [ ] Generate code appears on Mac
- [ ] Correct code succeeds
- [ ] Incorrect code fails
- [ ] Expired code fails
- [ ] Rate limiting activates after 3 failures

---

## Remediation 2: Encrypted Transport (TLS)

### Current State

```swift
let params = NWParameters.tcp  // Plaintext
listener = try NWListener(using: params, on: port)
```

### Required Implementation

```swift
// Server side
private func createTLSListener(port: UInt16) throws -> NWListener {
    let tlsOptions = NWProtocolTLS.Options()
    
    // Generate or load self-signed certificate
    let identity = try getOrCreateIdentity()
    sec_protocol_options_set_local_identity(
        tlsOptions.securityProtocolOptions,
        identity
    )
    
    // Require TLS 1.2+
    sec_protocol_options_set_min_tls_protocol_version(
        tlsOptions.securityProtocolOptions,
        .TLSv12
    )
    
    let params = NWParameters(tls: tlsOptions)
    params.allowLocalEndpointReuse = true
    
    return try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
}

private func getOrCreateIdentity() throws -> sec_identity_t {
    // Check Keychain for existing identity
    // If not found, generate self-signed certificate
    // Store in Keychain with app-specific tag
    // Return identity
}
```

### Certificate Management

- Generate self-signed certificate on first launch
- Store in Keychain
- Optionally display fingerprint for manual verification
- Consider certificate pinning after first successful pairing

### Testing Required

- [ ] Connection fails without TLS
- [ ] Connection succeeds with TLS
- [ ] Certificate persists across app restarts
- [ ] Wireshark shows encrypted traffic

---

## Remediation 3: Session Token Validation

### Current State

Session token is generated but never validated:

```swift
let ack = PairAckMessage(success: true, sessionToken: UUID().uuidString)
// Token is sent but never checked on subsequent messages
```

### Required Implementation

```swift
private var validSessionTokens: [String: SessionInfo] = [:]

struct SessionInfo {
    let token: String
    let deviceID: String
    let createdAt: Date
    let lastUsedAt: Date
}

private func validateSession(_ connection: ClientConnection) -> Bool {
    guard let token = connection.sessionToken,
          let session = validSessionTokens[token],
          session.lastUsedAt.addingTimeInterval(3600) > Date() else {
        return false
    }
    validSessionTokens[token]?.lastUsedAt = Date()
    return true
}

// Check on every command
private func handleMessage(_ message: RemoteMessage, from clientID: String) {
    guard let connection = connections[clientID],
          validateSession(connection) else {
        sendError(connection, "Session invalid or expired")
        connection.close()
        return
    }
    // ... process message
}
```

### Testing Required

- [ ] Valid token allows commands
- [ ] Invalid token rejects commands
- [ ] Expired token rejects commands
- [ ] Token refresh works

---

## Remediation 4: Rate Limiting

### Required Implementation

```swift
private var messageRates: [String: (count: Int, windowStart: Date)] = [:]
private let maxMessagesPerSecond = 100

private func checkRateLimit(_ clientID: String) -> Bool {
    let now = Date()
    var record = messageRates[clientID] ?? (count: 0, windowStart: now)
    
    // Reset window if older than 1 second
    if now.timeIntervalSince(record.windowStart) > 1.0 {
        record = (count: 1, windowStart: now)
    } else {
        record.count += 1
    }
    
    messageRates[clientID] = record
    return record.count <= maxMessagesPerSecond
}
```

### Testing Required

- [ ] Normal usage succeeds
- [ ] 100+ msg/sec triggers limit
- [ ] Rate limit resets after 1 second

---

## Remediation 5: Replay Protection

### Required Implementation

```swift
// Add to RemoteMessage
public struct RemoteMessage: Codable, Sendable {
    let type: RemoteMessageType
    let payload: Data
    let timestamp: TimeInterval
    let nonce: String  // Add unique nonce
    
    public init(type: RemoteMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
        self.timestamp = Date().timeIntervalSince1970
        self.nonce = UUID().uuidString
    }
}

// Server validation
private var seenNonces: Set<String> = []
private let maxNonceAge: TimeInterval = 30 // 30 seconds

private func validateTimestampAndNonce(_ message: RemoteMessage) -> Bool {
    let now = Date().timeIntervalSince1970
    
    // Check timestamp is recent (within 30 seconds)
    guard abs(now - message.timestamp) < maxNonceAge else {
        return false
    }
    
    // Check nonce hasn't been seen
    guard !seenNonces.contains(message.nonce) else {
        return false
    }
    
    seenNonces.insert(message.nonce)
    
    // Prune old nonces periodically
    // (implementation detail)
    
    return true
}
```

### Testing Required

- [ ] Fresh message succeeds
- [ ] Old timestamp rejected
- [ ] Replayed nonce rejected

---

## Remediation 6: Input Validation

### Required Implementation

```swift
extension SetBrightnessMessage {
    var isValid: Bool {
        brightness >= 0 && brightness <= 1
    }
}

extension SetColorMessage {
    var isValid: Bool {
        hue >= 0 && hue <= 1 && saturation >= 0 && saturation <= 1
    }
}

extension MouseMoveMessage {
    var isValid: Bool {
        abs(deltaX) < 10000 && abs(deltaY) < 10000
    }
}

// Validate before processing
private func handleLightCommand(_ message: RemoteMessage) {
    switch message.type {
    case .setBrightness:
        guard let cmd = try? message.decode(SetBrightnessMessage.self),
              cmd.isValid else {
            sendError("Invalid brightness value")
            return
        }
        // Process valid command
    // ... other cases
    }
}
```

### Testing Required

- [ ] Valid values accepted
- [ ] Out-of-range values rejected
- [ ] Extreme values don't crash

---

## Remediation 7: Message Size Limits

### Required Implementation

```swift
private let maxMessageSize = 65536 // 64KB

private func processBuffer() {
    while receiveBuffer.count >= 4 {
        let length = receiveBuffer.withUnsafeBytes { 
            $0.load(as: UInt32.self).bigEndian 
        }
        
        // Reject oversized messages
        guard length <= maxMessageSize else {
            disconnect(reason: "Message too large")
            return
        }
        
        // ... continue processing
    }
}
```

### Testing Required

- [ ] Normal messages accepted
- [ ] >64KB message rejected
- [ ] Connection closed on oversized message

---

## Remediation 8: Remote Input Authorization

### Required Implementation

Add user confirmation before enabling input control:

```swift
public enum RemoteCapability: String, CaseIterable {
    case lightControl
    case mouseControl
    case keyboardControl
    case mediaKeys
}

@Published public var enabledCapabilities: Set<RemoteCapability> = [.lightControl]

// Require explicit opt-in for input control
public func enableInputControl() {
    // Show confirmation dialog
    let alert = NSAlert()
    alert.messageText = "Enable Remote Input?"
    alert.informativeText = "This will allow the connected iPhone to control your cursor and keyboard."
    alert.addButton(withTitle: "Enable")
    alert.addButton(withTitle: "Cancel")
    
    if alert.runModal() == .alertFirstButtonReturn {
        enabledCapabilities.insert(.mouseControl)
        enabledCapabilities.insert(.keyboardControl)
    }
}

// Check capability before processing
private func handleInputCommand(_ message: RemoteMessage) {
    guard enabledCapabilities.contains(.mouseControl) else {
        sendError("Mouse control not enabled")
        return
    }
    // ... process
}
```

### Testing Required

- [ ] Light control works by default
- [ ] Input control blocked until enabled
- [ ] User sees confirmation dialog
- [ ] Disabling revokes access

---

## Implementation Priority

### Phase 1: Critical (Before Any External Use)

1. Real pairing with displayed code — **DONE** (code); confirm Mac UI shows code when pairing enabled
2. TLS transport encryption — **blocked on PD-001** until ADR
3. Session token validation — still open (low urgency while LAN-trusted)

### Phase 2: High (Before Public Release)

4. Rate limiting — **partially done** (pairing lockouts)
5. Input validation
6. Message size limits — **mostly done** (`kLightStarMaxMessagePayloadBytes`)

### Phase 3: Medium (Before v1.0)

7. Replay protection
8. Remote input authorization
9. Credential storage

### Phase 4: Low (Ongoing)

10. Bonjour service controls
11. Session expiration

---

## Verification Status

**ALL REMEDIATIONS ARE UNIMPLEMENTED.**

This document describes PLANNED changes. No code was modified. All implementations require:

1. Code changes on Mac
2. Compilation and testing
3. Manual security verification
4. Penetration testing before production use
