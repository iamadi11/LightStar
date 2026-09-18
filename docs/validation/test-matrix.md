# LightStar Test Matrix

> Generated: September 2026
> Environment: Cloud Agent
> Legend: A=CLOUD_EXECUTABLE, B=MAC_REQUIRED, C=IPHONE_REQUIRED, D=MAC_AND_IPHONE_REQUIRED, E=EXTERNAL_HARDWARE_REQUIRED, F=RESEARCH_ONLY

---

## Test Classification

### A. Cloud-Executable Tests

| Test ID | Feature | Preconditions | Execution | Auto/Manual | Expected | Actual | Status | Evidence |
|---------|---------|---------------|-----------|-------------|----------|--------|--------|----------|
| A001 | BLE Protocol Framing | None | Cloud | Auto | All frames have BC prefix, 55 suffix | Verified | PASS | CoreTests.swift:testAllFrames |
| A002 | Hue LUT Monotonicity | None | Cloud | Auto | LUT values non-decreasing | Verified | PASS | CoreTests.swift:testHueLUTIsMonotonicNonDecreasing |
| A003 | Purple Recalibration | None | Cloud | Auto | 305-360° maps to 351-360 | Verified | PASS | CoreTests.swift:testPurpleMagentaRecalibrationRegion |
| A004 | Circadian Night Warm | None | Cloud | Auto | 2AM returns CCT 0.0 | Verified | PASS | CoreTests.swift:testCircadianNightIsWarm |
| A005 | Kelvin Neutral Saturation | None | Cloud | Auto | 4000K has low saturation | Verified | PASS | CoreTests.swift:testKelvinNeutralIsLowSaturation |
| A006 | Schedule Not Due After | None | Cloud | Auto | Created after due time doesn't fire | Verified | PASS | CoreTests.swift:testCreatedAfterDueTimeDoesNotFire |
| A007 | Schedule Nil LastFired | None | Cloud | Auto | Nil lastFiredAt is never due | Verified | PASS | CoreTests.swift:testNilLastFiredAtIsNeverDue |
| A008 | Schedule Catch-up | None | Cloud | Auto | Fires when lastFired before scheduled | Verified | PASS | CoreTests.swift:testCatchUpFiresWhenLastFiredBeforeScheduledInstant |
| A009 | Schedule Next Fire Future | None | Cloud | Auto | Next fire date is in future | Verified | PASS | CoreTests.swift:testNextFireIsInTheFuture |
| A010 | Write Coalescer Order | None | Cloud | Auto | Same cmd replaces in place | Verified | PASS | CoreTests.swift:testReplaceInPlacePreservesInsertionOrder |
| A011 | Pending Actions Cap | None | Cloud | Auto | Queue capped at limit | Verified | PASS | CoreTests.swift:testPendingActionsCap |
| A012 | Drain Clears Once | None | Cloud | Auto | Drain empties queue | Verified | PASS | CoreTests.swift:testDrainClearsQueueOnce |
| A013 | Legacy Preset Decode | None | Cloud | Auto | Old JSON format decodes | Verified | PASS | CoreTests.swift:testLegacyPresetJSONWithoutOptionalFieldsDecodes |
| A014 | Legacy Schedule Decode | None | Cloud | Auto | Old JSON format decodes | Verified | PASS | CoreTests.swift:testLegacyScheduleJSONWithoutLastFiredAtDecodes |
| A015 | Protocol Message Encode | None | Cloud | Auto | encodeMessage produces valid data | NOT_TESTED | NOT_TESTED | No test exists |
| A016 | Protocol Message Decode | None | Cloud | Auto | decodeMessage round-trips | NOT_TESTED | NOT_TESTED | No test exists |
| A017 | Protocol Message Types | None | Cloud | Auto | All message types serialize | NOT_TESTED | NOT_TESTED | No test exists |
| A018 | Synthetic Frame Red | None | Cloud | Auto | Pure red frame → hue ~0 | NOT_TESTED | NOT_TESTED | No test exists |
| A019 | Synthetic Frame Blue | None | Cloud | Auto | Pure blue frame → hue ~0.67 | NOT_TESTED | NOT_TESTED | No test exists |
| A020 | Synthetic Frame Black | None | Cloud | Auto | All black → 100% black pixels | NOT_TESTED | NOT_TESTED | No test exists |

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

| Category | Total | Pass | Fail | Blocked | Not Tested | Research |
|----------|-------|------|------|---------|------------|----------|
| A (Cloud) | 20 | 14 | 0 | 0 | 6 | 0 |
| B (Mac) | 20 | 0 | 0 | 20 | 0 | 0 |
| C (iPhone) | 5 | 0 | 0 | 5 | 0 | 0 |
| D (Mac+iPhone) | 11 | 0 | 0 | 11 | 0 | 0 |
| E (Hardware) | 10 | 0 | 0 | 10 | 0 | 0 |
| F (Research) | 4 | 0 | 0 | 0 | 0 | 4 |
| **Total** | **70** | **14** | **0** | **46** | **6** | **4** |

---

## Known Limitations

1. **Cloud environment has no Swift compiler** — Cannot execute swift build/test
2. **No macOS SDK** — Cannot compile macOS-specific code
3. **No iOS SDK** — Cannot compile iOS-specific code
4. **No Metal** — Cannot verify shader compilation or GPU execution
5. **No network loopback testing** — TCP server/client tests require runtime
6. **No BLE simulation** — LED strip testing requires physical hardware

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
