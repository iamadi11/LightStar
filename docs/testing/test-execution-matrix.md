# LightStar Test Execution Matrix

> Generated: September 2026
> Status: TEST_CODE_EXISTS — Tests implemented but execution environment varies
> Actual Execution: BLOCKED_IN_CLOUD — No Swift runtime available in this environment

---

## Execution Categories

| Category | Description | Requirements |
|----------|-------------|--------------|
| CLOUD_EXECUTABLE | Can run in CI without macOS | Swift runtime only |
| MAC_SIMULATOR | Requires macOS but no hardware | macOS + Xcode |
| MAC_REQUIRED | Requires macOS runtime | macOS + Swift |
| IPHONE_SIMULATOR | Requires iOS simulator | macOS + Xcode + Simulator |
| IPHONE_REQUIRED | Requires physical iPhone | iPhone device |
| MAC_AND_IPHONE_REQUIRED | Requires both devices | Mac + iPhone + Network |
| PHYSICAL_BLE_HARDWARE_REQUIRED | Requires LED strip | Mac + BLE + LED strip |
| MANUAL_E2E_REQUIRED | Requires human verification | All hardware + human |

---

## Unit Tests (CoreTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| U001 | testAllFrames | CoreTests.swift:12 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | BLE protocol framing |
| U002 | testHueLUTIsMonotonicNonDecreasing | CoreTests.swift:36 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | ColorMath validation |
| U003 | testPurpleMagentaRecalibrationRegion | CoreTests.swift:44 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Hue correction |
| U004 | testCircadianNightIsWarm | CoreTests.swift:50 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | CCT curve |
| U005 | testKelvinNeutralIsLowSaturation | CoreTests.swift:58 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Color temp |
| U006 | testCreatedAfterDueTimeDoesNotFire | CoreTests.swift:82 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Schedule logic |
| U007 | testNilLastFiredAtIsNeverDue | CoreTests.swift:95 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Schedule logic |
| U008 | testCatchUpFiresWhenLastFiredBeforeScheduledInstant | CoreTests.swift:108 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Catch-up |
| U009 | testNextFireIsInTheFuture | CoreTests.swift:123 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Future fire |
| U010 | testReplaceInPlacePreservesInsertionOrder | CoreTests.swift:143 | MAC_REQUIRED | INFERRED_FROM_CI | Coalescer |
| U011 | testPendingActionsCap | CoreTests.swift:159 | MAC_REQUIRED | INFERRED_FROM_CI | Pending cap |
| U012 | testDrainClearsQueueOnce | CoreTests.swift:167 | MAC_REQUIRED | INFERRED_FROM_CI | Queue drain |
| U013 | testLegacyPresetJSONWithoutOptionalFieldsDecodes | CoreTests.swift:179 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Migration |
| U014 | testLegacyScheduleJSONWithoutLastFiredAtDecodes | CoreTests.swift:188 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Migration |

## Remote Protocol Tests (CoreTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| P001 | testPingMessageRoundTrip | CoreTests.swift:213 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Basic framing |
| P002 | testSetPowerMessageRoundTrip | CoreTests.swift:221 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Power message |
| P003 | testSetBrightnessMessageRoundTrip | CoreTests.swift:232 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Brightness msg |
| P004 | testMouseMoveMessageRoundTrip | CoreTests.swift:243 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Mouse message |
| P005 | testMultipleMessagesInStream | CoreTests.swift:255 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Stream parsing |
| P006 | testLengthPrefixIsBigEndian | CoreTests.swift:268 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Endianness |
| P007 | testIncompleteMessageThrows | CoreTests.swift:279 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Error handling |
| P008 | testHelloMessageRoundTrip | CoreTests.swift:285 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Hello message |
| P009 | testLightStarStateEquatable | CoreTests.swift:298 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | State equality |
| P010 | testAllMessageTypesHaveDistinctRawValues | CoreTests.swift:318 | CLOUD_EXECUTABLE | INFERRED_FROM_CI | Type uniqueness |

## Protocol Integration Tests (ProtocolIntegrationTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| P001 | testInvalidMessageTypeHandling | ProtocolIntegrationTests.swift:15 | MAC_REQUIRED | NOT_EXECUTED | Error handling |
| P002 | testMalformedJSONPayload | ProtocolIntegrationTests.swift:26 | MAC_REQUIRED | NOT_EXECUTED | Malformed JSON |
| P003 | testBrightnessBoundaryValues | ProtocolIntegrationTests.swift:36 | MAC_REQUIRED | NOT_EXECUTED | Boundary tests |
| P004 | testColorHueBoundaryValues | ProtocolIntegrationTests.swift:55 | MAC_REQUIRED | NOT_EXECUTED | Hue boundaries |
| P005 | testEffectIDRange | ProtocolIntegrationTests.swift:67 | MAC_REQUIRED | NOT_EXECUTED | Effect IDs |
| P006 | testSyncModeValues | ProtocolIntegrationTests.swift:80 | MAC_REQUIRED | NOT_EXECUTED | Sync modes |
| P007 | testMouseDeltaValues | ProtocolIntegrationTests.swift:93 | MAC_REQUIRED | NOT_EXECUTED | Mouse deltas |
| P008 | testKeyModifierCombinations | ProtocolIntegrationTests.swift:114 | MAC_REQUIRED | NOT_EXECUTED | Key modifiers |
| P009 | testTextInputCharacterSets | ProtocolIntegrationTests.swift:132 | MAC_REQUIRED | NOT_EXECUTED | Unicode/emoji |
| P010 | testAllMediaKeyTypes | ProtocolIntegrationTests.swift:149 | MAC_REQUIRED | NOT_EXECUTED | Media keys |
| P011 | testLightStarStateFullyPopulated | ProtocolIntegrationTests.swift:167 | MAC_REQUIRED | NOT_EXECUTED | Full state |
| P012 | testLightStarStateMinimal | ProtocolIntegrationTests.swift:198 | MAC_REQUIRED | NOT_EXECUTED | Minimal state |
| P013 | testErrorMessage | ProtocolIntegrationTests.swift:217 | MAC_REQUIRED | NOT_EXECUTED | Error encoding |
| P014 | testZeroLengthPayload | ProtocolIntegrationTests.swift:228 | MAC_REQUIRED | NOT_EXECUTED | Empty payload |
| P015 | testLargeMessageEncoding | ProtocolIntegrationTests.swift:238 | MAC_REQUIRED | NOT_EXECUTED | Stress test |
| P016 | testTrailingDataIgnored | ProtocolIntegrationTests.swift:250 | MAC_REQUIRED | NOT_EXECUTED | Trailing data |
| P017 | testHelloWithProtocolVersion | ProtocolIntegrationTests.swift:263 | MAC_REQUIRED | NOT_EXECUTED | Version check |
| P018 | testPairingMessage | ProtocolIntegrationTests.swift:275 | MAC_REQUIRED | NOT_EXECUTED | Pairing msg |
| P019 | testPairingAckWithToken | ProtocolIntegrationTests.swift:285 | MAC_REQUIRED | NOT_EXECUTED | Token ack |
| P020 | testPairingAckWithError | ProtocolIntegrationTests.swift:297 | MAC_REQUIRED | NOT_EXECUTED | Error ack |

## Security Tests (SecurityTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| S001 | testInvalidPairingCodeRejected | SecurityTests.swift:17 | MAC_REQUIRED | NOT_EXECUTED | Auth validation |
| S002 | testRateLimitingAfterFailedAttempts | SecurityTests.swift:32 | MAC_REQUIRED | NOT_EXECUTED | Rate limiting |
| S003 | testPairingCodeExpiration | SecurityTests.swift:51 | MAC_REQUIRED | NOT_EXECUTED | Code expiry |
| S004 | testSessionTokenValidation | SecurityTests.swift:65 | MAC_REQUIRED | NOT_EXECUTED | Token validation |
| S005 | testSessionInvalidation | SecurityTests.swift:77 | MAC_REQUIRED | NOT_EXECUTED | Session cleanup |
| S006 | testSeparateRateLimitingPerClient | SecurityTests.swift:86 | MAC_REQUIRED | NOT_EXECUTED | Per-client limits |
| S007 | testMessageTimestampsPresent | SecurityTests.swift:107 | MAC_REQUIRED | NOT_EXECUTED | Timestamp check |
| S008 | testOversizedMessageHandling | SecurityTests.swift:118 | MAC_REQUIRED | NOT_EXECUTED | Size limits |
| S009 | testPairingCodeRandomness | SecurityTests.swift:136 | MAC_REQUIRED | NOT_EXECUTED | Code entropy |
| S010 | testSessionTokenRandomness | SecurityTests.swift:148 | MAC_REQUIRED | NOT_EXECUTED | Token entropy |
| S011 | testExtremeMouseDeltas | SecurityTests.swift:163 | MAC_REQUIRED | NOT_EXECUTED | Input bounds |
| S012 | testMalformedTextInput | SecurityTests.swift:180 | MAC_REQUIRED | NOT_EXECUTED | UTF-8 handling |
| S013 | testLightingControllerBoundsChecking | SecurityTests.swift:195 | MAC_REQUIRED | NOT_EXECUTED | Value clamping |
| S014 | testMultipleActiveSessions | SecurityTests.swift:211 | MAC_REQUIRED | NOT_EXECUTED | Session tracking |
| S015 | testFailedAttemptTracking | SecurityTests.swift:226 | MAC_REQUIRED | NOT_EXECUTED | Attempt count |

## Frame Analysis Tests (FrameAnalysisTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| F001 | testAllBlackFrameDetection | FrameAnalysisTests.swift:23 | MAC_REQUIRED | NOT_EXECUTED | DRM detection |
| F002 | testRectangularBlackRegionDetection | FrameAnalysisTests.swift:30 | MAC_REQUIRED | NOT_EXECUTED | Region detect |
| F003 | testNormalFrameNotFlagged | FrameAnalysisTests.swift:39 | MAC_REQUIRED | NOT_EXECUTED | Normal frame |
| F004 | testPureColorFrames | FrameAnalysisTests.swift:45 | MAC_REQUIRED | NOT_EXECUTED | Color frames |
| F005 | testWhiteFrame | FrameAnalysisTests.swift:58 | MAC_REQUIRED | NOT_EXECUTED | White frame |
| F006 | testCustomFrameCreation | FrameAnalysisTests.swift:66 | MAC_REQUIRED | NOT_EXECUTED | Custom frame |
| F007 | testMockProviderDeliversFrames | FrameAnalysisTests.swift:85 | MAC_REQUIRED | NOT_EXECUTED | Frame delivery |
| F008 | testMockProviderLooping | FrameAnalysisTests.swift:102 | MAC_REQUIRED | NOT_EXECUTED | Loop mode |
| F009 | testMockProviderStartError | FrameAnalysisTests.swift:119 | MAC_REQUIRED | NOT_EXECUTED | Error handling |
| F010 | testMockAvailableDisplays | FrameAnalysisTests.swift:131 | MAC_REQUIRED | NOT_EXECUTED | Display list |
| F011 | testImmediateFrameDelivery | FrameAnalysisTests.swift:145 | MAC_REQUIRED | NOT_EXECUTED | Immediate mode |
| F012 | testFrameCountTracking | FrameAnalysisTests.swift:160 | MAC_REQUIRED | NOT_EXECUTED | Count tracking |
| F013 | testProviderReset | FrameAnalysisTests.swift:174 | MAC_REQUIRED | NOT_EXECUTED | Reset state |
| F014 | testProtectionThresholdBoundary | FrameAnalysisTests.swift:189 | MAC_REQUIRED | NOT_EXECUTED | Threshold edge |
| F015 | testBlackRegionFlagRequired | FrameAnalysisTests.swift:209 | MAC_REQUIRED | NOT_EXECUTED | Flag required |

## User Journey Tests (UserJourneyTests.swift)

| Test ID | Test Name | Location | Category | Status | Notes |
|---------|-----------|----------|----------|--------|-------|
| J1-001 | testFirstTimeSetupJourney | UserJourneyTests.swift:15 | MAC_REQUIRED | NOT_EXECUTED | Setup flow |
| J1-002 | testFailedPairingJourney | UserJourneyTests.swift:53 | MAC_REQUIRED | NOT_EXECUTED | Failed pairing |
| J2-001 | testBrightnessControlJourney | UserJourneyTests.swift:69 | MAC_REQUIRED | NOT_EXECUTED | Brightness |
| J2-002 | testPowerControlJourney | UserJourneyTests.swift:90 | MAC_REQUIRED | NOT_EXECUTED | Power control |
| J2-003 | testColorControlJourney | UserJourneyTests.swift:112 | MAC_REQUIRED | NOT_EXECUTED | Color control |
| J2-004 | testEffectControlJourney | UserJourneyTests.swift:126 | MAC_REQUIRED | NOT_EXECUTED | Effect control |
| J3-001 | testScreenSyncJourney | UserJourneyTests.swift:156 | MAC_REQUIRED | NOT_EXECUTED | Screen sync |
| J3-002 | testProtectedContentDuringSync | UserJourneyTests.swift:186 | MAC_REQUIRED | NOT_EXECUTED | DRM during sync |
| J4-001 | testTrackpadGestureJourney | UserJourneyTests.swift:209 | MAC_REQUIRED | NOT_EXECUTED | Trackpad |
| J4-002 | testClickGestureJourney | UserJourneyTests.swift:231 | MAC_REQUIRED | NOT_EXECUTED | Click gesture |
| J4-003 | testScrollGestureJourney | UserJourneyTests.swift:252 | MAC_REQUIRED | NOT_EXECUTED | Scroll gesture |
| J4-004 | testKeyboardInputJourney | UserJourneyTests.swift:269 | MAC_REQUIRED | NOT_EXECUTED | Keyboard |
| J4-005 | testTextInputJourney | UserJourneyTests.swift:290 | MAC_REQUIRED | NOT_EXECUTED | Text input |
| J5-001 | testDisconnectCleanup | UserJourneyTests.swift:310 | MAC_REQUIRED | NOT_EXECUTED | Disconnect |
| J5-002 | testStaleSessionRejected | UserJourneyTests.swift:326 | MAC_REQUIRED | NOT_EXECUTED | Stale session |
| J5-003 | testReconnectionRequiresNewSession | UserJourneyTests.swift:337 | MAC_REQUIRED | NOT_EXECUTED | Reconnection |
| JC-001 | testCompleteControlFlow | UserJourneyTests.swift:360 | MAC_REQUIRED | NOT_EXECUTED | Complete flow |
| JC-002 | testAuthenticatedInputControl | UserJourneyTests.swift:387 | MAC_REQUIRED | NOT_EXECUTED | Auth + input |

---

## Summary

| Category | Total Tests | Implemented | Executed | Passed | Failed | Blocked |
|----------|-------------|-------------|----------|--------|--------|---------|
| Unit (CoreTests) | 14 | 14 | 0* | 0 | 0 | 14 |
| Protocol (CoreTests) | 10 | 10 | 0* | 0 | 0 | 10 |
| Protocol Integration | 20 | 20 | 0 | 0 | 0 | 20 |
| Security | 15 | 15 | 0 | 0 | 0 | 15 |
| Frame Analysis | 15 | 15 | 0 | 0 | 0 | 15 |
| User Journey | 18 | 18 | 0 | 0 | 0 | 18 |
| **TOTAL** | **92** | **92** | **0** | **0** | **0** | **92** |

\* Tests in CoreTests are marked INFERRED_FROM_CI because CI runs `swift test` successfully on macOS runners.

---

## Execution Commands

### All Unit Tests (requires macOS + Xcode)
```bash
cd /workspace/LightStarCore
swift test
```

### Specific Test Class
```bash
swift test --filter SecurityTests
swift test --filter UserJourneyTests
swift test --filter FrameAnalysisTests
```

### Single Test
```bash
swift test --filter "testFirstTimeSetupJourney"
```

### Build Only (verify compilation)
```bash
swift build --build-tests
```

---

## Environment Status

| Requirement | Cloud Agent | CI (macos-15) | Local Mac |
|-------------|-------------|---------------|-----------|
| Swift Runtime | ❌ Missing | ✅ Available | ✅ Available |
| Xcode | ❌ Missing | ✅ 26.3 | ✅ Required |
| macOS Frameworks | ❌ Missing | ✅ Available | ✅ Available |
| iOS Simulator | ❌ Missing | ❌ Not in CI | ✅ Available |
| Physical iPhone | ❌ N/A | ❌ N/A | ⚠️ Optional |
| BLE Hardware | ❌ N/A | ❌ N/A | ⚠️ Optional |
| LED Strip | ❌ N/A | ❌ N/A | ⚠️ Optional |

---

## Known Limitations

1. **Cloud Environment**: No Swift runtime available — all tests blocked
2. **CI Environment**: macOS only, no iOS simulator or hardware
3. **Security Tests**: Expected to expose current implementation weaknesses
4. **BLE Tests**: Cannot execute without physical LED strip
5. **Screen Capture Tests**: Requires macOS Screen Recording permission
6. **Input Tests**: Requires macOS Accessibility permission
