# LightStar End-to-End User Journeys

> Status: DOCUMENTED — Journeys defined, automated tests implemented with mocks
> Hardware Testing: MANUAL_REQUIRED

---

## Journey 1: First-Time Setup

### Description
A new user installs LightStar on their Mac and iPhone, then pairs the devices.

### Prerequisites
- Mac with LightStar app installed
- iPhone with LightStar Controller app installed
- Both devices on same local network
- LED strip connected to Mac via BLE

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 1.1 | User | Opens Mac app | Menu bar icon appears, app running | MAC_REQUIRED |
| 1.2 | System | Mac starts Bonjour service | `_lightstar._tcp` service registered | MAC_REQUIRED |
| 1.3 | User | Opens iPhone app | Discovery screen shown | IPHONE_REQUIRED |
| 1.4 | System | iPhone discovers Mac | Mac appears in server list | MAC_AND_IPHONE |
| 1.5 | User | Taps discovered Mac | Pairing code prompt shown | IPHONE_REQUIRED |
| 1.6 | System | Mac displays pairing code | 4-6 digit code shown on Mac | MAC_REQUIRED |
| 1.7 | User | Enters code on iPhone | Code sent to Mac | IPHONE_REQUIRED |
| 1.8 | System | Mac validates code | Session token issued | J1-001 (mock) |
| 1.9 | System | iPhone receives token | Connected state shown | MAC_AND_IPHONE |
| 1.10 | System | Mac sends initial state | Lighting state displayed | J1-001 (mock) |

### Failure Scenarios

| Scenario | Test ID | Expected Behavior |
|----------|---------|-------------------|
| Wrong pairing code | J1-002 | Error shown, retry allowed |
| Code expired | S003 | Error shown, new code required |
| Rate limited | S002 | Error shown, wait required |
| Network unavailable | — | Timeout, retry option |

### Automated Coverage
- `testFirstTimeSetupJourney` (J1-001): Full flow with mocks
- `testFailedPairingJourney` (J1-002): Wrong code handling

---

## Journey 2: Lighting Control

### Description
User controls LED strip brightness, color, and effects from iPhone.

### Prerequisites
- Paired Mac and iPhone
- Active session
- LED strip connected

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 2.1 | User | Taps power button | Power command sent | J2-002 |
| 2.2 | System | Mac receives command | State updated, LED responds | PHYSICAL_BLE |
| 2.3 | User | Adjusts brightness slider | Brightness command sent | J2-001 |
| 2.4 | System | Mac applies brightness | LED brightness changes | PHYSICAL_BLE |
| 2.5 | User | Selects color | Color command sent | J2-003 |
| 2.6 | System | Mac applies color | LED color changes | PHYSICAL_BLE |
| 2.7 | User | Selects effect | Effect command sent | J2-004 |
| 2.8 | System | Mac starts effect | LED animates | PHYSICAL_BLE |

### Automated Coverage
- `testBrightnessControlJourney` (J2-001): Brightness with mock
- `testPowerControlJourney` (J2-002): Power on/off with mock
- `testColorControlJourney` (J2-003): Color change with mock
- `testEffectControlJourney` (J2-004): Effect change with mock

---

## Journey 3: Screen Synchronization

### Description
User enables screen sync to have LED colors match the display.

### Prerequisites
- Paired and connected
- Screen Recording permission granted
- Display visible (not sleeping)

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 3.1 | User | Enables video sync mode | Sync command sent | — |
| 3.2 | System | Mac starts capture | ScreenCaptureKit initialized | MAC_REQUIRED |
| 3.3 | System | Mac analyzes frames | Dominant color extracted | J3-001 (mock) |
| 3.4 | System | Mac updates LEDs | Color matches screen | PHYSICAL_BLE |
| 3.5 | User | Plays protected video | DRM detection triggered | J3-002 (mock) |
| 3.6 | System | Mac detects black frames | Warning shown, fallback suggested | MAC_REQUIRED |
| 3.7 | User | Disables sync | Capture stopped | — |

### DRM Scenarios

| Content | Expected Result | Test Coverage |
|---------|-----------------|---------------|
| Normal content | Colors match screen | J3-001 |
| Netflix (HW accel) | Black frames detected | J3-002 |
| Safari streaming | Black frames likely | MANUAL |
| Chrome (SW render) | Colors may work | MANUAL |

### Automated Coverage
- `testScreenSyncJourney` (J3-001): Frame processing with mock
- `testProtectedContentDuringSync` (J3-002): DRM detection with mock

---

## Journey 4: Remote Trackpad and Keyboard

### Description
User controls Mac cursor and keyboard from iPhone.

### Prerequisites
- Paired and connected
- Accessibility permission granted on Mac

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 4.1 | User | Enables remote input | Input mode activated | — |
| 4.2 | User | Swipes on trackpad | Mouse move sent | J4-001 |
| 4.3 | System | Mac injects movement | Cursor moves | MAC_REQUIRED |
| 4.4 | User | Taps trackpad | Click sent | J4-002 |
| 4.5 | System | Mac injects click | Click occurs | MAC_REQUIRED |
| 4.6 | User | Two-finger scroll | Scroll sent | J4-003 |
| 4.7 | System | Mac injects scroll | Page scrolls | MAC_REQUIRED |
| 4.8 | User | Types on keyboard | Text sent | J4-005 |
| 4.9 | System | Mac injects keys | Text appears | MAC_REQUIRED |

### Automated Coverage
- `testTrackpadGestureJourney` (J4-001): Mouse movement with mock
- `testClickGestureJourney` (J4-002): Click events with mock
- `testScrollGestureJourney` (J4-003): Scroll with mock
- `testKeyboardInputJourney` (J4-004): Key events with mock
- `testTextInputJourney` (J4-005): Text input with mock

---

## Journey 5: Connection Failure and Recovery

### Description
Network disruption occurs and system recovers gracefully.

### Prerequisites
- Established connection
- Active session

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 5.1 | System | Network interrupted | Connection lost | — |
| 5.2 | iPhone | Detects disconnect | Disconnected UI shown | J5-001 |
| 5.3 | Mac | Detects disconnect | Session cleaned up | J5-001 |
| 5.4 | System | Network restored | Discovery resumes | — |
| 5.5 | iPhone | Finds Mac again | Reconnect option shown | — |
| 5.6 | User | Initiates reconnect | Re-pairing flow | — |
| 5.7 | System | New session established | Connected state restored | J5-003 |
| 5.8 | System | Old token rejected | Security maintained | J5-002 |

### Automated Coverage
- `testDisconnectCleanup` (J5-001): Session cleanup
- `testStaleSessionRejected` (J5-002): Old token rejection
- `testReconnectionRequiresNewSession` (J5-003): Fresh session

---

## Journey 6: Multi-Display Setup

### Description
User with multiple displays selects which display to sync.

### Prerequisites
- Multiple displays connected to Mac
- Video sync available

### Steps

| Step | Actor | Action | Expected Result | Automated Test |
|------|-------|--------|-----------------|----------------|
| 6.1 | System | Mac enumerates displays | Display list populated | — |
| 6.2 | System | iPhone receives display list | Options shown | — |
| 6.3 | User | Selects external display | Selection command sent | — |
| 6.4 | System | Mac updates capture target | Correct display captured | MAC_REQUIRED |

### Automated Coverage
- Display enumeration tested via `MockScreenFrameProvider.availableDisplays`
- Full flow requires manual testing with hardware

---

## Manual E2E Checklist

### First-Time Setup (MANUAL_E2E_REQUIRED)

- [ ] Mac app installs cleanly from DMG
- [ ] iPhone app installs from App Store/TestFlight
- [ ] Bonjour discovery works across network
- [ ] Pairing code displays correctly on Mac
- [ ] Pairing succeeds with correct code
- [ ] Pairing fails with incorrect code
- [ ] Rate limiting activates after 3 failures
- [ ] Connected state persists across app restarts

### Lighting Control (PHYSICAL_BLE_HARDWARE_REQUIRED)

- [ ] Power on/off works
- [ ] Brightness slider responds smoothly
- [ ] Color picker changes LED color
- [ ] All effects work correctly
- [ ] Effect speed adjustment works
- [ ] Effect direction reversal works

### Screen Sync (MAC_REQUIRED)

- [ ] Video sync activates successfully
- [ ] LED colors match screen content
- [ ] DRM content shows black frame warning
- [ ] Sync stops cleanly
- [ ] Multiple displays can be selected

### Remote Input (MAC_REQUIRED)

- [ ] Trackpad movement is smooth
- [ ] Click gestures work
- [ ] Scroll direction is correct
- [ ] Keyboard input is accurate
- [ ] Modifier keys work (Cmd, Opt, Ctrl)
- [ ] Special characters work
- [ ] Media keys work

### Connection Resilience (MAC_AND_IPHONE_REQUIRED)

- [ ] App handles WiFi disconnection gracefully
- [ ] Reconnection works after network restore
- [ ] Background operation maintains connection
- [ ] Multiple iPhones can connect
- [ ] Session cleanup on force quit

---

## Test Implementation Files

| Journey | Test File | Test Class |
|---------|-----------|------------|
| J1 | UserJourneyTests.swift | UserJourneyTests |
| J2 | UserJourneyTests.swift | UserJourneyTests |
| J3 | FrameAnalysisTests.swift | FrameAnalysisTests |
| J4 | UserJourneyTests.swift | UserJourneyTests |
| J5 | UserJourneyTests.swift | UserJourneyTests |
| Security | SecurityTests.swift | SecurityTests |
