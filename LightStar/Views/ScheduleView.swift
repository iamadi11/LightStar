import SwiftUI
import LightStarCore

struct ScheduleView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(LightBLEManager.self) private var ble
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Schedule", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).font(.caption).help("Add schedule")
            }

            if store.schedules.isEmpty {
                Text("No schedules — tap + to add")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(store.schedules) { sched in
                    ScheduleRow(schedule: sched)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddScheduleSheet()
        }
    }
}

private struct ScheduleRow: View {
    @Environment(ScheduleStore.self) private var store
    var schedule: LightSchedule

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { val in
                    if let idx = store.schedules.firstIndex(where: { $0.id == schedule.id }) {
                        store.schedules[idx].isEnabled = val
                        store.save()
                    }
                }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.label).font(.caption).lineLimit(1)
                Text("\(timeString) · \(daysString)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(actionLabel)
                .font(.caption2).foregroundStyle(.secondary)
            if schedule.firmwareTimerEnabled {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Firmware timer")
            }
            Button(role: .destructive) {
                store.schedules.removeAll { $0.id == schedule.id }
                store.save()
            } label: { Image(systemName: "trash").font(.caption2) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var timeString: String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: schedule.time)
    }

    private var daysString: String {
        let names = ["Su","Mo","Tu","We","Th","Fr","Sa"]
        if schedule.days.count == 7 { return "Every day" }
        let weekdays = Set([2,3,4,5,6])
        if schedule.days == weekdays { return "Weekdays" }
        if schedule.days == Set([1,7]) { return "Weekends" }
        return schedule.days.sorted().map { names[$0 - 1] }.joined(separator: ",")
    }

    private var actionLabel: String {
        switch schedule.action {
        case .powerOn:  return "On"
        case .powerOff: return "Off"
        case .preset:   return "Preset"
        }
    }
}

private struct AddScheduleSheet: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(LightBLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var days: Set<Int> = [2, 3, 4, 5, 6]   // Mon–Fri default
    @State private var actionType = 0   // 0=On, 1=Off, 2=Current color
    @State private var useFirmwareTimer = false

    private let dayLabels = [(1,"Su"),(2,"Mo"),(3,"Tu"),(4,"We"),(5,"Th"),(6,"Fr"),(7,"Sa")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Schedule").font(.headline)

            TextField("Label (e.g. Morning)", text: $label)
                .textFieldStyle(.roundedBorder)

            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text("Days").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(dayLabels, id: \.0) { (idx, name) in
                        let selected = days.contains(idx)
                        Button(name) {
                            if selected { days.remove(idx) } else { days.insert(idx) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(selected ? .accentColor : nil)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Action").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $actionType) {
                    Text("Power On").tag(0)
                    Text("Power Off").tag(1)
                    Text("Current Color").tag(2)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Firmware timer (works with Mac asleep)", isOn: $useFirmwareTimer)
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Pushes BC0D weekly timers to the strip so bedtime still works when this Mac is off.")

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(days.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    private func save() {
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? "Schedule" : label
        let action: LightSchedule.ScheduledAction
        switch actionType {
        case 1:  action = .powerOff
        case 2:
            let (h, s, _) = ble.color.hsvComponents
            action = .preset(colorHue: h, colorSat: s, brightness: ble.brightness)
        default: action = .powerOn
        }
        // lastFiredAt: .now — creating "08:00 weekdays" at 08:05 must not catch-up-fire.
        store.schedules.append(LightSchedule(
            label: name, time: time, days: days, action: action,
            lastFiredAt: .now, useFirmwareTimer: useFirmwareTimer
        ))
        store.save()
    }
}
