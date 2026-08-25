import Foundation
import SwiftUI

struct LightSchedule: Codable, Identifiable {
    var id = UUID()
    var label: String
    var time: Date          // only hour+minute used; date component ignored
    var days: Set<Int>      // 1=Sun … 7=Sat (Calendar weekday)
    var isEnabled: Bool = true
    var action: ScheduledAction

    enum ScheduledAction: Codable {
        case powerOn
        case powerOff
        case preset(colorHue: Double, colorSat: Double, brightness: Double)
    }
}

@MainActor @Observable
final class ScheduleStore {
    var schedules: [LightSchedule] = []
    private var timers: [UUID: Timer] = [:]
    weak var ble: LightBLEManager?

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }

    init() { load() }

    func save() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        try? data.write(to: Self.storeURL)
        reschedule()
    }

    // Rebuild all NSTimer-based minute-check timers when schedules change.
    func reschedule() {
        timers.values.forEach { $0.invalidate() }
        timers = [:]
        for schedule in schedules where schedule.isEnabled {
            scheduleTimer(for: schedule)
        }
    }

    private func scheduleTimer(for schedule: LightSchedule) {
        // Fire once per minute; check if current time matches schedule
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkFire(schedule) }
        }
        // Align to the next minute boundary
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        comps.second = 0
        if let aligned = cal.date(from: comps)?.addingTimeInterval(60) {
            timer.fireDate = aligned
        }
        timers[schedule.id] = timer
    }

    private func checkFire(_ schedule: LightSchedule) {
        guard schedule.isEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        let nowComps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        let schedComps = cal.dateComponents([.hour, .minute], from: schedule.time)
        guard nowComps.hour == schedComps.hour,
              nowComps.minute == schedComps.minute,
              let weekday = nowComps.weekday,
              schedule.days.contains(weekday)
        else { return }
        fire(schedule)
    }

    private func fire(_ schedule: LightSchedule) {
        guard let ble, ble.connectionState == .connected else { return }
        switch schedule.action {
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

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([LightSchedule].self, from: data)
        else { return }
        schedules = decoded
    }
}
