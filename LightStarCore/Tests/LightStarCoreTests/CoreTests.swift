import XCTest
@testable import LightStarCore

final class BLEProtocolTests: XCTestCase {
    func assertFrame(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(bytes.isEmpty, file: file, line: line)
        XCTAssertEqual(bytes.first, 0xBC, file: file, line: line)
        XCTAssertEqual(bytes.last, 0x55, file: file, line: line)
        XCTAssertEqual(Int(bytes[2]), bytes.count - 4, "data_len must equal payload size", file: file, line: line)
    }

    func testAllFrames() {
        let allFrames: [[UInt8]] = [
            Cmd.powerOn,
            Cmd.powerOff,
            Cmd.channelOrder(1),
            Cmd.pixelCount(30),
            Cmd.hue(0.5, saturation: 1),
            Cmd.brightness(1),
            Cmd.effect(id: 0x01),
            Cmd.effectDirection(forward: true),
            Cmd.speed(0.5),
            Cmd.audioHue(0.2, saturation: 0.8),
            Cmd.timeSync(year: 26, month: 9, day: 18, hour: 8, minute: 0, second: 0, weekdayMask: 0x01),
            Cmd.weeklyTimer(slot: 1, powerOn: false, enabled: true, dayMask: 0x1F, hour: 23, minute: 30),
            Cmd.stripMic(enabled: true),
            Cmd.micStyle(2),
            Cmd.micSensitivity(128),
            Cmd.animation(id: 0x10),
        ]
        for frame in allFrames { assertFrame(frame) }
    }

    func testBrightnessPayloadClampsToProtocolRange() {
        XCTAssertEqual(Cmd.brightness(0), [0xBC, 0x05, 0x06, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x55])
        XCTAssertEqual(Cmd.brightness(1)[3], 0x03)
        XCTAssertEqual(Cmd.brightness(1)[4], 0xE8)
        XCTAssertEqual(Cmd.brightness(-1), Cmd.brightness(0))
        XCTAssertEqual(Cmd.brightness(2), Cmd.brightness(1))
    }

    func testWeeklyTimerPayload() {
        XCTAssertEqual(
            Cmd.weeklyTimer(slot: 1, powerOn: false, enabled: true, dayMask: 0x1F, hour: 23, minute: 30),
            [0xBC, 0x0D, 0x06, 1, 0x00, 0x01, 0x1F, 23, 30, 0x55]
        )
    }

    func testOEMWeekdayBits() {
        XCTAssertEqual(UInt8(1 << ((2 + 5) % 7)), 0x01) // Monday
        XCTAssertEqual(UInt8(1 << ((1 + 5) % 7)), 0x40) // Sunday
        XCTAssertEqual(UInt8(1 << ((7 + 5) % 7)), 0x20) // Saturday
    }
}

final class ColorMathTests: XCTestCase {
    func testHueLUTIsMonotonicNonDecreasing() {
        var lastObs = -1.0
        var lastSend = -1.0
        for pair in ColorMath.hueLUT {
            XCTAssertGreaterThanOrEqual(pair.obs, lastObs,
                "obs column must be non-decreasing, got \(pair.obs) after \(lastObs)")
            XCTAssertGreaterThanOrEqual(pair.send, lastSend,
                "send column must be non-decreasing, got \(pair.send) after \(lastSend)")
            lastObs = pair.obs
            lastSend = pair.send
        }
    }

    func testPurpleMagentaRecalibrationRegion() {
        // 305–360° maps into 351–360 (the 2026-08-24 recalibration).
        let sent = ColorMath.correctedHueDeg(330.0 / 360.0)
        XCTAssertGreaterThan(sent, 350)
        XCTAssertLessThanOrEqual(sent, 360)
    }

    func testCircadianNightIsWarm() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1
        comps.hour = 2; comps.minute = 0
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(ColorMath.circadianCCTValue(for: date), 0.0)
    }

    func testKelvinNeutralIsLowSaturation() {
        let (_, s) = ColorMath.kelvinToHS(4000)
        XCTAssertLessThan(s, 0.25)
    }
}

final class LightScheduleTests: XCTestCase {
    func monday0805() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 5 // Monday
        c.hour = 8; c.minute = 5
        return cal.date(from: c)!
    }

    func eightAM(on day: Date, cal: Calendar) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: day)
        c.hour = 8; c.minute = 0; c.second = 0
        return cal.date(from: c)!
    }

    func testCreatedAfterDueTimeDoesNotFire() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let schedule = LightSchedule(
            label: "Morning",
            time: eightAM(on: now, cal: cal),
            days: [2, 3, 4, 5, 6],
            action: .powerOn,
            lastFiredAt: now
        )
        XCTAssertFalse(schedule.isDue(at: now, calendar: cal))
    }

    func testNilLastFiredAtIsNeverDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let schedule = LightSchedule(
            label: "Morning",
            time: eightAM(on: now, cal: cal),
            days: [2],
            action: .powerOn,
            lastFiredAt: nil
        )
        XCTAssertFalse(schedule.isDue(at: now, calendar: cal))
    }

    func testCatchUpFiresWhenLastFiredBeforeScheduledInstant() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let scheduled = eightAM(on: now, cal: cal)
        let schedule = LightSchedule(
            label: "Morning",
            time: scheduled,
            days: [2],
            action: .powerOn,
            lastFiredAt: scheduled.addingTimeInterval(-3600)
        )
        XCTAssertTrue(schedule.isDue(at: now, catchUp: 15 * 60, calendar: cal))
    }

    func testNextFireIsInTheFuture() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let schedule = LightSchedule(
            label: "Morning",
            time: eightAM(on: now, cal: cal),
            days: [2],
            action: .powerOff,
            lastFiredAt: now
        )
        let next = schedule.nextFireDate(after: now, calendar: cal)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, now)
    }

    func testDisabledScheduleIsNeverDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let scheduled = eightAM(on: now, cal: cal)
        let schedule = LightSchedule(
            label: "Morning",
            time: scheduled,
            days: [2],
            isEnabled: false,
            action: .powerOn,
            lastFiredAt: scheduled.addingTimeInterval(-3600)
        )
        XCTAssertFalse(schedule.isDue(at: now, calendar: cal))
        XCTAssertNil(schedule.nextFireDate(after: now, calendar: cal))
    }

    func testEmptyDaysIsNeverDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = monday0805()
        let schedule = LightSchedule(
            label: "Morning",
            time: eightAM(on: now, cal: cal),
            days: [],
            action: .powerOn,
            lastFiredAt: now.addingTimeInterval(-3600)
        )
        XCTAssertFalse(schedule.isDue(at: now, calendar: cal))
        XCTAssertNil(schedule.nextFireDate(after: now, calendar: cal))
    }

    func testCatchUpBoundaryIsInclusive() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let scheduled = eightAM(on: monday0805(), cal: cal)
        let now = scheduled.addingTimeInterval(15 * 60)
        let schedule = LightSchedule(
            label: "Morning",
            time: scheduled,
            days: [2],
            action: .powerOn,
            lastFiredAt: scheduled.addingTimeInterval(-3600)
        )
        XCTAssertTrue(schedule.isDue(at: now, catchUp: 15 * 60, calendar: cal))
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(1), catchUp: 15 * 60, calendar: cal))
    }

    func testAlreadyFiredForScheduledInstantIsNotDue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let scheduled = eightAM(on: monday0805(), cal: cal)
        let schedule = LightSchedule(
            label: "Morning",
            time: scheduled,
            days: [2],
            action: .powerOn,
            lastFiredAt: scheduled
        )
        XCTAssertFalse(schedule.isDue(at: monday0805(), calendar: cal))
    }

    func testWrongWeekdayIsNotDueInsideCatchUpOfAnotherDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = monday0805()
        // Sunday 4 Jan 2026 08:05 GMT. Schedule is Monday-only at 08:00.
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 4
        c.hour = 8; c.minute = 5
        let sunday = cal.date(from: c)!
        let schedule = LightSchedule(
            label: "Morning",
            time: eightAM(on: monday, cal: cal),
            days: [2],
            action: .powerOn,
            lastFiredAt: sunday.addingTimeInterval(-3600)
        )
        XCTAssertFalse(schedule.isDue(at: sunday, catchUp: 15 * 60, calendar: cal))
    }
}

@MainActor
final class BLEWriteCoalescerTests: XCTestCase {
    func testReplaceInPlacePreservesInsertionOrder() {
        let coalescer = BLEWriteCoalescer(send: { _ in }, isConnected: { true })
        coalescer.enqueue(Cmd.powerOn)
        coalescer.enqueue(Cmd.hue(0, saturation: 1))
        coalescer.enqueue(Cmd.brightness(1))
        coalescer.enqueue(Cmd.powerOff) // same cmd byte 0x01 — replaces powerOn in place
        let drained = coalescer.drainOrderedForTesting()
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual([UInt8](drained[0]), Cmd.powerOff)
        XCTAssertEqual(drained[1][1], 0x04)
        XCTAssertEqual(drained[2][1], 0x05)
    }

    func testFlushClearsQueue() {
        let coalescer = BLEWriteCoalescer(send: { _ in }, isConnected: { true })
        coalescer.enqueue(Cmd.powerOn)
        coalescer.enqueue(Cmd.hue(0.5, saturation: 1))
        coalescer.flush()
        let drained = coalescer.drainOrderedForTesting()
        XCTAssertTrue(drained.isEmpty, "flush() must remove all pending frames")
    }

    func testEnqueueWhileDisconnectedDropsFrame() {
        var sent: [Data] = []
        let coalescer = BLEWriteCoalescer(send: { sent.append($0) }, isConnected: { false })
        coalescer.enqueue(Cmd.powerOn)
        let drained = coalescer.drainOrderedForTesting()
        XCTAssertTrue(drained.isEmpty,
                      "enqueue while disconnected must not add to the queue")
        XCTAssertTrue(sent.isEmpty,
                      "enqueue while disconnected must not trigger a send")
    }
}

@MainActor
final class ScheduleStorePendingTests: XCTestCase {
    func testPendingActionsCap() {
        let store = ScheduleStore()
        for _ in 0..<20 {
            store.enqueuePendingForTesting(.powerOn)
        }
        XCTAssertEqual(store.pendingActions.count, ScheduleStore.pendingCap)
    }

    func testDrainClearsQueueOnce() {
        let store = ScheduleStore()
        store.enqueuePendingForTesting(.powerOff)
        XCTAssertEqual(store.pendingActions.count, 1)
        XCTAssertEqual(store.drainPendingActions(), 1)
        XCTAssertTrue(store.pendingActions.isEmpty)
        XCTAssertEqual(store.drainPendingActions(), 0)
        XCTAssertTrue(store.pendingActions.isEmpty)
    }
}

final class PresetMigrationTests: XCTestCase {
    func testLegacyPresetJSONWithoutOptionalFieldsDecodes() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Reading","red":1,"green":0.95,"blue":0.8,"brightness":1}]
        """.data(using: .utf8)!
        let presets = try JSONDecoder().decode([Preset].self, from: json)
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "Reading")
    }

    func testLegacyScheduleJSONWithoutLastFiredAtDecodes() throws {
        // time is a Date encoded as interval in default encoder; use a round-trip of a
        // stripped payload via JSONSerialization-style keys matching Codable synthesis.
        struct Legacy: Codable {
            var id: UUID
            var label: String
            var time: Date
            var days: Set<Int>
            var isEnabled: Bool
            var action: LightSchedule.ScheduledAction
        }
        let legacy = Legacy(id: UUID(), label: "Bed", time: Date(), days: [1], isEnabled: true, action: .powerOff)
        let data = try JSONEncoder().encode([legacy])
        let decoded = try JSONDecoder().decode([LightSchedule].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].lastFiredAt)
        XCTAssertFalse(decoded[0].isDue(at: .now))
    }
}

// MARK: - Remote Protocol Tests

final class RemoteProtocolTests: XCTestCase {
    
    func testPingMessageRoundTrip() throws {
        let original = RemoteMessage(type: .ping)
        let encoded = try encodeMessage(original)
        let (decoded, consumed) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(consumed, encoded.count)
    }

    func testBinaryPointerFrameRoundTrip() throws {
        let frame = encodePointerFrame(deltaX: 12.3, deltaY: -4.1, isScroll: false)
        XCTAssertEqual(frame.count, kPointerFrameLength)
        let pointer = try decodePointerFrame(from: frame)
        XCTAssertEqual(pointer?.deltaX ?? 0, 12.3, accuracy: 0.05)
        XCTAssertEqual(pointer?.deltaY ?? 0, -4.1, accuracy: 0.05)
        XCTAssertEqual(pointer?.isScroll, false)

        let (message, consumed) = try decodeMessage(from: frame)
        XCTAssertEqual(message.type, .mouseMove)
        XCTAssertEqual(consumed, kPointerFrameLength)
        let move = try message.decode(MouseMoveMessage.self)
        XCTAssertEqual(move.deltaX, 12.3, accuracy: 0.05)
    }

    func testBinaryScrollBesideJSON() throws {
        var stream = Data()
        stream.append(try encodeMessage(RemoteMessage(type: .ping)))
        stream.append(encodePointerFrame(deltaX: 1.5, deltaY: -8, isScroll: true))
        let (ping, first) = try decodeMessage(from: stream)
        stream.removeFirst(first)
        if stream.startIndex != 0 { stream = Data(stream) }
        let (scroll, _) = try decodeMessage(from: stream)
        XCTAssertEqual(ping.type, .ping)
        XCTAssertEqual(scroll.type, .scroll)
        let payload = try scroll.decode(MouseMoveMessage.self)
        XCTAssertEqual(payload.deltaY, -8, accuracy: 0.1)
    }
    
    func testSetPowerMessageRoundTrip() throws {
        let payload = SetPowerMessage(on: true)
        let original = try RemoteMessage(type: .setPower, content: payload)
        let encoded = try encodeMessage(original)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .setPower)
        let decodedPayload = try decoded.decode(SetPowerMessage.self)
        XCTAssertEqual(decodedPayload.on, true)
    }
    
    func testSetBrightnessMessageRoundTrip() throws {
        let payload = SetBrightnessMessage(brightness: 0.75)
        let original = try RemoteMessage(type: .setBrightness, content: payload)
        let encoded = try encodeMessage(original)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .setBrightness)
        let decodedPayload = try decoded.decode(SetBrightnessMessage.self)
        XCTAssertEqual(decodedPayload.brightness, 0.75, accuracy: 0.0001)
    }
    
    func testMouseMoveMessageRoundTrip() throws {
        let payload = MouseMoveMessage(deltaX: 10.5, deltaY: -20.3)
        let original = try RemoteMessage(type: .mouseMove, content: payload)
        let encoded = try encodeMessage(original)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .mouseMove)
        let decodedPayload = try decoded.decode(MouseMoveMessage.self)
        XCTAssertEqual(decodedPayload.deltaX, 10.5, accuracy: 0.0001)
        XCTAssertEqual(decodedPayload.deltaY, -20.3, accuracy: 0.0001)
    }

    func testMouseButtonClickCountIsOptional() throws {
        let legacy = try RemoteMessage(type: .mouseDown, content: MouseButtonMessage(button: 0))
        let decodedLegacy = try decodeMessage(from: try encodeMessage(legacy)).0.decode(MouseButtonMessage.self)
        XCTAssertNil(decodedLegacy.clickCount)

        let double = try RemoteMessage(type: .mouseDown, content: MouseButtonMessage(button: 0, clickCount: 2))
        let decodedDouble = try decodeMessage(from: try encodeMessage(double)).0.decode(MouseButtonMessage.self)
        XCTAssertEqual(decodedDouble.clickCount, 2)
    }
    
    func testMultipleMessagesInStream() throws {
        var stream = Data()
        stream.append(try encodeMessage(RemoteMessage(type: .ping)))
        stream.append(try encodeMessage(RemoteMessage(type: .pong)))
        
        let (msg1, consumed1) = try decodeMessage(from: stream)
        stream.removeFirst(consumed1)
        let (msg2, _) = try decodeMessage(from: stream)
        
        XCTAssertEqual(msg1.type, .ping)
        XCTAssertEqual(msg2.type, .pong)
    }
    
    func testLengthPrefixIsBigEndian() throws {
        let msg = RemoteMessage(type: .ping)
        let encoded = try encodeMessage(msg)

        // Big-endian 4-byte length prefix: for a small message the top 3 bytes are 0
        // and the LSB equals the actual payload length.
        XCTAssertEqual(encoded[0], 0)
        XCTAssertEqual(encoded[1], 0)
        XCTAssertEqual(encoded[2], 0)
        let payloadLength = Int(encoded[3])
        XCTAssertGreaterThan(payloadLength, 0, "Length byte must be non-zero")
        XCTAssertEqual(encoded.count, payloadLength + 4,
                       "Total frame size must equal 4-byte prefix + payload length")
    }
    
    func testIncompleteMessageThrows() {
        // Only 2 bytes of the 4-byte length prefix
        let incomplete = Data([0x00, 0x00])
        XCTAssertThrowsError(try decodeMessage(from: incomplete))
    }
    
    func testHelloMessageRoundTrip() throws {
        let payload = HelloMessage(deviceName: "Test iPhone", deviceType: "iOS")
        let original = try RemoteMessage(type: .hello, content: payload)
        let encoded = try encodeMessage(original)
        let (decoded, _) = try decodeMessage(from: encoded)
        
        XCTAssertEqual(decoded.type, .hello)
        let decodedPayload = try decoded.decode(HelloMessage.self)
        XCTAssertEqual(decodedPayload.deviceName, "Test iPhone")
        XCTAssertEqual(decodedPayload.deviceType, "iOS")
        XCTAssertEqual(decodedPayload.protocolVersion, kLightStarProtocolVersion)
    }
    
    func testLightStarStateEquatable() {
        let state1 = LightStarState(
            isConnected: true, isOn: true, brightness: 0.8,
            colorHue: 0.5, colorSaturation: 0.7, colorTemperature: 4000,
            syncMode: "video"
        )
        let state2 = LightStarState(
            isConnected: true, isOn: true, brightness: 0.8,
            colorHue: 0.5, colorSaturation: 0.7, colorTemperature: 4000,
            syncMode: "video"
        )
        let state3 = LightStarState(
            isConnected: true, isOn: false, brightness: 0.8,
            colorHue: 0.5, colorSaturation: 0.7, colorTemperature: 4000,
            syncMode: "video"
        )
        
        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }

    func testMacTrackpadPrefsRoundTrip() throws {
        let prefs = MacTrackpadPrefs(
            tapToClick: true,
            twoFingerSecondaryClick: true,
            threeFingerDrag: false,
            naturalScrolling: true,
            pointerSpeed: 1.2,
            doubleClickThreshold: 0.5
        )
        let state = LightStarState(
            isConnected: true, isOn: true, brightness: 1,
            colorHue: 0.1, colorSaturation: 0.9, colorTemperature: 0.5,
            syncMode: "Off",
            trackpad: prefs
        )
        let message = try RemoteMessage(type: .stateUpdate, content: state)
        let decoded = try message.decode(LightStarState.self)
        XCTAssertEqual(decoded.trackpad, prefs)
    }

    func testMacActionMessageRoundTrip() throws {
        let message = try RemoteMessage(type: .macAction, content: MacActionMessage(action: .missionControl))
        XCTAssertEqual(message.type, .macAction)
        XCTAssertEqual(message.type.rawValue, 0x39)
        let decoded = try message.decode(MacActionMessage.self)
        XCTAssertEqual(decoded.action, .missionControl)
    }

    func testRemoteScrollMappingMatchesMacTrackpad() {
        let natural = RemoteScrollMapping.eventDeltas(fingerDeltaX: 3, fingerDeltaY: -10, naturalScrolling: true)
        XCTAssertEqual(natural.x, 3)
        XCTAssertEqual(natural.y, -10)

        let traditional = RemoteScrollMapping.eventDeltas(fingerDeltaX: 3, fingerDeltaY: -10, naturalScrolling: false)
        XCTAssertEqual(traditional.x, -3)
        XCTAssertEqual(traditional.y, 10)
    }

    func testGyroPointerDeadzoneAndSigns() {
        let wrap = GyroPointerMath.shortestAngle(0.9 * Double.pi, -0.9 * Double.pi)
        XCTAssertEqual(wrap, -0.2 * Double.pi, accuracy: 0.0001)

        let rest = GyroPointerMath.targetOffset(
            yaw: 0.01, pitch: 0.01, originYaw: 0, originPitch: 0, sensitivity: 1
        )
        XCTAssertEqual(rest.x, 0)
        XCTAssertEqual(rest.y, 0)

        let yawRight = GyroPointerMath.targetOffset(
            yaw: -0.2, pitch: 0, originYaw: 0, originPitch: 0, sensitivity: 1
        )
        XCTAssertGreaterThan(yawRight.x, 0)

        let pitchAimHigher = GyroPointerMath.targetOffset(
            yaw: 0, pitch: -0.2, originYaw: 0, originPitch: 0, sensitivity: 1
        )
        XCTAssertGreaterThan(pitchAimHigher.y, 0)

        let delta = GyroPointerMath.sampleDelta(targetX: 400, targetY: 0, lastX: 0, lastY: 0)
        XCTAssertEqual(delta.dx, GyroPointerMath.maxPixelsPerSample)
        XCTAssertEqual(delta.dy, 0)

        XCTAssertTrue(GyroPointerMath.isParked(pitch: 0.1, rotationRate: 0.01))
        XCTAssertFalse(GyroPointerMath.isParked(pitch: 0.9, rotationRate: 0.01))

        let turned = GyroPointerMath.incrementalDelta(
            yaw: -0.2, pitch: 0, lastYaw: 0, lastPitch: 0, sensitivity: 1,
            accelerationEnabled: false
        )
        XCTAssertGreaterThan(turned.dx, 0)

        let still = GyroPointerMath.rateDelta(
            rateX: 0.01, rateY: 0, rateZ: 0.01, dt: 0.008, sensitivity: 1
        )
        XCTAssertEqual(still.dx, 0)
        XCTAssertEqual(still.dy, 0)
        let flick = GyroPointerMath.rateDelta(
            rateX: -1.2, rateY: 0, rateZ: -1.2, dt: 0.008, sensitivity: 1,
            accelerationEnabled: false
        )
        XCTAssertGreaterThan(flick.dx, 0)
        XCTAssertGreaterThan(flick.dy, 0)

        let slow = GyroPointerMath.incrementalDelta(
            yaw: -0.002, pitch: 0, lastYaw: 0, lastPitch: 0, sensitivity: 1,
            dt: 1.0 / 120.0, accelerationEnabled: true
        )
        let fast = GyroPointerMath.incrementalDelta(
            yaw: -0.04, pitch: 0, lastYaw: 0, lastPitch: 0, sensitivity: 1,
            dt: 1.0 / 120.0, accelerationEnabled: true
        )
        XCTAssertGreaterThan(abs(fast.dx) / 0.04, abs(slow.dx) / 0.002)

        let slowTrack = RemotePointerAcceleration.factor(pixelsPerSecond: 40, enabled: true, scaling: 2)
        let fastTrack = RemotePointerAcceleration.factor(pixelsPerSecond: 800, enabled: true, scaling: 2)
        XCTAssertEqual(slowTrack, 1.04, accuracy: 0.02)
        XCTAssertGreaterThan(fastTrack, slowTrack * 2)
        XCTAssertEqual(
            RemotePointerAcceleration.factor(pixelsPerSecond: 40, enabled: false, scaling: 2),
            1.04,
            accuracy: 0.02
        )
        XCTAssertGreaterThan(
            RemotePointerAcceleration.gyroFactor(radiansPerSecond: 3.0, enabled: true),
            RemotePointerAcceleration.gyroFactor(radiansPerSecond: 0.1, enabled: true)
        )

        XCTAssertEqual(RemoteTrackpadSwipe.from(dx: -90, dy: 10), .left)
        XCTAssertEqual(RemoteTrackpadSwipe.from(dx: -90, dy: 10)?.macAction, .spaceRight)
        XCTAssertEqual(RemoteTrackpadSwipe.from(dx: 12, dy: -80), .up)
        XCTAssertEqual(RemoteTrackpadSwipe.from(dx: 12, dy: -80)?.macAction, .missionControl)
        XCTAssertNil(RemoteTrackpadSwipe.from(dx: 20, dy: -20))

        let portrait = RemotePointerOrientation.portrait.mapPointer(dx: 10, dy: 4)
        XCTAssertEqual(portrait.0, 10)
        XCTAssertEqual(portrait.1, 4)
        let left = RemotePointerOrientation.landscapeLeft.mapPointer(dx: 10, dy: 4)
        XCTAssertEqual(left.0, 4)
        XCTAssertEqual(left.1, -10)
        let right = RemotePointerOrientation.landscapeRight.mapPointer(dx: 10, dy: 4)
        XCTAssertEqual(right.0, -4)
        XCTAssertEqual(right.1, 10)

        let yaw = 0.2
        let portraitAim = RemotePointerOrientation.portrait.aimingDelta(dYaw: yaw, dPitch: 0, dRoll: 0)
        let landRightAim = RemotePointerOrientation.landscapeRight.aimingDelta(dYaw: yaw, dPitch: 0, dRoll: 0)
        let landLeftAim = RemotePointerOrientation.landscapeLeft.aimingDelta(dYaw: yaw, dPitch: 0, dRoll: 0)
        XCTAssertEqual(portraitAim.0, landRightAim.0, accuracy: 0.0001)
        XCTAssertEqual(portraitAim.0, landLeftAim.0, accuracy: 0.0001)
        XCTAssertEqual(landRightAim.1, 0, accuracy: 0.0001)
        XCTAssertEqual(
            RemotePointerOrientation.landscapeRight.aimingDelta(dYaw: 0, dPitch: 0.4, dRoll: -0.3).1,
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RemotePointerOrientation.landscapeLeft.aimingDelta(dYaw: 0, dPitch: 0.4, dRoll: 0.3).1,
            0.3,
            accuracy: 0.0001
        )

        var acc = 0.0
        XCTAssertEqual(RemotePixelQueue.takeInteger(from: &acc, adding: 0.4), 0)
        XCTAssertEqual(RemotePixelQueue.takeInteger(from: &acc, adding: 0.4), 0)
        XCTAssertEqual(RemotePixelQueue.takeInteger(from: &acc, adding: 0.4), 1)
        XCTAssertEqual(acc, 0.2, accuracy: 0.0001)
        var neg = 0.0
        XCTAssertEqual(RemotePixelQueue.takeInteger(from: &neg, adding: -1.6), -1)
        XCTAssertEqual(neg, -0.6, accuracy: 0.0001)
    }

    func testRemoteDisplayGeometryCentersCurrentScreen() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let side = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let onSide = RemoteDisplayGeometry.bounds(
            containing: CGPoint(x: 2100, y: 200),
            among: [main, side]
        )
        XCTAssertEqual(onSide, side)
        XCTAssertEqual(RemoteDisplayGeometry.center(of: side), CGPoint(x: 3200, y: 720))

        let onMain = RemoteDisplayGeometry.bounds(
            containing: CGPoint(x: 100, y: 100),
            among: [main, side]
        )
        XCTAssertEqual(onMain, main)
        XCTAssertEqual(RemoteDisplayGeometry.center(of: main), CGPoint(x: 960, y: 540))
    }
    
    func testAllMessageTypesHaveDistinctRawValues() {
        let types: [RemoteMessageType] = [
            .hello, .helloAck, .pair, .pairAck, .ping, .pong, .disconnect,
            .getState, .stateUpdate,
            .setPower, .setBrightness, .setColor, .setColorTemperature,
            .setEffect, .setEffectSpeed, .setEffectDirection, .setSyncMode, .selectDisplay,
            .connectStrip, .disconnectStrip, .writeFrame,
            .mouseMove, .mouseDown, .mouseUp, .rightClick, .scroll,
            .keyDown, .keyUp, .textInput, .mediaKey, .macAction,
            .getDiagnostics, .diagnosticsUpdate,
            .error
        ]
        
        var seen = Set<UInt8>()
        for type in types {
            XCTAssertFalse(seen.contains(type.rawValue), "Duplicate raw value: \(type.rawValue)")
            seen.insert(type.rawValue)
        }
    }
}

final class PairingCodeFormatTests: XCTestCase {
    func testPairingAlphabetMatchesGeneratedLengthAndExcludesAmbiguousChars() {
        XCTAssertEqual(kLightStarPairingCodeLength, 6)
        XCTAssertEqual(kLightStarPairingCodeAlphabet.count, 32)
        XCTAssertFalse(kLightStarPairingCodeAlphabet.contains("0"))
        XCTAssertFalse(kLightStarPairingCodeAlphabet.contains("1"))
        XCTAssertFalse(kLightStarPairingCodeAlphabet.contains("I"))
        XCTAssertFalse(kLightStarPairingCodeAlphabet.contains("O"))
        let unique = Set(kLightStarPairingCodeAlphabet)
        XCTAssertEqual(unique.count, kLightStarPairingCodeAlphabet.count)
    }
}

#if os(macOS)
@MainActor
final class PairingCodeGenerationTests: XCTestCase {
    func testGeneratedPairingCodeMatchesProtocolAlphabet() {
        let server = RemoteControlServer()
        let allowed = CharacterSet(charactersIn: kLightStarPairingCodeAlphabet)
        let forbidden = CharacterSet(charactersIn: "01IO")
        for _ in 0..<20 {
            let code = server.generatePairingCode()
            XCTAssertEqual(code.count, kLightStarPairingCodeLength)
            XCTAssertEqual(server.activePairingCode, code)
            XCTAssertTrue(code.unicodeScalars.allSatisfy { allowed.contains($0) })
            XCTAssertNil(code.rangeOfCharacter(from: forbidden))
        }
    }

    func testStopClearsActivePairingCode() {
        let server = RemoteControlServer()
        XCTAssertNotNil(server.generatePairingCode())
        XCTAssertNotNil(server.activePairingCode)
        server.stop()
        XCTAssertNil(server.activePairingCode)
    }
}
#endif

final class ReceiveBufferOverflowTests: XCTestCase {
    func testEqualToMaxIsAllowed() {
        XCTAssertFalse(receiveBufferWouldOverflow(
            currentCount: kLightStarMaxReceiveBufferBytes - 10,
            incomingCount: 10
        ))
        XCTAssertFalse(receiveBufferWouldOverflow(
            currentCount: 0,
            incomingCount: kLightStarMaxReceiveBufferBytes
        ))
    }

    func testOneBytePastMaxIsRejected() {
        XCTAssertTrue(receiveBufferWouldOverflow(
            currentCount: kLightStarMaxReceiveBufferBytes,
            incomingCount: 1
        ))
        XCTAssertTrue(receiveBufferWouldOverflow(
            currentCount: kLightStarMaxReceiveBufferBytes - 10,
            incomingCount: 11
        ))
    }
}

final class ConnectAndSchedulePolicyTests: XCTestCase {
    func testDefaultPresetYieldsToPendingScheduleAndPowerOff() {
        XCTAssertTrue(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: false, pendingScheduleCount: 0
        ))
        XCTAssertFalse(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: false, pendingScheduleCount: 1
        ))
        XCTAssertFalse(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: false, isSyncing: false, pendingScheduleCount: 0
        ))
        XCTAssertFalse(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: true, pendingScheduleCount: 0
        ))
        XCTAssertFalse(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: false, pendingScheduleCount: 0, hasSyncToRestore: true
        ))
        XCTAssertTrue(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: false, pendingScheduleCount: 0, hasSyncToRestore: false
        ))
    }

    func testConnectInitDoesNotRestoreAppearanceWhenOff() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldRestoreAppearanceOnConnect(targetOn: true))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldRestoreAppearanceOnConnect(targetOn: false))
    }

    func testMultiLightKeepsScanningAfterPrimary() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldStopScanOnPrimaryDiscovery(multiLightEnabled: false))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldStopScanOnPrimaryDiscovery(multiLightEnabled: true))
    }

    func testExtraLightFailureDoesNotReconnectPrimary() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldReconnectPrimaryAfterConnectFailure(failedIsPrimary: true))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldReconnectPrimaryAfterConnectFailure(failedIsPrimary: false))
    }

    func testConnectSequenceStartsOnlyWhenWriteCharIsFirstFound() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldStartConnectSequence(writeCharAlreadyReady: false))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldStartConnectSequence(writeCharAlreadyReady: true))
    }

    func testFirmwareTimersDisableUnusedSlots() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 5
        comps.hour = 23; comps.minute = 30
        let time = cal.date(from: comps)!
        let bedtime = LightSchedule(
            label: "Bed",
            time: time,
            days: [2],
            action: .powerOff,
            useFirmwareTimer: true
        )
        let ignored = LightSchedule(
            label: "Mac only",
            time: time,
            days: [2],
            action: .powerOn,
            useFirmwareTimer: false
        )
        let frames = FirmwareTimerSync.frames(for: [bedtime, ignored], calendar: cal)
        XCTAssertEqual(frames.count, Int(Cmd.weeklyTimerSlotCount))
        XCTAssertEqual(frames[0][3], 1, "first firmware schedule occupies slot 1")
        XCTAssertEqual(frames[0][4], 0, "powerOff")
        XCTAssertEqual(frames[0][5], 1, "enabled")
        XCTAssertEqual(frames[0][7], 23)
        XCTAssertEqual(frames[0][8], 30)
        XCTAssertEqual(frames[1][3], 2)
        XCTAssertEqual(frames[1][5], 0, "unused slot must be disabled")
        XCTAssertEqual(frames.last?[3], Cmd.weeklyTimerSlotCount)
        XCTAssertEqual(frames.last?[5], 0)
    }

    func testFirmwareTimerCapClearsWhenNoneRemain() {
        let frames = FirmwareTimerSync.frames(for: [])
        XCTAssertEqual(frames.count, Int(Cmd.weeklyTimerSlotCount))
        XCTAssertTrue(frames.allSatisfy { $0[5] == 0 })
    }

    func testTransportClosePreservesPairingError() {
        let failed = RemoteClientSessionPolicy.stateAfterTransportClose(
            current: .error("Pairing failed")
        )
        XCTAssertEqual(failed, .error("Pairing failed"))
        XCTAssertEqual(
            RemoteClientSessionPolicy.stateAfterTransportClose(current: .authenticating),
            .disconnected
        )
        XCTAssertEqual(
            RemoteClientSessionPolicy.stateAfterTransportClose(current: .connected("Mac")),
            .disconnected
        )
    }

    func testPointerDeltaSaturationUsesInt16Range() {
        XCTAssertEqual(pointerDeltaToInt16(.greatestFiniteMagnitude), .max)
        XCTAssertEqual(pointerDeltaToInt16(-.greatestFiniteMagnitude), .min)
        XCTAssertEqual(pointerDeltaToInt16(.infinity), 0)
        XCTAssertEqual(pointerDeltaToInt16(.nan), 0)
    }

    func testHideKeyboardDoesNotEmitDeletesForLocalBufferReset() {
        XCTAssertFalse(RemoteTypingDelta.shouldEmit(forLocalBufferReset: true))
        XCTAssertTrue(RemoteTypingDelta.shouldEmit(forLocalBufferReset: false))
        XCTAssertEqual(RemoteTypingDelta.from(oldValue: "hello", newValue: ""), .delete(5))
        XCTAssertEqual(RemoteTypingDelta.from(oldValue: "hel", newValue: "hello"), .insert("lo"))
        XCTAssertEqual(RemoteTypingDelta.from(oldValue: "abc", newValue: "xyz"), .replace(delete: 3, insert: "xyz"))
        XCTAssertEqual(RemoteTypingDelta.from(oldValue: "a", newValue: "a"), .none)
    }

    func testClickDragKeepsPointerWhenExtraFingerLands() {
        XCTAssertEqual(RemoteTrackpadMoveKind.kind(fingerCount: 1, isClickDrag: false), .pointer)
        XCTAssertEqual(RemoteTrackpadMoveKind.kind(fingerCount: 2, isClickDrag: false), .scroll)
        XCTAssertEqual(RemoteTrackpadMoveKind.kind(fingerCount: 2, isClickDrag: true), .pointer)
        XCTAssertEqual(RemoteTrackpadMoveKind.kind(fingerCount: 3, isClickDrag: true), .pointer)
        XCTAssertEqual(RemoteTrackpadMoveKind.kind(fingerCount: 3, isClickDrag: false), .threeFinger)
    }

    func testConnectStripDoesNotDisconnectWhenAlreadyIdle() {
        XCTAssertFalse(StripReconnectPolicy.shouldDisconnectBeforeReconnect(.connected))
        XCTAssertFalse(StripReconnectPolicy.shouldDisconnectBeforeReconnect(.disconnected))
        XCTAssertTrue(StripReconnectPolicy.shouldDisconnectBeforeReconnect(.scanning))
        XCTAssertTrue(StripReconnectPolicy.shouldDisconnectBeforeReconnect(.connecting))
    }

    func testExtraLightsRequirePrimaryConnected() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight(
            multiLightEnabled: true, primaryConnectionState: .connected
        ))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight(
            multiLightEnabled: true, primaryConnectionState: .disconnected
        ))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight(
            multiLightEnabled: true, primaryConnectionState: .connecting
        ))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight(
            multiLightEnabled: false, primaryConnectionState: .connected
        ))
        XCTAssertTrue(BLEDiscoveryPolicy.shouldAdoptAdvertisementAsPrimary(isAlreadyExtra: false))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldAdoptAdvertisementAsPrimary(isAlreadyExtra: true))
    }

    func testStalePrimaryPeripheralDoesNotSwallowRediscoveryWhileDisconnected() {
        XCTAssertFalse(BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
            hasPrimaryPeripheral: true, primaryConnectionState: .disconnected
        ))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
            hasPrimaryPeripheral: true, primaryConnectionState: .scanning
        ))
        XCTAssertTrue(BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
            hasPrimaryPeripheral: true, primaryConnectionState: .connecting
        ))
        XCTAssertTrue(BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
            hasPrimaryPeripheral: true, primaryConnectionState: .connected
        ))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldIgnoreNonPrimaryAdvertisement(
            hasPrimaryPeripheral: false, primaryConnectionState: .connected
        ))
    }

    func testMultiLightToggleScanFollowsPrimaryConnection() {
        XCTAssertTrue(BLEDiscoveryPolicy.shouldStopScanWhenDisablingMultiLight(connectionState: .connected))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldStopScanWhenDisablingMultiLight(connectionState: .scanning))
        XCTAssertTrue(BLEDiscoveryPolicy.shouldStartExtraScanWhenEnablingMultiLight(connectionState: .connected))
        XCTAssertFalse(BLEDiscoveryPolicy.shouldStartExtraScanWhenEnablingMultiLight(connectionState: .disconnected))
    }

    func testWakeDoesNotReconnectAfterUserDisconnect() {
        XCTAssertTrue(WakeReconnectPolicy.shouldReconnect(
            autoConnect: true, connectionState: .disconnected, userInitiatedDisconnect: false
        ))
        XCTAssertFalse(WakeReconnectPolicy.shouldReconnect(
            autoConnect: true, connectionState: .disconnected, userInitiatedDisconnect: true
        ))
        XCTAssertFalse(WakeReconnectPolicy.shouldReconnect(
            autoConnect: false, connectionState: .disconnected, userInitiatedDisconnect: false
        ))
        XCTAssertFalse(WakeReconnectPolicy.shouldReconnect(
            autoConnect: true, connectionState: .connected, userInitiatedDisconnect: false
        ))
    }

    func testLastSyncModePersistsWhenTurningSyncOff() {
        XCTAssertEqual(
            SyncModePersistence.lastSyncModeToPersist(previous: .video, next: .off),
            .video
        )
        XCTAssertEqual(
            SyncModePersistence.lastSyncModeToPersist(previous: .audio, next: .off),
            .audio
        )
        XCTAssertNil(SyncModePersistence.lastSyncModeToPersist(previous: .off, next: .off))
        XCTAssertNil(SyncModePersistence.lastSyncModeToPersist(previous: .video, next: .audio))
        XCTAssertFalse(SyncReconnectPolicy.restoreFlagAfterUserTurnsSyncOff())
        XCTAssertTrue(SyncReconnectPolicy.restoreFlagAfterSyncInterrupted(wasSyncing: true))
        XCTAssertFalse(SyncReconnectPolicy.restoreFlagAfterSyncInterrupted(wasSyncing: false))
        XCTAssertFalse(SyncReconnectPolicy.shouldRestoreSync(
            wasActiveAtDisconnect: false, lastSyncMode: .video
        ))
        XCTAssertTrue(SyncReconnectPolicy.shouldRestoreSync(
            wasActiveAtDisconnect: true, lastSyncMode: .video
        ))
        XCTAssertFalse(SyncReconnectPolicy.shouldRestoreSync(
            wasActiveAtDisconnect: true, lastSyncMode: .off
        ))
        XCTAssertFalse(ConnectAppearancePolicy.shouldApplyDefaultPreset(
            isOn: true, isSyncing: false, pendingScheduleCount: 0, hasSyncToRestore: true
        ))
    }

    func testStaleRemoteCallbacksAreIgnored() {
        XCTAssertTrue(RemoteClientSessionPolicy.shouldHandleCallback(
            callbackGeneration: 3, currentGeneration: 3
        ))
        XCTAssertFalse(RemoteClientSessionPolicy.shouldHandleCallback(
            callbackGeneration: 2, currentGeneration: 3
        ))
    }

    func testStripSnapshotRequiresUserIntent() {
        XCTAssertTrue(RemoteStripSnapshotPolicy.shouldApplyConnectionFromSnapshot(
            wantsMacStripConnection: true
        ))
        XCTAssertFalse(RemoteStripSnapshotPolicy.shouldApplyConnectionFromSnapshot(
            wantsMacStripConnection: false
        ))
    }

    func testPairingFieldClearsWhenLeavingPairing() {
        XCTAssertFalse(RemotePairingFieldPolicy.shouldClearLocalCode(for: .authenticating))
        XCTAssertTrue(RemotePairingFieldPolicy.shouldClearLocalCode(for: .disconnected))
        XCTAssertTrue(RemotePairingFieldPolicy.shouldClearLocalCode(for: .error("nope")))
        XCTAssertTrue(RemotePairingFieldPolicy.shouldClearLocalCode(for: .connected("Mac")))
    }

    func testPointerCleanupReleasesEveryHeldButton() {
        XCTAssertEqual(PointerButtonCleanup.buttonsToRelease(left: true, right: false, other: false), [0])
        XCTAssertEqual(PointerButtonCleanup.buttonsToRelease(left: false, right: true, other: true), [1, 2])
        XCTAssertEqual(PointerButtonCleanup.buttonsToRelease(left: true, right: true, other: true), [0, 1, 2])
        XCTAssertEqual(PointerButtonCleanup.buttonsToRelease(left: false, right: false, other: false), [])
    }

    func testLaunchAtLoginToggleFollowsServiceOnFailure() {
        XCTAssertTrue(LaunchAtLoginSync.displayedEnabled(
            requested: true, succeeded: true, currentlyEnabled: true
        ))
        XCTAssertFalse(LaunchAtLoginSync.displayedEnabled(
            requested: true, succeeded: false, currentlyEnabled: false
        ))
        XCTAssertTrue(LaunchAtLoginSync.displayedEnabled(
            requested: false, succeeded: false, currentlyEnabled: true
        ))
    }

    func testPendingScheduleStampRequiresApplyOrDurableQueue() {
        XCTAssertTrue(ScheduleFirePersistence.shouldStampLastFiredAt(applied: true, pendingPersisted: false))
        XCTAssertTrue(ScheduleFirePersistence.shouldStampLastFiredAt(applied: false, pendingPersisted: true))
        XCTAssertFalse(ScheduleFirePersistence.shouldStampLastFiredAt(applied: false, pendingPersisted: false))
    }

    func testPendingScheduleStoreRoundTripAndCap() throws {
        let original: [LightSchedule.ScheduledAction] = [.powerOn, .powerOff, .preset(colorHue: 0.2, colorSat: 0.8, brightness: 0.5)]
        let data = try PendingScheduleStore.encode(original)
        let decoded = try PendingScheduleStore.decode(data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(PendingScheduleStore.capped(original + original + original, cap: 2).count, 2)
    }

    func testUnauthenticatedPointerFramesAreConsumedNotInjected() {
        XCTAssertTrue(RemotePointerAuthPolicy.isPointerCommand(.mouseMove))
        XCTAssertTrue(RemotePointerAuthPolicy.isPointerCommand(.scroll))
        XCTAssertTrue(RemotePointerAuthPolicy.isPointerCommand(.mouseDown))
        XCTAssertFalse(RemotePointerAuthPolicy.isPointerCommand(.setPower))
        XCTAssertTrue(RemotePointerAuthPolicy.shouldConsumeUnauthenticatedPointerFrame(authenticated: false))
        XCTAssertFalse(RemotePointerAuthPolicy.shouldConsumeUnauthenticatedPointerFrame(authenticated: true))
        XCTAssertFalse(RemotePointerAuthPolicy.shouldInjectPointer(authenticated: false))
        XCTAssertTrue(RemotePointerAuthPolicy.shouldInjectPointer(authenticated: true))
    }

    func testSupersededCaptureStartIsNotAUserFacingError() {
        XCTAssertTrue(CaptureSessionPolicy.isSuperseded(startGeneration: 1, currentGeneration: 2))
        XCTAssertFalse(CaptureSessionPolicy.isSuperseded(startGeneration: 4, currentGeneration: 4))
        XCTAssertFalse(CaptureSessionPolicy.shouldSurfaceStartError(CancellationError()))
        XCTAssertTrue(CaptureSessionPolicy.shouldSurfaceStartError(
            NSError(domain: "ScreenCapture", code: 1)
        ))
        XCTAssertFalse(CaptureSessionPolicy.shouldStopSyncAfterResumeError(CancellationError()))
        XCTAssertTrue(CaptureSessionPolicy.shouldStopSyncAfterResumeError(
            NSError(domain: "ScreenCapture", code: -3801)
        ))
    }

    func testCombinedScreenCancellationContinuesWithoutAbortingAudio() {
        XCTAssertEqual(
            CaptureSessionPolicy.disposition(
                forStartError: CancellationError(), transitionCancelled: false
            ),
            .continueWithoutSampler
        )
        XCTAssertEqual(
            CaptureSessionPolicy.disposition(
                forStartError: CancellationError(), transitionCancelled: true
            ),
            .abortQuietTeardown
        )
        XCTAssertEqual(
            CaptureSessionPolicy.disposition(
                forStartError: NSError(domain: "ScreenCapture", code: -3801),
                transitionCancelled: false
            ),
            .surfaceFailure
        )
        XCTAssertTrue(CaptureSessionPolicy.samplerAvailable(
            callbackInstalled: false, startWasSuperseded: true
        ))
        XCTAssertFalse(CaptureSessionPolicy.samplerAvailable(
            callbackInstalled: false, startWasSuperseded: false
        ))
        XCTAssertEqual(
            CombinedSyncAssembly.resolvedMode(screenAvailable: true, audioAvailable: true),
            .combined
        )
        XCTAssertEqual(
            CombinedSyncAssembly.resolvedMode(screenAvailable: true, audioAvailable: false),
            .video
        )
        XCTAssertEqual(
            CombinedSyncAssembly.resolvedMode(screenAvailable: false, audioAvailable: true),
            .audio
        )
        // Pause during combined screen start: screen superseded + audio running stays combined
        // so display-wake resumeScreenSync still sees isSyncingVideo.
        let pausedScreenStillCombined = CombinedSyncAssembly.resolvedMode(
            screenAvailable: CaptureSessionPolicy.samplerAvailable(
                callbackInstalled: false, startWasSuperseded: true
            ),
            audioAvailable: true
        )
        XCTAssertEqual(pausedScreenStillCombined, .combined)
    }

    func testRemoteBroadcastThrottlesSyncColorOnlyChanges() {
        let a = RemoteStateBroadcastPolicy.significantIdentity(
            isConnected: true, isOn: true, syncMode: "Video", brightness: 1, effectID: nil
        )
        let b = RemoteStateBroadcastPolicy.significantIdentity(
            isConnected: true, isOn: true, syncMode: "Video", brightness: 1, effectID: nil
        )
        let powerOff = RemoteStateBroadcastPolicy.significantIdentity(
            isConnected: true, isOn: false, syncMode: "Video", brightness: 1, effectID: nil
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, powerOff)
        XCTAssertFalse(RemoteStateBroadcastPolicy.shouldBroadcast(
            identityChanged: false, now: 1.05, lastBroadcastAt: 1.0
        ))
        XCTAssertTrue(RemoteStateBroadcastPolicy.shouldBroadcast(
            identityChanged: false, now: 1.11, lastBroadcastAt: 1.0
        ))
        XCTAssertTrue(RemoteStateBroadcastPolicy.shouldBroadcast(
            identityChanged: true, now: 1.01, lastBroadcastAt: 1.0
        ))
    }
}
