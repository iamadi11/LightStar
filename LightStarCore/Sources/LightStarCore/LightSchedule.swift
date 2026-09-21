import Foundation
import SwiftUI

public struct LightSchedule: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var label: String
    public var time: Date          // only hour+minute used; date component ignored
    public var days: Set<Int>      // 1=Sun … 7=Sat (Calendar weekday)
    public var isEnabled: Bool = true
    public var action: ScheduledAction
    /// Optional so existing JSON still decodes. New schedules default to `.now`
    /// so a catch-up window cannot fire for a time that passed before creation.
    public var lastFiredAt: Date? = Date()
    /// When true, also push this schedule as a BC0D firmware timer (Mac asleep / out of range).
    public var useFirmwareTimer: Bool? = nil

    public enum ScheduledAction: Codable, Equatable {
        case powerOn
        case powerOff
        case preset(colorHue: Double, colorSat: Double, brightness: Double)
    }

    public init(
        id: UUID = UUID(),
        label: String,
        time: Date,
        days: Set<Int>,
        isEnabled: Bool = true,
        action: ScheduledAction,
        lastFiredAt: Date? = Date(),
        useFirmwareTimer: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.time = time
        self.days = days
        self.isEnabled = isEnabled
        self.action = action
        self.lastFiredAt = lastFiredAt
        self.useFirmwareTimer = useFirmwareTimer
    }

    public var firmwareTimerEnabled: Bool { useFirmwareTimer ?? false }

    /// Most recent scheduled instant at or before `now` that matches `days`.
    public func previousFireDate(onOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        guard !days.isEmpty else { return nil }
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        // Walk back up to 8 days so we always cover the previous matching weekday.
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard days.contains(weekday) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hm.hour
            comps.minute = hm.minute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { continue }
            if candidate <= now { return candidate }
        }
        return nil
    }

    public func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled, !days.isEmpty else { return nil }
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard days.contains(weekday) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hm.hour
            comps.minute = hm.minute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    /// Due if the last scheduled instant is within `catchUp` of `now` and we have
    /// not already fired for that instant. `lastFiredAt == nil` is treated as not
    /// due — creation and load both stamp `.now` so this only protects corrupt files.
    public func isDue(at now: Date, catchUp: TimeInterval = 15 * 60, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        guard let lastFiredAt else { return false }
        guard let scheduled = previousFireDate(onOrBefore: now, calendar: calendar) else { return false }
        if now.timeIntervalSince(scheduled) > catchUp { return false }
        return lastFiredAt < scheduled
    }
}

@MainActor @Observable
public final class ScheduleStore {
    public var schedules: [LightSchedule] = []
    public weak var ble: LightBLEManager?
    /// Actions that fired while disconnected; drained once on connect.
    public private(set) var pendingActions: [LightSchedule.ScheduledAction] = []
    public static let pendingCap = 8

    private var timer: Timer?

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }

    private static var pendingURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-actions.json")
    }

    public init() {
        load()
        armNextTimer()
    }

    public func save() {
        persist()
        reschedule()
        pushFirmwareTimers()
    }

    public func persist() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    public func reschedule() {
        timer?.invalidate()
        timer = nil
        armNextTimer()
    }

    public func fireDue(now: Date = .now) {
        var didFire = false
        for i in schedules.indices where schedules[i].isEnabled {
            guard schedules[i].isDue(at: now) else { continue }
            let appliedOrQueued = perform(schedules[i].action)
            if ScheduleFirePersistence.shouldStampLastFiredAt(
                applied: appliedOrQueued.applied,
                pendingPersisted: appliedOrQueued.pendingPersisted
            ) {
                schedules[i].lastFiredAt = now
                didFire = true
            }
        }
        if didFire { persist() }
        armNextTimer()
    }

    /// Returns how many queued actions were applied so connect-restore can
    /// skip the default preset when a schedule already chose the post-connect state.
    @discardableResult
    public func drainPendingActions() -> Int {
        let queued = pendingActions
        pendingActions.removeAll()
        persistPending()
        for action in queued { apply(action) }
        return queued.count
    }

    /// Test seam: enqueue as if a schedule fired while disconnected.
    public func enqueuePendingForTesting(_ action: LightSchedule.ScheduledAction) {
        if pendingActions.count < Self.pendingCap {
            pendingActions.append(action)
        }
    }

    private func armNextTimer() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        let next = schedules.compactMap { $0.nextFireDate(after: now) }.min()
        guard let next else { return }
        let interval = max(1, next.timeIntervalSince(now))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireDue() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func perform(_ action: LightSchedule.ScheduledAction) -> (applied: Bool, pendingPersisted: Bool) {
        guard let ble, ble.connectionState == .connected else {
            let persisted = enqueuePending(action)
            ble?.connect()
            return (false, persisted)
        }
        apply(action)
        return (true, false)
    }

    @discardableResult
    private func enqueuePending(_ action: LightSchedule.ScheduledAction) -> Bool {
        guard pendingActions.count < Self.pendingCap else { return false }
        pendingActions.append(action)
        return persistPending()
    }

    @discardableResult
    private func persistPending() -> Bool {
        guard let data = try? PendingScheduleStore.encode(pendingActions) else { return false }
        do {
            try data.write(to: Self.pendingURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func apply(_ action: LightSchedule.ScheduledAction) {
        guard let ble else { return }
        switch action {
        case .powerOn:
            ble.setPower(on: true)
        case .powerOff:
            ble.setPower(on: false)
        case .preset(let h, let s, let bri):
            if !ble.isOn { ble.setPower(on: true) }
            ble.setHue(h, saturation: s)
            ble.setBrightness(bri)
        }
    }

    public func pushFirmwareTimers() {
        guard let ble, ble.connectionState == .connected else { return }
        for frame in FirmwareTimerSync.frames(for: schedules) {
            ble.write(frame)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let decoded = try? JSONDecoder().decode([LightSchedule].self, from: data) {
            let now = Date()
            // Stamp missing lastFiredAt so a catch-up cannot fire for times that
            // passed before this install knew about the schedule.
            schedules = decoded.map { s in
                var copy = s
                if copy.lastFiredAt == nil { copy.lastFiredAt = now }
                return copy
            }
        }
        loadPending()
    }

    private func loadPending() {
        guard let data = try? Data(contentsOf: Self.pendingURL),
              let decoded = try? PendingScheduleStore.decode(data)
        else { return }
        pendingActions = PendingScheduleStore.capped(decoded, cap: Self.pendingCap)
    }
}

/// Default-preset restore after BLE connect. A queued schedule that caused the
/// reconnect, or a strip that should stay off, must win over the default look.
public enum ConnectAppearancePolicy: Sendable {
    public static func shouldApplyDefaultPreset(
        isOn: Bool,
        isSyncing: Bool,
        pendingScheduleCount: Int,
        hasSyncToRestore: Bool = false
    ) -> Bool {
        isOn && !isSyncing && pendingScheduleCount == 0 && !hasSyncToRestore
    }
}

/// Builds the full BC0D weekly-timer table, including disabled leftover slots.
public enum FirmwareTimerSync: Sendable {
    public static func frames(
        for schedules: [LightSchedule],
        calendar: Calendar = .current
    ) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var slot: UInt8 = 1
        for schedule in schedules where schedule.firmwareTimerEnabled {
            let hm = calendar.dateComponents([.hour, .minute], from: schedule.time)
            let hour = UInt8(hm.hour ?? 0)
            let minute = UInt8(hm.minute ?? 0)
            let powerOn: Bool
            switch schedule.action {
            case .powerOn, .preset: powerOn = true
            case .powerOff: powerOn = false
            }
            // Day byte is an OEM bitmask: bit0=Mon … bit6=Sun.
            var mask: UInt8 = 0
            for weekday in schedule.days {
                mask |= UInt8(1 << ((weekday + 5) % 7))
            }
            frames.append(Cmd.weeklyTimer(
                slot: slot,
                powerOn: powerOn,
                enabled: schedule.isEnabled,
                dayMask: mask,
                hour: hour,
                minute: minute
            ))
            slot &+= 1
            if slot > Cmd.weeklyTimerSlotCount { break }
        }
        while slot <= Cmd.weeklyTimerSlotCount {
            frames.append(Cmd.weeklyTimer(
                slot: slot,
                powerOn: false,
                enabled: false,
                dayMask: 0,
                hour: 0,
                minute: 0
            ))
            slot &+= 1
        }
        return frames
    }
}

/// lastFiredAt may be stamped when the action is applied, or when it is durably
/// queued for the next connect. Memory-only pending is not enough.
public enum ScheduleFirePersistence: Sendable {
    public static func shouldStampLastFiredAt(applied: Bool, pendingPersisted: Bool) -> Bool {
        applied || pendingPersisted
    }
}

public enum PendingScheduleStore: Sendable {
    public static func encode(_ actions: [LightSchedule.ScheduledAction]) throws -> Data {
        try JSONEncoder().encode(actions)
    }

    public static func decode(_ data: Data) throws -> [LightSchedule.ScheduledAction] {
        try JSONDecoder().decode([LightSchedule.ScheduledAction].self, from: data)
    }

    public static func capped(
        _ actions: [LightSchedule.ScheduledAction],
        cap: Int
    ) -> [LightSchedule.ScheduledAction] {
        Array(actions.prefix(cap))
    }
}
