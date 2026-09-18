# LightStar Architecture Test Map

> Generated: September 2026
> Status: DOCUMENTATION — Component mapping verified via source inspection
> Execution: NOT_EXECUTED — No Swift runtime available

---

## Project Structure

### Targets Identified

| Target | Platform | Type | Path |
|--------|----------|------|------|
| LightStar | macOS | Application | `LightStar/` |
| LightStariOS | iOS | Application | `LightStariOS/` |
| LightStarCore | macOS/iOS | Swift Package | `LightStarCore/` |
| LightStarWidget | macOS | App Extension | `LightStarWidget/` |
| LightStariOSWidget | iOS | App Extension | (shares LightStarWidget source) |

### Shared Module: LightStarCore

| File | Component | Test Level | Hardware Required |
|------|-----------|------------|-------------------|
| `RemoteProtocol.swift` | Message types, framing | Unit | None |
| `RemoteControlServer.swift` | TCP server, Bonjour | Integration | Mac network |
| `RemoteControlClient.swift` | TCP client, discovery | Integration | iPhone network |
| `LightBLEManager.swift` | BLE communication | E2E | BLE hardware |
| `LightBLEManager+Remote.swift` | Remote command handling | Integration | Mock BLE |
| `BLEProtocol.swift` | BLE command encoding | Unit | None |
| `BLEWriteCoalescer.swift` | Write deduplication | Unit | None |
| `ScreenFrameProvider.swift` | Capture protocol | Unit (protocol) | Mac for impl |
| `ScreenCaptureKitProvider.swift` | SCK implementation | E2E | Mac + permission |
| `ScreenColorSampler.swift` | Frame analysis wrapper | Integration | Mock provider |
| `MetalColorAnalyzer.swift` | GPU histogram | Integration | Mac + Metal |
| `MetalColorAnalyzer.metal` | Compute shaders | Build | Mac + Metal |
| `ColorMath.swift` | Hue/CCT math | Unit | None |
| `MacInputController.swift` | Input injection | E2E | Mac + Accessibility |
| `LightSchedule.swift` | Scheduling logic | Unit | None |
| `LightState.swift` | Preset data | Unit | None |
| `CaptureDiagnostics.swift` | DRM detection | Integration | Mac + video |
| `FrequencyBands.swift` | Audio analysis | Unit | None |

---

## Component → Test Level Mapping

### Level 1: Unit Tests (CLOUD_EXECUTABLE if Swift available)

| Component | Testable Without Hardware | Protocol/Abstraction Exists |
|-----------|--------------------------|----------------------------|
| RemoteProtocol | ✅ Yes | N/A (data types) |
| BLEProtocol (Cmd) | ✅ Yes | N/A (encoding) |
| BLEWriteCoalescer | ✅ Yes | ✅ Uses callbacks |
| ColorMath | ✅ Yes | N/A (pure functions) |
| LightSchedule | ✅ Yes | N/A (pure logic) |
| FrameAnalysis | ✅ Yes | N/A (data struct) |
| Message framing | ✅ Yes | N/A (encode/decode) |

### Level 2: Integration Tests (MAC_REQUIRED with mocks)

| Component | Can Mock Dependencies | Abstraction Needed |
|-----------|----------------------|-------------------|
| RemoteControlServer | ⚠️ Partial (needs NWListener) | NetworkTransport protocol |
| RemoteControlClient | ⚠️ Partial (needs NWBrowser) | DiscoveryProvider protocol |
| ScreenColorSampler | ✅ Yes | ScreenFrameProvider exists |
| LightBLEManager commands | ⚠️ Partial | LightingController protocol |
| RemoteControlCoordinator | ✅ Yes | Uses existing abstractions |
| CaptureDiagnostics | ✅ Yes | Uses FrameAnalysis |

### Level 3: E2E Tests (HARDWARE_REQUIRED)

| Component | Hardware Required | Can Simulate |
|-----------|------------------|--------------|
| BLE strip communication | LED strip | ❌ No |
| Screen capture | Mac display | ❌ No |
| Metal GPU analysis | Metal GPU | ❌ No |
| Mac input injection | Mac + Accessibility | ❌ No |
| iPhone trackpad | iPhone | ❌ No |
| Bonjour discovery | Network | ⚠️ Loopback only |

---

## Existing Abstractions

### ScreenFrameProvider Protocol (EXISTS)

```swift
@MainActor
public protocol ScreenFrameProvider: AnyObject {
    var onFrame: ((FrameAnalysis) -> Void)? { get set }
    var selectedDisplayID: CGDirectDisplayID? { get set }
    var isRunning: Bool { get }
    func start() async throws
    func stop() async
    static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)]
}
```

**Status**: Protocol exists, can create test double.

### Missing Abstractions Needed

| Abstraction | Purpose | Current Implementation |
|-------------|---------|----------------------|
| `LightingController` | BLE command abstraction | Direct `LightBLEManager` |
| `NetworkTransport` | TCP abstraction | Direct `NWConnection` |
| `DiscoveryProvider` | Bonjour abstraction | Direct `NWBrowser` |
| `InputController` | Input injection abstraction | Direct `MacInputController` |
| `SessionAuthenticator` | Auth logic abstraction | Inline in server |

---

## Test Infrastructure Status

### Existing Tests (CoreTests.swift)

| Test Class | Coverage | Abstraction Used |
|------------|----------|------------------|
| BLEProtocolTests | Cmd framing | None needed |
| ColorMathTests | Hue LUT, CCT | None needed |
| LightScheduleTests | Schedule logic | None needed |
| BLEWriteCoalescerTests | Coalescing | Callbacks |
| ScheduleStorePendingTests | Queue logic | None needed |
| PresetMigrationTests | JSON decode | None needed |
| RemoteProtocolTests | Message round-trip | None needed |

### Missing Test Infrastructure

| Need | Purpose | Priority |
|------|---------|----------|
| MockScreenFrameProvider | Test color analysis | HIGH |
| MockLightingController | Test BLE commands | HIGH |
| MockNetworkTransport | Test protocol handling | MEDIUM |
| MockInputController | Test input commands | MEDIUM |
| Test fixtures (frames) | Deterministic color tests | HIGH |
| Protocol test helpers | Message construction | MEDIUM |

---

## Network Protocol (RemoteProtocol.swift)

### Message Types Identified

| Category | Types | Testable |
|----------|-------|----------|
| Connection | hello, helloAck, pair, pairAck, ping, pong, disconnect | ✅ Unit |
| State | getState, stateUpdate | ✅ Unit |
| Light Control | setPower, setBrightness, setColor, setColorTemperature, setEffect, setEffectSpeed, setEffectDirection, setSyncMode, selectDisplay | ✅ Unit |
| Input Control | mouseMove, mouseDown, mouseUp, rightClick, scroll, keyDown, keyUp, textInput, mediaKey | ✅ Unit |
| Diagnostics | getDiagnostics, diagnosticsUpdate | ✅ Unit |
| Error | error | ✅ Unit |

### Framing

```
[4 bytes: length (big-endian)] [JSON payload]
```

**Testable**: Yes, pure encoding/decoding.

---

## Bonjour/mDNS Discovery

| Property | Value | Source |
|----------|-------|--------|
| Service Type | `_lightstar._tcp` | RemoteProtocol.swift |
| Domain | `local.` | RemoteControlServer.swift |
| Port | 19384 | RemoteProtocol.swift |

**Testable**: Requires network stack, can mock NWBrowser results.

---

## Pairing and Authentication

### Current Implementation (SECURITY CONCERN)

| Step | Implementation | Issue |
|------|---------------|-------|
| Pairing request | Client sends 4-digit code | No display on Mac |
| Pairing validation | Server accepts any 4-digit code | **FAKE AUTHENTICATION** |
| Session token | Generated but not validated | **UNUSED** |
| Rate limiting | None | **MISSING** |

**Test Strategy**: Security tests MUST fail against current implementation.

---

## State Management

### LightBLEManager State

| State | Type | Observable |
|-------|------|------------|
| connectionState | ConnectionState | ✅ @Observable |
| isOn | Bool | ✅ @Observable |
| brightness | Double | ✅ @Observable |
| color | Color | ✅ @Observable |
| syncMode | SyncMode | ✅ @Observable |
| effectID | UInt8 | ✅ @Observable |

### RemoteControlClient State

| State | Type | Observable |
|-------|------|------------|
| state | ConnectionState | ✅ @Published |
| discoveredServers | [DiscoveredServer] | ✅ @Published |
| currentState | LightStarState? | ✅ @Published |
| requiresPairing | Bool | ✅ @Published |

---

## Reconnection Logic

### Client Reconnection

| Scenario | Current Behavior | Test Needed |
|----------|------------------|-------------|
| Server disconnect | State → disconnected | ✅ |
| Network interruption | No auto-reconnect | ⚠️ Missing feature |
| App backgrounding | Connection maintained | ✅ |
| Server restart | Manual reconnect required | ⚠️ |

### Server Reconnection

| Scenario | Current Behavior | Test Needed |
|----------|------------------|-------------|
| Client disconnect | Connection removed | ✅ |
| Multiple clients | All tracked | ✅ |
| Client reconnect | New session required | ✅ |

---

## Summary

### Components Ready for Unit Testing

1. RemoteProtocol (message types, framing)
2. BLEProtocol (command encoding)
3. ColorMath (hue correction, CCT)
4. LightSchedule (scheduling logic)
5. BLEWriteCoalescer (deduplication)
6. FrameAnalysis (data struct)

### Components Needing Abstractions for Integration Testing

1. LightBLEManager → needs LightingController protocol
2. RemoteControlServer → needs NetworkTransport protocol
3. RemoteControlClient → needs DiscoveryProvider protocol
4. MacInputController → needs InputController protocol

### Components Requiring Hardware

1. ScreenCaptureKitProvider → Mac with Screen Recording
2. MetalColorAnalyzer → Mac with Metal GPU
3. LightBLEManager BLE ops → Mac + LED strip
4. MacInputController → Mac + Accessibility
5. Full E2E → Mac + iPhone + LED strip
