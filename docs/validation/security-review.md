# LightStar Security Review

> Generated: September 2026
> Environment: Cloud Agent (code inspection only)
> Status: SECURITY AUDIT — Findings require attention before production use

---

## Executive Summary

**Risk Level: HIGH**

The remote control system has significant security vulnerabilities that could allow any device on the local network to:
- Control the Mac's cursor and keyboard
- Access lighting controls
- Potentially disrupt user activity

These issues must be addressed before recommending the remote control feature for general use.

---

## 1. Unauthenticated LAN Access

### Vulnerability

**Location**: `RemoteControlServer.swift`

Any device that can reach the TCP port can:
1. Connect to the server
2. Send commands
3. If pairing is disabled, immediately control the Mac

### Risk Assessment

| Factor | Assessment |
|--------|------------|
| Attack Vector | Local network (LAN) |
| Attack Complexity | Low — just send TCP packets |
| Privileges Required | None — any LAN device |
| User Interaction | None — passive victim |
| Impact | High — full input control |

**CVSS-like Score**: 8.8 (High)

### Evidence

```swift
// RemoteControlServer.swift:177-179
connection.authenticated = !requirePairing

// If requirePairing is false (which is the default), any connection is authenticated
```

### Mitigation Required

1. **Change default**: `requirePairing` should default to `true`
2. **Add TLS**: Encrypt transport with NWProtocolTLS
3. **Verify pairing**: Display code on Mac, require exact match

---

## 2. Fake Pairing Implementation

### Vulnerability

**Location**: `RemoteControlServer.swift:205-219`

```swift
// Simple pairing: accept any 4-digit code for now
if pair.pairingCode.count == 4, pair.pairingCode.allSatisfy({ $0.isNumber }) {
    connection.authenticated = true
```

The server accepts ANY 4-digit numeric code. There is no:
- Actual code generation
- Code verification against a displayed value
- Rate limiting

### Risk Assessment

| Factor | Assessment |
|--------|------------|
| Brute Force Space | 10,000 codes (0000-9999) |
| Time to Enumerate | ~10 seconds with parallel connections |
| Rate Limiting | None |
| User Notification | None during brute force |

### Mitigation Required

1. **Real pairing flow**:
   ```swift
   // Server generates code
   let pairingCode = String(format: "%04d", Int.random(in: 0..<10000))
   // Display to user
   showPairingCode(pairingCode)
   // Verify incoming code matches exactly
   if incomingCode == expectedPairingCode { ... }
   ```

2. **Rate limiting**: Block IP after 3 failed attempts for 60 seconds

3. **User notification**: Show "Pairing attempt from [device]" dialog

---

## 3. Plaintext Transport

### Vulnerability

**Location**: `RemoteControlServer.swift`, `RemoteControlClient.swift`

All communication is unencrypted TCP:
- Commands sent in plain JSON
- Session tokens visible on network
- Input events (keystrokes!) readable

### Risk Assessment

| Attack | Feasibility | Impact |
|--------|-------------|--------|
| Passive sniffing | Easy (Wireshark) | Read all commands |
| Keystroke capture | Easy | Passwords, sensitive data |
| Session hijacking | Moderate | Take over connection |
| MITM | Moderate | Inject commands |

### Mitigation Required

Implement TLS transport:

```swift
let tlsOptions = NWProtocolTLS.Options()
sec_protocol_options_set_min_tls_protocol_version(
    tlsOptions.securityProtocolOptions,
    .TLSv12
)
let params = NWParameters(tls: tlsOptions)
```

For local network, consider:
- Self-signed certificates (generated at first launch)
- Certificate pinning (store iPhone's cert on Mac after pairing)
- Pre-shared key authentication

---

## 4. Remote Keyboard Injection

### Vulnerability

**Location**: `MacInputController.swift`

Remote keyboard control is equivalent to physical keyboard access:
- Can type any text
- Can press any key combination (including Cmd+Space, Cmd+Tab)
- Can interact with password dialogs
- Can execute Terminal commands if Terminal is open

### Risk Assessment

| Scenario | Risk |
|----------|------|
| Unauthorized access | Malicious actor can control Mac |
| Password entry | Remote keylogger equivalent |
| System dialogs | Can dismiss security prompts |
| Terminal access | Command execution |

### Mitigation Required

1. **Require Accessibility dialog**: Already implemented, but user may grant without understanding implications
2. **Input activity indicator**: Show visual feedback when remote input is occurring
3. **Emergency disconnect**: Physical keyboard shortcut to kill all remote sessions
4. **Scope limitation**: Consider allowing only media keys by default, require explicit enable for full keyboard

---

## 5. Remote Mouse Injection

### Vulnerability

**Location**: `MacInputController.swift`

Remote mouse control can:
- Click on any screen element
- Bypass click-to-focus restrictions
- Interact with System Preferences
- Approve permission dialogs

### Risk Assessment

Similar to keyboard injection. Combined with keyboard, provides complete UI control.

### Mitigation Required

1. **Overlay indicator**: Show cursor trail or badge when remote cursor is active
2. **Screen region restriction**: Option to limit mouse to certain apps/areas
3. **Lockdown mode**: Emergency hotkey to disable remote input

---

## 6. Session Token Issues

### Vulnerability

**Location**: `RemoteControlServer.swift:207`

```swift
let ack = PairAckMessage(success: true, sessionToken: UUID().uuidString)
```

Session tokens are:
- Generated but not validated
- Transmitted in plaintext
- Not stored or checked on subsequent messages
- Never expire

### Risk Assessment

The token is generated but appears to have no actual function — the `authenticated` flag is set directly, not verified against the token.

### Mitigation Required

1. **Store and verify tokens**: Actually check the token on each message
2. **Keychain storage**: Persist paired device tokens
3. **Token expiration**: Tokens should expire (configurable, e.g., 30 days)
4. **Token revocation**: UI to unpair/revoke specific devices

---

## 7. Bonjour Spoofing

### Vulnerability

Any device can advertise a `_lightstar._tcp` service. iPhone could connect to malicious server.

### Risk Assessment

| Attack | Impact |
|--------|--------|
| Impersonate Mac | iPhone sends commands to attacker |
| Credential capture | If iPhone sends stored credentials |
| Phishing | Display fake pairing UI |

### Mitigation Required

1. **Verify Mac identity**: After pairing, iPhone should verify Mac's identity (certificate or device identifier)
2. **Warn on new servers**: "This is a new LightStar server. Verify it's your Mac before pairing."

---

## 8. Denial of Service

### Vulnerability

No connection limits or rate limiting:
- Can open unlimited connections
- Can flood with commands
- Can exhaust memory with large messages

### Evidence

```swift
// No limit on connections
private var connections: [String: ClientConnection] = [:]
```

### Mitigation Required

1. **Connection limit**: Max 5 concurrent connections
2. **Rate limiting**: Max 100 messages/second per connection
3. **Message size limit**: Already using length-prefixed framing, add max (e.g., 64KB)
4. **Timeout**: Disconnect idle connections after 5 minutes

---

## 9. Credential Storage

### Finding

Session tokens and pairing data are not persisted. This is actually a security positive — no credentials to steal from disk.

However:
- User must re-pair after every Mac restart
- No "remember this device" functionality

### Recommendation

If persistence is added:
- Use Keychain Services
- Store minimal data (device UUID, encrypted token)
- Require user confirmation to store

---

## 10. Permission Model Issues

### Finding

The Mac app requires:
- Screen Recording (for capture)
- Accessibility (for input)
- Bluetooth (for LED strip)
- Local Network (for iPhone communication)

All permissions are granted to the entire app. Once granted, remote clients inherit all capabilities.

### Risk

Granting Accessibility permission to enable trackpad also enables remote keyboard. Users may not understand this.

### Recommendation

1. **Separate features**: Consider separate processes or XPC services
2. **Clear UI**: Explain what each permission enables for remote control
3. **Granular enable**: Let users enable/disable input types separately

---

## Security Review Summary

| Issue | Severity | Status | Fix Priority |
|-------|----------|--------|--------------|
| Fake pairing | CRITICAL | ❌ Vulnerable | P0 |
| Plaintext transport | HIGH | ❌ Vulnerable | P0 |
| Unauthenticated access | HIGH | ⚠️ Configurable | P1 |
| Remote keyboard injection | HIGH | ⚠️ By design | P1 |
| Remote mouse injection | MEDIUM | ⚠️ By design | P2 |
| No rate limiting | MEDIUM | ❌ Missing | P2 |
| Bonjour spoofing | LOW | ⚠️ Partial | P3 |
| Session token unused | LOW | ⚠️ Dead code | P3 |

---

## Recommended Security Architecture

### Phase 1: Immediate Fixes

```swift
// 1. Default pairing on
@Published public var requirePairing: Bool = true  // Changed from false

// 2. Real pairing flow
private var currentPairingCode: String?

func generatePairingCode() -> String {
    let code = String(format: "%06d", Int.random(in: 0..<1000000))
    currentPairingCode = code
    // Clear after 2 minutes
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        if self.currentPairingCode == code {
            self.currentPairingCode = nil
        }
    }
    return code
}

// 3. Verify pairing
private func handlePair(_ message: RemoteMessage, connection: ClientConnection) {
    guard let pair = try? message.decode(PairMessage.self),
          let expectedCode = currentPairingCode,
          pair.pairingCode == expectedCode else {
        failedPairingAttempts += 1
        // Rate limiting...
        return
    }
    // Success
}
```

### Phase 2: Transport Security

```swift
// TLS transport
let tlsOptions = NWProtocolTLS.Options()
// Configure with self-signed cert
let params = NWParameters(tls: tlsOptions)
listener = try NWListener(using: params, on: port)
```

### Phase 3: Production Hardening

- Connection limits
- Rate limiting
- Activity logging
- Emergency disconnect hotkey
- Granular permission UI

---

## Compliance Considerations

### GDPR/Privacy

- No personal data transmitted to external servers ✅
- Input events stay on local network ✅
- Consider adding privacy policy for remote control feature

### App Store Guidelines

Current implementation may face review issues:
- Remote control features require clear user consent
- Must explain why Accessibility permission is needed
- Cannot enable features that could harm user

---

## Conclusion

The remote control feature has a **functional implementation** but **significant security gaps**. It should NOT be used on untrusted networks or promoted as a feature until:

1. ✅ Real pairing is implemented
2. ✅ TLS encryption is added
3. ✅ Rate limiting is added
4. ✅ User is clearly warned about what remote control enables

For personal use on a trusted home network with pairing enabled, the risk is moderate. For any broader deployment, the fixes are mandatory.
