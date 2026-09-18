# LightStar Integration Test Plan

> Status: IMPLEMENTED — Test code exists, execution requires macOS
> Generated: September 2026

---

## Overview

This document describes the integration testing strategy for LightStar, covering
the interaction between components through well-defined boundaries.

### Test Pyramid

```
                    ╔════════════════════════════════╗
                    ║     Manual E2E (Hardware)      ║  ← Few, expensive
                    ╚════════════════════════════════╝
               ╔═══════════════════════════════════════════╗
               ║      Integration Tests (with Mocks)       ║  ← Medium count
               ╚═══════════════════════════════════════════╝
          ╔═════════════════════════════════════════════════════╗
          ║              Unit Tests (Pure Logic)                 ║  ← Many, fast
          ╚═════════════════════════════════════════════════════╝
```

---

## Component Boundaries

### 1. Protocol Layer (RemoteProtocol.swift)

**Interface**: Message encoding/decoding functions

**Dependencies**: None (pure functions)

**Tests**:
- Message round-trip encoding
- Length prefix framing
- All message types
- Malformed data handling
- Boundary values

**Location**: `CoreTests.swift`, `ProtocolIntegrationTests.swift`

### 2. Authentication Layer (SessionAuthenticator protocol)

**Interface**: `SessionAuthenticator` protocol

**Dependencies**: None (abstract)

**Tests**:
- Pairing code generation
- Code validation
- Rate limiting
- Session management
- Token validation
- Code expiration

**Location**: `SecurityTests.swift`

**Mock**: `MockSessionAuthenticator`

### 3. Lighting Control Layer (LightingController protocol)

**Interface**: `LightingController` protocol

**Dependencies**: BLE hardware (abstracted)

**Tests**:
- Power control
- Brightness control
- Color control
- Effect control
- Value bounds checking

**Location**: `UserJourneyTests.swift`

**Mock**: `MockLightingController`

### 4. Screen Capture Layer (ScreenFrameProvider protocol)

**Interface**: `ScreenFrameProvider` protocol

**Dependencies**: ScreenCaptureKit (abstracted)

**Tests**:
- Frame delivery
- Protected content detection
- Display enumeration
- Start/stop lifecycle

**Location**: `FrameAnalysisTests.swift`

**Mock**: `MockScreenFrameProvider`

### 5. Input Control Layer (RemoteInputController protocol)

**Interface**: `RemoteInputController` protocol

**Dependencies**: CGEvent (abstracted)

**Tests**:
- Mouse movement
- Click events
- Scroll events
- Keyboard events
- Text input

**Location**: `UserJourneyTests.swift`

**Mock**: `MockInputController`

### 6. Network Transport Layer (MessageTransport protocol)

**Interface**: `MessageTransport` protocol

**Dependencies**: Network.framework (abstracted)

**Tests**:
- Message sending
- Message receiving
- Connection state
- Error handling
- Latency simulation

**Location**: (Available via `MockMessageTransport`)

**Mock**: `MockMessageTransport`

---

## Integration Test Categories

### A. Protocol Integration

Tests the complete message flow from encoding to decoding.

```swift
// Test flow:
1. Create message struct
2. Encode to RemoteMessage
3. Encode to framed Data
4. Decode from Data
5. Verify payload matches
```

**Coverage**:
- All 28 message types
- Edge cases (empty, large, unicode)
- Error conditions (malformed, incomplete)

### B. Session Integration

Tests the authentication flow without network.

```swift
// Test flow:
1. Server generates code
2. Client submits code
3. Server validates
4. Server issues token
5. Client uses token
6. Server validates token
```

**Coverage**:
- Happy path pairing
- Wrong code rejection
- Rate limiting
- Session lifecycle

### C. Lighting Control Integration

Tests commands reaching the lighting abstraction.

```swift
// Test flow:
1. Receive authenticated command
2. Validate session
3. Parse command
4. Execute on LightingController
5. Verify mock state
```

**Coverage**:
- All lighting commands
- Value validation
- State transitions

### D. Screen Capture Integration

Tests frame processing pipeline with mock frames.

```swift
// Test flow:
1. Configure mock provider
2. Start capture
3. Deliver test frames
4. Verify analysis results
5. Check protected content detection
```

**Coverage**:
- Frame delivery
- Color extraction
- DRM detection
- Lifecycle management

### E. Input Control Integration

Tests input command flow to the input abstraction.

```swift
// Test flow:
1. Receive authenticated input command
2. Validate session
3. Parse input event
4. Execute on InputController
5. Verify mock records event
```

**Coverage**:
- All input types
- Coordinate handling
- Modifier keys
- Text input

---

## Mock Implementations

### MockLightingController

**Purpose**: Record lighting commands without BLE hardware

**Features**:
- State tracking (power, brightness, color, etc.)
- Command history
- Value bounds checking
- Reset capability

**Usage**:
```swift
let controller = MockLightingController()
controller.setBrightness(0.5)
XCTAssertEqual(controller.brightness, 0.5)
XCTAssertEqual(controller.commandCount(ofType: .brightness), 1)
```

### MockScreenFrameProvider

**Purpose**: Deliver deterministic frames without screen capture

**Features**:
- Configurable frame sequence
- Loop mode
- Immediate delivery
- Error simulation
- Frame count tracking

**Usage**:
```swift
let provider = MockScreenFrameProvider()
provider.framesToDeliver = [.pureRed, .pureGreen]
try await provider.start()
// ... receive frames
await provider.stop()
```

### MockSessionAuthenticator

**Purpose**: Implement proper authentication logic for testing

**Features**:
- Code generation
- Rate limiting
- Session management
- Call tracking

**Usage**:
```swift
let auth = MockSessionAuthenticator()
let code = auth.generatePairingCode()
let token = auth.validatePairingCode(code, clientID: "test")
XCTAssertNotNil(token)
```

### MockInputController

**Purpose**: Record input events without actual injection

**Features**:
- Event history
- State tracking (mouse position, pressed keys)
- Event filtering

**Usage**:
```swift
let input = MockInputController()
input.moveMouse(deltaX: 10, deltaY: -5)
XCTAssertEqual(input.currentMouseX, 10)
```

### MockMessageTransport

**Purpose**: Simulate network communication

**Features**:
- Message queuing
- Latency simulation
- Auto-respond mode
- Connection state control

**Usage**:
```swift
let transport = MockMessageTransport()
try await transport.send(message)
transport.enqueueForReceive(response)
let received = try await transport.receive()
```

---

## Test Fixtures

### Frame Fixtures (FrameAnalysis)

| Fixture | Hue | Sat | Bright | Black% | Region | Protected |
|---------|-----|-----|--------|--------|--------|-----------|
| pureRed | 0.0 | 1.0 | 1.0 | 0 | No | No |
| pureGreen | 0.333 | 1.0 | 1.0 | 0 | No | No |
| pureBlue | 0.667 | 1.0 | 1.0 | 0 | No | No |
| pureWhite | 0.0 | 0.0 | 1.0 | 0 | No | No |
| allBlack | 0.0 | 0.0 | 0.0 | 1.0 | Yes | Yes |
| protectedContent | 0.5 | 0.3 | 0.2 | 0.75 | Yes | Yes |
| normalDesktop | 0.6 | 0.4 | 0.7 | 0.1 | No | No |

---

## Execution Plan

### Phase 1: Unit Tests
```bash
swift test --filter "BLEProtocolTests|ColorMathTests|LightScheduleTests"
```

### Phase 2: Protocol Tests
```bash
swift test --filter "RemoteProtocolTests|ProtocolIntegrationTests"
```

### Phase 3: Security Tests
```bash
swift test --filter "SecurityTests"
```

### Phase 4: Integration Tests
```bash
swift test --filter "FrameAnalysisTests|UserJourneyTests"
```

### Phase 5: All Tests
```bash
swift test
```

---

## CI Integration

### Current CI Capability (GitHub Actions)

| Test Category | CI Executable | Notes |
|---------------|---------------|-------|
| Unit Tests | ✅ Yes | Pure Swift |
| Protocol Tests | ✅ Yes | Pure Swift |
| Security Tests | ✅ Yes | Uses mocks |
| Frame Analysis | ⚠️ macOS only | Uses macOS FrameAnalysis |
| User Journeys | ⚠️ macOS only | Uses macOS APIs |

### Recommended CI Workflow

```yaml
name: Tests
on: [push, pull_request]
jobs:
  unit-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Run Unit Tests
        run: |
          cd LightStarCore
          swift test
```

---

## Test Documentation Standards

Each test must include:

1. **Test ID**: Unique identifier (e.g., `J1-001`)
2. **Description**: What the test verifies
3. **Category**: Execution environment required
4. **Preconditions**: Setup requirements
5. **Expected Result**: Pass criteria

Example:
```swift
/// TEST_ID: J1-001
/// Tests the complete first-time setup flow with mocks.
/// CATEGORY: MAC_REQUIRED
/// PRECONDITIONS: None (uses mocks)
/// EXPECTED: Session token issued after valid pairing
func testFirstTimeSetupJourney() async throws {
    // ...
}
```
