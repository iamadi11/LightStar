# LightStar Test Matrix

> Generated: September 2026
> Environment: Cloud Agent (Linux, no Swift runtime)
> Legend: A=CLOUD_EXECUTABLE, B=MAC_REQUIRED, C=IPHONE_REQUIRED, D=MAC_AND_IPHONE_REQUIRED, E=EXTERNAL_HARDWARE_REQUIRED, F=RESEARCH_ONLY

---

## CRITICAL CORRECTION

**The tests listed below were NOT executed in this cloud environment.**

- Swift compiler: NOT AVAILABLE
- macOS SDK: NOT AVAILABLE  
- Xcode: NOT AVAILABLE
- Command executed: `which swift` → "Swift not available"

The "INFERRED_FROM_CI" status means the test exists in code and CI workflow logs indicate it passes on the GitHub Actions macos-15 runner. This is NOT the same as direct execution verification.

---

## Test Classification

### A. Tests With Existing Code (Execution Blocked)

| Test ID | Feature | Test File | Test Function | CI Status | Local Execution | Status | Evidence |
|---------|---------|-----------|---------------|-----------|-----------------|--------|----------|
| A001 | BLE Protocol Framing | CoreTests.swift | testAllFrames | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A002 | Hue LUT Monotonicity | CoreTests.swift | testHueLUTIsMonotonicNonDecreasing | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A003 | Purple Recalibration | CoreTests.swift | testPurpleMagentaRecalibrationRegion | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A004 | Circadian Night Warm | CoreTests.swift | testCircadianNightIsWarm | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A005 | Kelvin Neutral Saturation | CoreTests.swift | testKelvinNeutralIsLowSaturation | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A006 | Schedule Not Due After | CoreTests.swift | testCreatedAfterDueTimeDoesNotFire | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A007 | Schedule Nil LastFired | CoreTests.swift | testNilLastFiredAtIsNeverDue | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A008 | Schedule Catch-up | CoreTests.swift | testCatchUpFiresWhenLastFiredBeforeScheduledInstant | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A009 | Schedule Next Fire Future | CoreTests.swift | testNextFireIsInTheFuture | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A010 | Write Coalescer Order | CoreTests.swift | testReplaceInPlacePreservesInsertionOrder | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A011 | Pending Actions Cap | CoreTests.swift | testPendingActionsCap | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A012 | Drain Clears Once | CoreTests.swift | testDrainClearsQueueOnce | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A013 | Legacy Preset Decode | CoreTests.swift | testLegacyPresetJSONWithoutOptionalFieldsDecodes | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A014 | Legacy Schedule Decode | CoreTests.swift | testLegacyScheduleJSONWithoutLastFiredAtDecodes | Passes in CI | NOT_EXECUTED | INFERRED_FROM_CI | CI workflow logs |
| A015 | Protocol Ping Round-trip | CoreTests.swift | testPingMessageRoundTrip | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |
| A016 | Protocol Power Round-trip | CoreTests.swift | testSetPowerMessageRoundTrip | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |
| A017 | Protocol Brightness Round-trip | CoreTests.swift | testSetBrightnessMessageRoundTrip | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |
| A018 | Protocol Mouse Round-trip | CoreTests.swift | testMouseMoveMessageRoundTrip | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |
| A019 | Protocol Multi-message | CoreTests.swift | testMultipleMessagesInStream | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |
| A020 | Protocol Length Prefix | CoreTests.swift | testLengthPrefixIsBigEndian | Unknown | NOT_EXECUTED | TEST_CODE_EXISTS | Test added this session |

### B. Mac-Required Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| B001 | macOS Build | Xcode 26.3 | Mac | Auto | Build succeeds | N/A | BLOCKED_ENVIRONMENT | CI passes |
| B002 | ScreenCaptureKit Init | Screen Recording permission | Mac | Manual | Stream starts | N/A | NOT_TESTED | — |
| B003 | Display Enumeration | Screen Recording permission | Mac | Manual | Returns display list | N/A | NOT_TESTED | — |
| B004 | Metal Shader Compile | Metal GPU | Mac | Auto | Shaders compile | N/A | NOT_TESTED | — |
| B005 | Metal Histogram | Metal GPU | Mac | Auto | Correct histogram | N/A | NOT_TESTED | — |
| B006 | CPU/GPU Parity | Metal GPU | Mac | Auto | Same results | N/A | NOT_TESTED | — |
| B007 | Accessibility Permission | System Preferences | Mac | Manual | AXIsProcessTrusted | N/A | NOT_TESTED | — |
| B008 | Mouse Movement | Accessibility permission | Mac | Manual | Cursor moves | N/A | NOT_TESTED | — |
| B009 | Mouse Click | Accessibility permission | Mac | Manual | Click registers | N/A | NOT_TESTED | — |
| B010 | Keyboard Input | Accessibility permission | Mac | Manual | Keys typed | N/A | NOT_TESTED | — |
| B011 | TCP Server Start | Network permission | Mac | Manual | Listens on port | N/A | NOT_TESTED | — |
| B012 | Bonjour Publish | Network permission | Mac | Manual | Service visible | N/A | NOT_TESTED | — |
| B013 | Desktop Capture | Screen Recording | Mac | Manual | Colors captured | N/A | NOT_TESTED | — |
| B014 | YouTube Capture | Screen Recording | Mac | Manual | Colors captured | N/A | NOT_TESTED | — |
| B015 | Netflix Chrome HW ON | Screen Recording, Chrome | Mac | Manual | Black frame | N/A | NOT_TESTED | — |
| B016 | Netflix Chrome HW OFF | Screen Recording, Chrome | Mac | Manual | Colors captured | N/A | NOT_TESTED | — |
| B017 | Netflix Safari | Screen Recording, Safari | Mac | Manual | Black frame | N/A | NOT_TESTED | — |
| B018 | Prime Chrome HW ON | Screen Recording, Chrome | Mac | Manual | Black frame | N/A | NOT_TESTED | — |
| B019 | Prime Chrome HW OFF | Screen Recording, Chrome | Mac | Manual | Colors captured | N/A | NOT_TESTED | — |
| B020 | External Display | External monitor | Mac | Manual | Capture works | N/A | NOT_TESTED | — |

### C. iPhone-Required Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| C001 | iOS Build | Xcode 26.3 | iPhone | Auto | Build succeeds | N/A | BLOCKED_ENVIRONMENT | CI passes |
| C002 | Bonjour Discovery | Same network as Mac | iPhone | Manual | Finds Mac server | N/A | NOT_TESTED | — |
| C003 | Connection UI | Running Mac server | iPhone | Manual | States transition correctly | N/A | NOT_TESTED | — |
| C004 | Trackpad Gestures | Connected to Mac | iPhone | Manual | Recognizes tap/drag/scroll | N/A | NOT_TESTED | — |
| C005 | Keyboard Input | Connected to Mac | iPhone | Manual | Text field captures input | N/A | NOT_TESTED | — |

### D. Mac-and-iPhone-Required Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| D001 | End-to-End Connection | Both apps running, same network | Manual | Manual | Client connects to server | N/A | NOT_TESTED | — |
| D002 | Pairing Flow | Connected | Manual | Manual | Code accepted, authenticated | N/A | NOT_TESTED | — |
| D003 | Light Power Control | Connected, BLE strip | Manual | Manual | Strip turns on/off | N/A | NOT_TESTED | — |
| D004 | Light Brightness | Connected, BLE strip | Manual | Manual | Brightness changes | N/A | NOT_TESTED | — |
| D005 | Light Color | Connected, BLE strip | Manual | Manual | Color changes | N/A | NOT_TESTED | — |
| D006 | Remote Mouse Move | Connected, Accessibility | Manual | Manual | Mac cursor moves | N/A | NOT_TESTED | — |
| D007 | Remote Mouse Click | Connected, Accessibility | Manual | Manual | Mac click registers | N/A | NOT_TESTED | — |
| D008 | Remote Scroll | Connected, Accessibility | Manual | Manual | Mac scroll works | N/A | NOT_TESTED | — |
| D009 | Remote Keyboard | Connected, Accessibility | Manual | Manual | Mac receives keys | N/A | NOT_TESTED | — |
| D010 | State Sync | Connected | Manual | Manual | iPhone shows Mac state | N/A | NOT_TESTED | — |
| D011 | Disconnect Recovery | Connected, then disconnect | Manual | Manual | Both sides detect disconnect | N/A | NOT_TESTED | — |

### E. External-Hardware-Required Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| E001 | BLE Strip Discovery | LED strip powered | Manual | Manual | Strip found via BLE scan | N/A | NOT_TESTED | — |
| E002 | BLE Strip Connect | Strip discovered | Manual | Manual | Connection established | N/A | NOT_TESTED | — |
| E003 | BLE Power On | Connected | Manual | Manual | Strip lights up | N/A | NOT_TESTED | — |
| E004 | BLE Power Off | Strip on | Manual | Manual | Strip turns off | N/A | NOT_TESTED | — |
| E005 | BLE Color Hue | Connected, strip on | Manual | Manual | Color changes | N/A | NOT_TESTED | — |
| E006 | BLE Brightness | Connected, strip on | Manual | Manual | Brightness changes | N/A | NOT_TESTED | — |
| E007 | BLE Effect | Connected, strip on | Manual | Manual | Effect plays | N/A | NOT_TESTED | — |
| E008 | Video Sync Mode | Screen Recording, strip | Manual | Manual | Colors sync to screen | N/A | NOT_TESTED | — |
| E009 | Audio Sync Mode | Microphone, strip | Manual | Manual | Colors react to audio | N/A | NOT_TESTED | — |
| E010 | HDMI Capture | External display, strip | Manual | Manual | External display colors work | N/A | NOT_TESTED | — |

### F. Research-Only Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| F001 | IOSurface Access | Mac, research code | Manual | Manual | Document findings | N/A | RESEARCH_ONLY | — |
| F002 | Metal Compositor | Mac, research code | Manual | Manual | Document findings | N/A | RESEARCH_ONLY | — |
| F003 | IOFramebuffer | Mac, research code | Manual | Manual | Document findings | N/A | RESEARCH_ONLY | — |
| F004 | DCP Access | Mac, research code | Manual | Manual | Document findings | N/A | RESEARCH_ONLY | — |

---

## Test Coverage Summary

| Category | Total | Inferred from CI | Test Code Exists | Not Executed | Blocked | Research |
|----------|-------|------------------|------------------|--------------|---------|----------|
| A (Cloud-theoretically) | 20 | 14 | 6 | 20 | 20 | 0 |
| B (Mac) | 20 | 0 | 0 | 20 | 20 | 0 |
| C (iPhone) | 5 | 0 | 0 | 5 | 5 | 0 |
| D (Mac+iPhone) | 11 | 0 | 0 | 11 | 11 | 0 |
| E (Hardware) | 10 | 0 | 0 | 10 | 10 | 0 |
| F (Research) | 4 | 0 | 0 | 4 | 0 | 4 |
| **Total** | **70** | **14** | **6** | **70** | **66** | **4** |

**IMPORTANT**: "Inferred from CI" means the test exists and CI logs suggest it passes on the GitHub Actions runner. This is NOT the same as verified execution. All 70 tests remain NOT_EXECUTED in this local environment.

---

## Known Limitations (CRITICAL)

1. **Cloud environment has no Swift compiler** — `which swift` returns nothing
2. **No macOS SDK** — Cannot compile any macOS-specific code
3. **No iOS SDK** — Cannot compile iOS-specific code  
4. **No Metal framework** — Cannot verify shader compilation
5. **No test execution** — Zero tests were actually run
6. **CI inference only** — Previous test passage inferred from CI workflow, not directly observed

---

## Commands for Mac Execution

When Mac is available, run:

```bash
# Unit tests
cd LightStarCore && swift test

# Build validation
xcodegen generate
xcodebuild build -scheme LightStar -configuration Debug CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme LightStariOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO

# Metal shader verification
# (Integrated into swift test if tests exist)
```
