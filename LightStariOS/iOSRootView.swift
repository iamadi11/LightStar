import SwiftUI
import LightStarCore
import WidgetKit

struct iOSRootView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets
    @Environment(ScheduleStore.self) private var schedules

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Status") {
                        Text(statusText)
                            .foregroundStyle(ble.connectionError == nil ? .secondary : .red)
                    }
                    if ble.connectionState == .connected {
                        Button("Disconnect", role: .destructive) { ble.disconnect() }
                    } else if ble.connectionState == .scanning || ble.connectionState == .connecting {
                        Button("Cancel") { ble.disconnect() }
                    } else {
                        Button("Connect") { ble.connect() }
                    }
                }

                if ble.connectionState == .connected {
                    Section("Power") {
                        Toggle("Light", isOn: Binding(
                            get: { ble.isOn },
                            set: { ble.setPower(on: $0) }
                        ))
                        Slider(value: Binding(
                            get: { ble.brightness },
                            set: { ble.setBrightness($0) }
                        ), in: 0...1) {
                            Text("Brightness")
                        }
                    }

                    Section("Color") {
                        ColorPicker("Color", selection: Binding(
                            get: { ble.color },
                            set: { ble.setColor($0) }
                        ), supportsOpacity: false)
                        Button("Warm white") { ble.setColorTemperature(0) }
                        Button("Neutral") { ble.setColorTemperature(0.5) }
                        Button("Cool white") { ble.setColorTemperature(1) }
                    }

                    Section("Scenes") {
                        ForEach(presets.presets) { preset in
                            Button {
                                ble.apply(preset: preset)
                            } label: {
                                HStack {
                                    Circle().fill(preset.color).frame(width: 14, height: 14)
                                    Text(preset.name)
                                }
                            }
                        }
                    }

                    Section("Effects") {
                        ForEach(knownEffects, id: \.group.rawValue) { section in
                            DisclosureGroup(section.group.rawValue) {
                                ForEach(section.effects) { fx in
                                    Button(fx.name) { ble.setEffect(id: fx.id) }
                                }
                            }
                        }
                        if ble.effectModeActive {
                            Slider(value: Binding(
                                get: { ble.effectSpeed },
                                set: { ble.setEffectSpeed($0) }
                            ), in: 0...1) { Text("Speed") }
                            Button("Solid color") { ble.exitEffectMode() }
                        }
                    }

                    Section("Mic sync") {
                        Picker("Source", selection: Binding(
                            get: { ble.audioInputSource },
                            set: { ble.audioInputSource = $0 }
                        )) {
                            Text("Microphone").tag(LightBLEManager.AudioInputSource.mic)
                            Text("Strip Mic").tag(LightBLEManager.AudioInputSource.stripMic)
                        }
                        Button(ble.syncMode == .audio ? "Stop sync" : "Start audio sync") {
                            ble.setSyncMode(ble.syncMode == .audio ? .off : .audio)
                        }
                    }

                    Section("Schedules") {
                        ForEach(schedules.schedules) { sched in
                            VStack(alignment: .leading) {
                                Text(sched.label).font(.headline)
                                Text(sched.firmwareTimerEnabled ? "Firmware timer" : "App timer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        NavigationLink("Add schedule") { iOSAddScheduleView() }
                    }
                }
            }
            .navigationTitle("LightStar")
            .onChange(of: ble.isOn) { _, _ in writeWidget() }
            .onChange(of: ble.connectionState) { _, _ in writeWidget() }
            .onChange(of: ble.color) { _, _ in writeWidget() }
        }
    }

    private func writeWidget() {
        let (h, s, _) = ble.color.hsvComponents
        WidgetState(
            connected: ble.connectionState == .connected,
            isOn: ble.isOn,
            hue: h,
            saturation: s
        ).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "LightStarWidget")
    }

    private var statusText: String {
        if let err = ble.connectionError { return err }
        switch ble.connectionState {
        case .connected: return ble.isOn ? "Connected · On" : "Connected · Off"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }
}

struct iOSAddScheduleView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var label = "Bedtime"
    @State private var time = Date()
    @State private var days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var powerOn = false
    @State private var firmware = true

    var body: some View {
        Form {
            TextField("Label", text: $label)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            Toggle("Power on (otherwise off)", isOn: $powerOn)
            Toggle("Firmware timer (works with phone away)", isOn: $firmware)
            Section("Days") {
                ForEach([(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")], id: \.0) { item in
                    Toggle(item.1, isOn: Binding(
                        get: { days.contains(item.0) },
                        set: { on in if on { days.insert(item.0) } else { days.remove(item.0) } }
                    ))
                }
            }
            Button("Save") {
                store.schedules.append(LightSchedule(
                    label: label,
                    time: time,
                    days: days,
                    action: powerOn ? .powerOn : .powerOff,
                    lastFiredAt: .now,
                    useFirmwareTimer: firmware
                ))
                store.save()
                dismiss()
            }
            .disabled(days.isEmpty)
        }
        .navigationTitle("Add schedule")
    }
}
