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
}

final class ColorMathTests: XCTestCase {
    func testHueLUTIsMonotonicNonDecreasing() {
        var last = -1.0
        for pair in ColorMath.hueLUT {
            XCTAssertGreaterThanOrEqual(pair.obs, last)
            last = pair.obs
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
        store.drainPendingActions()
        XCTAssertTrue(store.pendingActions.isEmpty)
        store.drainPendingActions()
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
