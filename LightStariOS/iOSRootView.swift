import SwiftUI
import LightStarCore
import WidgetKit
import UIKit

struct iOSRootView: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        TabView {
            iOSControlTab()
                .tabItem { Label("Control", systemImage: "lightbulb.fill") }
            iOSEffectsTab()
                .tabItem { Label("Effects", systemImage: "sparkles") }
            iOSSyncTab()
                .tabItem { Label("Sync", systemImage: "waveform") }
            iOSMoreTab()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .onChange(of: ble.isOn) { _, _ in writeWidget() }
        .onChange(of: ble.connectionState) { _, _ in writeWidget() }
        .onChange(of: ble.color) { _, _ in writeWidget() }
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
}

// MARK: - Control

private struct iOSControlTab: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets
    @State private var hue: Double = 0
    @State private var sat: Double = 1
    @State private var saveName = ""
    @State private var showSave = false

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
                        HStack {
                            ProgressView()
                            Button("Cancel") { ble.disconnect() }
                        }
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
                        VStack(alignment: .leading) {
                            Text("Brightness \(Int(ble.brightness * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { ble.brightness },
                                set: { ble.setBrightness($0) }
                            ), in: 0...1)
                        }
                    }

                    Section("Color") {
                        ColorPicker("Picker", selection: Binding(
                            get: { ble.color },
                            set: { ble.setColor($0) }
                        ), supportsOpacity: false)
                        VStack(alignment: .leading) {
                            Text("Hue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $hue, in: 0...1)
                                .tint(Color(hue: hue, saturation: 1, brightness: 1))
                                .onChange(of: hue) { _, _ in ble.setHue(hue, saturation: sat) }
                        }
                        VStack(alignment: .leading) {
                            Text("Saturation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $sat, in: 0...1)
                                .onChange(of: sat) { _, _ in ble.setHue(hue, saturation: sat) }
                        }
                        if !ble.colorHistory.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(ble.colorHistory.prefix(12).enumerated()), id: \.offset) { _, entry in
                                        Circle()
                                            .fill(Color(hue: entry.h, saturation: entry.s, brightness: 1))
                                            .frame(width: 28, height: 28)
                                            .onTapGesture {
                                                hue = entry.h
                                                sat = entry.s
                                                ble.setHue(entry.h, saturation: entry.s)
                                            }
                                    }
                                }
                            }
                        }
                    }

                    Section("White") {
                        VStack(alignment: .leading) {
                            Text(cctLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { ble.colorTemperature },
                                set: { ble.setColorTemperature($0) }
                            ), in: 0...1)
                            .disabled(ble.circadianEnabled)
                        }
                        Toggle("Circadian auto-adjust", isOn: Binding(
                            get: { ble.circadianEnabled },
                            set: { ble.circadianEnabled = $0 }
                        ))
                    }

                    Section("Scenes") {
                        ForEach(presets.presets) { preset in
                            Button {
                                ble.apply(preset: preset)
                                syncFromBLE()
                            } label: {
                                HStack {
                                    Circle().fill(preset.color).frame(width: 14, height: 14)
                                    Text(preset.name)
                                    Spacer()
                                    if presets.defaultPresetID == preset.id {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                    }
                                }
                            }
                            .contextMenu {
                                Button(presets.defaultPresetID == preset.id ? "Clear Default" : "Set as Default on Connect") {
                                    presets.defaultPresetID = presets.defaultPresetID == preset.id ? nil : preset.id
                                }
                                Button("Delete", role: .destructive) {
                                    if presets.defaultPresetID == preset.id { presets.defaultPresetID = nil }
                                    presets.presets.removeAll { $0.id == preset.id }
                                    presets.save()
                                }
                            }
                        }
                        Button("Save current as scene…") { showSave = true }
                        if presets.presets.isEmpty {
                            Button("Restore Defaults") {
                                presets.presets = Preset.defaults
                                presets.save()
                            }
                        }
                    }
                }
            }
            .navigationTitle("LightStar")
            .onAppear { syncFromBLE() }
            .onChange(of: ble.color) { _, _ in syncFromBLE() }
            .alert("Save scene", isPresented: $showSave) {
                TextField("Name", text: $saveName)
                Button("Save") { saveCurrentPreset() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func syncFromBLE() {
        let (h, s, _) = ble.color.hsvComponents
        if s > 0.05 { hue = h; sat = s }
    }

    private func saveCurrentPreset() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(ble.color).getRed(&r, green: &g, blue: &b, alpha: &a)
        presets.presets.append(Preset(
            name: name,
            red: Double(r),
            green: Double(g),
            blue: Double(b),
            brightness: ble.brightness
        ))
        presets.save()
        saveName = ""
    }

    private var cctLabel: String {
        let k = Int(2700 + ble.colorTemperature * 3800)
        if ble.circadianEnabled { return "Circadian · \(k)K" }
        switch k {
        case ..<3200: return "Warm \(k)K"
        case ..<4500: return "Neutral \(k)K"
        default: return "Cool \(k)K"
        }
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

// MARK: - Effects

private struct iOSEffectsTab: View {
    @Environment(LightBLEManager.self) private var ble
    private static let validIDs: [UInt8] = (0x00...0xFF).compactMap { v in
        [0x3D, 0x5B, 0x96].contains(v) ? nil : UInt8(v)
    }
    @State private var sceneIndex: Double = 0

    var body: some View {
        NavigationStack {
            List {
                if ble.connectionState != .connected {
                    ContentUnavailableView("Connect first", systemImage: "lightbulb.slash")
                } else {
                    if ble.effectModeActive {
                        Section {
                            Button("Solid color") { ble.exitEffectMode() }
                            VStack(alignment: .leading) {
                                Text("Speed \(Int(ble.effectSpeed * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { ble.effectSpeed },
                                    set: { ble.setEffectSpeed($0) }
                                ), in: 0...1)
                            }
                            Toggle("Forward", isOn: Binding(
                                get: { ble.effectForward },
                                set: { ble.setEffectDirection(forward: $0) }
                            ))
                        }
                    }

                    ForEach(knownEffects, id: \.group.rawValue) { section in
                        Section(section.group.rawValue) {
                            ForEach(section.effects) { fx in
                                Button(fx.name) { ble.setEffect(id: fx.id) }
                                    .foregroundStyle(
                                        ble.effectModeActive && ble.effectID == fx.id ? Color.accentColor : .primary
                                    )
                            }
                        }
                    }

                    Section("Firmware animations") {
                        let currentID = Self.validIDs[min(Int(sceneIndex), Self.validIDs.count - 1)]
                        Text("Scene \(Int(sceneIndex) + 1)/\(Self.validIDs.count)  (0x\(String(format: "%02X", currentID)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $sceneIndex, in: 0...Double(Self.validIDs.count - 1), step: 1)
                            .onChange(of: sceneIndex) { _, _ in sendAnimation() }
                        HStack {
                            Button("Previous") {
                                sceneIndex = max(0, sceneIndex - 1)
                                sendAnimation()
                            }
                            Spacer()
                            Button("Random") {
                                sceneIndex = Double(Int.random(in: 0..<Self.validIDs.count))
                                sendAnimation()
                            }
                            Spacer()
                            Button("Next") {
                                sceneIndex = min(Double(Self.validIDs.count - 1), sceneIndex + 1)
                                sendAnimation()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Effects")
        }
    }

    private func sendAnimation() {
        let currentID = Self.validIDs[min(Int(sceneIndex), Self.validIDs.count - 1)]
        ble.setSyncMode(.off)
        ble.write(Cmd.animation(id: currentID))
    }
}

// MARK: - Sync (phone mic / strip mic — no screen capture on iOS)

private struct iOSSyncTab: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        NavigationStack {
            List {
                if ble.connectionState != .connected {
                    ContentUnavailableView("Connect first", systemImage: "lightbulb.slash")
                } else {
                    Section("Audio sync") {
                        Picker("Source", selection: Binding(
                            get: { ble.audioInputSource == .system ? .mic : ble.audioInputSource },
                            set: { ble.audioInputSource = $0 }
                        )) {
                            Text("Microphone").tag(LightBLEManager.AudioInputSource.mic)
                            Text("Strip Mic").tag(LightBLEManager.AudioInputSource.stripMic)
                        }
                        .pickerStyle(.segmented)

                        if ble.audioInputSource != .stripMic {
                            Picker("Style", selection: Binding(
                                get: { ble.audioSyncMode },
                                set: { ble.audioSyncMode = $0 }
                            )) {
                                ForEach(LightBLEManager.AudioSyncMode.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            Picker("Strip style", selection: Binding(
                                get: { ble.micStyle },
                                set: { ble.micStyle = $0 }
                            )) {
                                ForEach(LightBLEManager.MicStyle.allCases, id: \.self) {
                                    Text($0.label).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            VStack(alignment: .leading) {
                                Text("Sensitivity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { ble.micSensitivity },
                                    set: { ble.micSensitivity = $0 }
                                ), in: 0...1)
                            }
                        }

                        Button(ble.syncMode == .audio ? "Stop sync" : "Start audio sync") {
                            ble.setSyncMode(ble.syncMode == .audio ? .off : .audio)
                        }
                        .disabled(ble.syncTransitioning)

                        if ble.syncTransitioning {
                            ProgressView()
                        }
                        if let err = ble.syncError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Text(modeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sync")
            .onAppear {
                if ble.audioInputSource == .system {
                    ble.audioInputSource = .mic
                }
            }
        }
    }

    private var modeDescription: String {
        if ble.audioInputSource == .stripMic {
            return "The bar’s onboard mic drives color. No phone audio needed."
        }
        switch ble.audioSyncMode {
        case .rainbow: return "Beats shift hue · treble drifts · bass sets brightness."
        case .pulse: return "Bass pulses brightness and keeps the current color."
        case .frequency: return "Bass → red · mids → green · treble → blue."
        }
    }
}

// MARK: - More

private struct iOSMoreTab: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(ScheduleStore.self) private var schedules

    var body: some View {
        NavigationStack {
            List {
                Section("Strip") {
                    Picker("Channel order", selection: Binding(
                        get: { ble.ledChannelOrder },
                        set: { ble.ledChannelOrder = $0 }
                    )) {
                        ForEach(LightBLEManager.LEDChannelOrder.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    Stepper("LED count: \(ble.ledPixelCount)", value: Binding(
                        get: { ble.ledPixelCount },
                        set: { ble.ledPixelCount = $0 }
                    ), in: 8...300)
                    Toggle("Connect all nearby bars", isOn: Binding(
                        get: { ble.multiLightEnabled },
                        set: { ble.multiLightEnabled = $0 }
                    ))
                    if ble.multiLightEnabled && ble.connectedLightNames.count > 1 {
                        Text(ble.connectedLightNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Schedules") {
                    ForEach(schedules.schedules) { sched in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(sched.label).font(.headline)
                                Spacer()
                                if sched.firmwareTimerEnabled {
                                    Image(systemName: "cpu")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(sched.firmwareTimerEnabled ? "Firmware timer" : "App timer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                schedules.schedules.removeAll { $0.id == sched.id }
                                schedules.save()
                            }
                        }
                    }
                    NavigationLink("Add schedule") { iOSAddScheduleView() }
                }
            }
            .navigationTitle("More")
        }
    }
}

struct iOSAddScheduleView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(LightBLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var label = "Bedtime"
    @State private var time = Date()
    @State private var days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var actionType = 1
    @State private var firmware = true

    var body: some View {
        Form {
            TextField("Label", text: $label)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            Picker("Action", selection: $actionType) {
                Text("Power on").tag(0)
                Text("Power off").tag(1)
                Text("Current color").tag(2)
            }
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
                let action: LightSchedule.ScheduledAction
                switch actionType {
                case 0: action = .powerOn
                case 2:
                    let (h, s, _) = ble.color.hsvComponents
                    action = .preset(colorHue: h, colorSat: s, brightness: ble.brightness)
                default: action = .powerOff
                }
                store.schedules.append(LightSchedule(
                    label: label,
                    time: time,
                    days: days,
                    action: action,
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
