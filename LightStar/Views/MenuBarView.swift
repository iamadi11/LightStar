import SwiftUI
import LightStarCore
import AppKit
import AVFoundation
import ServiceManagement

struct MenuBarView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets
    @Environment(ScheduleStore.self) private var schedules
    @State private var selectedTab = 0
    @State private var showSaveSheet = false
    @State private var newPresetName = ""
    @State private var renamingPreset: Preset?
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoConnectOnLaunch") private var autoConnectOnLaunch = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            #if DEBUG
            HStack(spacing: 0) {
                tabButton("Control", index: 0)
                tabButton("Debug", index: 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            #endif

            ScrollView {
                #if DEBUG
                if selectedTab == 0 {
                    contentView
                } else {
                    DebugTabView()
                }
                #else
                contentView
                #endif
            }
            .animation(LightStarMotion.spring(reduceMotion), value: ble.connectionState)
            .animation(LightStarMotion.snappy(reduceMotion), value: ble.isOn)
        }
        .frame(width: 336)
        .tint(ble.stripAccent)
        .background {
            LightStarVisualEffect(material: .menu)
                .ignoresSafeArea()
        }
    }

    private var headerBar: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(ble.stripAccent)
                .frame(height: 3)
                .padding(.horizontal, 72)
                .animation(LightStarMotion.snappy(reduceMotion), value: ble.stripAccent)

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ble.stripAccent)
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("LightStar")
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(statusLineColor)
                }
                Spacer()
                Button {
                    openLightStarControlWindow()
                } label: {
                    Image(systemName: "macwindow")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Open LightStar window")
                .accessibilityLabel("Open LightStar window")
                Button {
                    openLightStarSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                connectionButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var contentView: some View {
        if ble.connectionState == .connected {
            controlsSection
                .transition(.opacity.combined(with: .offset(y: 6)))
        } else {
            statusSection
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    private var headerIcon: String {
        switch ble.connectionState {
        case .connected:   return ble.isOn ? "lightbulb.fill" : "lightbulb"
        case .scanning:    return "antenna.radiowaves.left.and.right"
        case .connecting:  return "antenna.radiowaves.left.and.right"
        case .disconnected: return "lightbulb.slash"
        }
    }

    private var statusLine: String {
        if let err = ble.connectionError { return err }
        switch ble.connectionState {
        case .connected:    return ble.isOn ? "Connected · On" : "Connected · Off"
        case .scanning:     return "Scanning for device…"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Not connected"
        }
    }

    private var statusLineColor: Color {
        if ble.connectionError != nil { return .red }
        switch ble.connectionState {
        case .connected:    return .green
        case .scanning, .connecting: return .accentColor
        case .disconnected: return .secondary
        }
    }

    private func tabButton(_ label: String, index: Int) -> some View {
        Button(label) { selectedTab = index }
            .buttonStyle(.plain)
            .font(.caption.weight(selectedTab == index ? .semibold : .regular))
            .foregroundStyle(selectedTab == index ? .primary : .secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == index ? Color.accentColor.opacity(0.15) : .clear)
            )
    }

    // MARK: - Sections

    private var statusSection: some View {
        VStack(spacing: 12) {
            if ble.connectionState == .scanning || ble.connectionState == .connecting {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 4)
                Text(stateLabel)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Button("Cancel") { ble.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Image(systemName: stateIcon)
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                if let err = ble.connectionError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No light bar connected")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                if ble.bleNeedsPermission {
                    Button("Open Bluetooth Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button("Connect to Light Bar") { ble.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var controlsSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { ble.isOn },
                    set: { ble.setPower(on: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                Text(ble.isOn ? "On" : "Off")
                    .frame(width: 24, alignment: .leading)
                    .contentTransition(.opacity)
                Spacer()
                Text("⌘⇧L")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Global shortcut: ⌘⇧L toggles power")
            }

            let live = StripCommandPolicy.canSendStripCommands(
                isConnected: true, isOn: ble.isOn
            )
            if !live {
                Text("Turn the light on to use color, presets, and sync.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ColorControlView()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Brightness", systemImage: "sun.max")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { ble.brightness },
                        set: { ble.setBrightness($0) }
                    ), in: 0...1)
                    .accessibilityLabel("Brightness")
                    .accessibilityValue("\(Int(ble.brightness * 100))%")
                }
            }
            .stripOutputEnabled(live)

            Divider().opacity(0.35)
            presetsBlock
                .stripOutputEnabled(live)
            Divider().opacity(0.35)
            SyncControlView()
                .stripOutputEnabled(live)
            Divider().opacity(0.35)
            HStack {
                Button("Open full controls") { openLightStarControlWindow() }
                    .buttonStyle(.plain)
                Spacer()
                Button("Settings") { openLightStarSettings() }
                    .buttonStyle(.plain)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 12)
    }

    private var presetsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Presets")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if presets.presets.isEmpty {
                        Button("Restore Defaults") {
                            presets.presets = Preset.defaults
                            presets.save()
                        }
                        .font(.subheadline)
                        .buttonStyle(.link)
                    }
                    Button {
                        newPresetName = "Custom"
                        showSaveSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Save current color as preset")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(presets.presets) { preset in
                        let isDefault = presets.defaultPresetID == preset.id
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 10, height: 10)
                                Text(preset.name)
                                    .lineLimit(1)
                                if isDefault {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .contextMenu {
                            Button(isDefault ? "Clear Default" : "Set as Default on Connect") {
                                presets.defaultPresetID = isDefault ? nil : preset.id
                            }
                            Divider()
                            Button("Rename…") {
                                renamingPreset = preset
                                newPresetName = preset.name
                            }
                            Button("Delete", role: .destructive) {
                                if isDefault { presets.defaultPresetID = nil }
                                presets.presets.removeAll { $0.id == preset.id }
                                presets.save()
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSaveSheet) {
                SavePresetSheet(name: $newPresetName) { name in
                    saveCurrentAsPreset(named: name)
                }
            }
            .sheet(item: $renamingPreset) { preset in
                SavePresetSheet(name: $newPresetName) { name in
                    if let idx = presets.presets.firstIndex(where: { $0.id == preset.id }) {
                        presets.presets[idx].name = name
                        presets.save()
                    }
                }
            }
    }

    private var stripAndAppPrefs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Strip Configuration", systemImage: "light.strip.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Channel order")
                    .font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { ble.ledChannelOrder },
                    set: { ble.ledChannelOrder = $0 }
                )) {
                    ForEach(LightBLEManager.LEDChannelOrder.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
                .controlSize(.small)
            }

            HStack {
                Text("LED count")
                    .font(.system(size: 11))
                Spacer()
                Stepper("\(ble.ledPixelCount)", value: Binding(
                    get: { ble.ledPixelCount },
                    set: { ble.ledPixelCount = $0 }
                ), in: 8...300)
                .font(.system(size: 11))
                .frame(width: 110)
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onAppear {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    let succeeded: Bool
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        succeeded = true
                    } catch {
                        succeeded = false
                    }
                    let next = LaunchAtLoginSync.displayedEnabled(
                        requested: enabled,
                        succeeded: succeeded,
                        currentlyEnabled: SMAppService.mainApp.status == .enabled
                    )
                    if next != launchAtLogin { launchAtLogin = next }
                }
            Toggle("Auto-connect on Launch", isOn: $autoConnectOnLaunch)
                .font(.caption)
                .toggleStyle(.checkbox)
            Toggle("Multi-light (connect all nearby bars)", isOn: Binding(
                get: { ble.multiLightEnabled },
                set: { ble.multiLightEnabled = $0 }
            ))
            .font(.caption)
            .toggleStyle(.checkbox)
            if ble.multiLightEnabled && ble.connectedLightNames.count > 1 {
                Text(ble.connectedLightNames.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if presets.iCloudAvailable {
                Toggle("Sync Presets via iCloud", isOn: Binding(
                    get: { presets.iCloudEnabled },
                    set: { presets.iCloudEnabled = $0 }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionButton: some View {
        Button {
            if ble.connectionState == .connected || ble.connectionState == .connecting || ble.connectionState == .scanning {
                ble.disconnect()
            } else {
                ble.connect()
            }
        } label: {
            Text(connectionButtonLabel)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(ble.connectionState == .connected ? .secondary : .primary)
    }

}

struct SyncControlView: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Sync", systemImage: "waveform.and.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let sc = ble.syncColor {
                    Circle()
                        .fill(sc)
                        .frame(width: 8, height: 8)
                        .transition(.opacity)
                }
                Text("⌘⇧S")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Global shortcut: ⌘⇧S toggles sync")
                if ble.syncTransitioning { ProgressView().controlSize(.mini) }
            }
            .animation(.snappy(duration: 0.22), value: ble.syncColor != nil)

            Picker("", selection: Binding(
                get: { ble.syncMode },
                set: { ble.setSyncMode($0) }
            )) {
                ForEach(LightBLEManager.SyncMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .disabled(ble.syncTransitioning)

            if let err = ble.syncError {
                // Show fatal error only when fully failed (.off); partial failures
                // (e.g. audio failed but video is running) show as a warning instead.
                Text(err)
                    .font(.system(size: 9))
                    .foregroundStyle(ble.syncMode == .off ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                if ble.syncNeedsPermission {
                    let isMicError = ble.syncError?.contains("Microphone") == true
                    Button(isMicError ? "Open Microphone Settings" : "Open Screen Recording Settings") {
                        let url = isMicError
                            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                            : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        NSWorkspace.shared.open(URL(string: url)!)
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.link)
                }
            }

            if ble.syncMode == .audio {
                Picker("", selection: Binding(
                    get: { ble.audioSyncMode },
                    set: { ble.audioSyncMode = $0 }
                )) {
                    ForEach(LightBLEManager.AudioSyncMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)

                Picker("", selection: Binding(
                    get: { ble.audioInputSource },
                    set: { ble.audioInputSource = $0 }
                )) {
                    ForEach(LightBLEManager.AudioInputSource.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }

            if (ble.syncMode == .audio && ble.audioSyncMode == .rainbow) || ble.syncMode == .combined {
                HStack {
                    Text("Beat sensitivity")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { ble.beatSensitivity },
                        set: { ble.beatSensitivity = $0 }
                    ), in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("Beat Sensitivity")
                    .accessibilityValue("\(Int(ble.beatSensitivity * 100))%")
                    Text("\(Int(ble.beatSensitivity * 100))%")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Text(modeDescription)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            if ble.isSyncingVideo {
                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { ble.selectedDisplayID },
                        set: { ble.selectedDisplayID = $0 }
                    )) {
                        Text("Primary display").tag(Optional<CGDirectDisplayID>.none)
                        ForEach(ble.availableDisplays, id: \.id) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).controlSize(.small)
                    Button { ble.loadAvailableDisplays() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).font(.caption).help("Refresh display list")
                }
                .onAppear { ble.loadAvailableDisplays() }

                HStack {
                    Text("Responsiveness")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { ble.syncResponsiveness },
                        set: { ble.syncResponsiveness = $0 }
                    ), in: 0.1...1.0)
                    .controlSize(.mini)
                    .accessibilityLabel("Responsiveness")
                    .accessibilityValue("\(Int(ble.syncResponsiveness * 100))%")
                }

                if ble.syncMode == .video {
                    Toggle("Follow screen brightness", isOn: Binding(
                        get: { ble.videoSyncBrightness },
                        set: { ble.videoSyncBrightness = $0 }
                    ))
                    .font(.system(size: 9))
                    .toggleStyle(.checkbox)
                    .help("Strip brightness tracks average screen brightness (not available in Combined — audio drives brightness there)")
                }
            }
        }
    }

    private var modeDescription: String {
        switch ble.syncMode {
        case .off:      return "Color picker and presets are active"
        case .video:    return "Strip mirrors your screen colors in real-time"
        case .audio:
            switch ble.audioSyncMode {
            case .rainbow:   return "Music beats drive color and brightness"
            case .pulse:     return "Keeps current color · bass and beats drive brightness"
            case .frequency: return "Bass → red · mids → green · treble → blue"
            }
        case .combined: return "Screen color · music pulses brightness like Music Pulse"
        }
    }
}

// MARK: - MenuBarView helpers (private extension keeps them off the struct namespace)
private extension MenuBarView {
    var colorTempLabel: String {
        let k = Int(2700 + ble.colorTemperature * 3800)
        switch k {
        case ..<3200: return "Warm \(k)K"
        case ..<4500: return "Neutral \(k)K"
        case ..<5500: return "Cool \(k)K"
        default:      return "Daylight \(k)K"
        }
    }

    func applyPreset(_ preset: Preset) {
        if !ble.isOn { ble.setPower(on: true) }
        // setColor → setHue already calls stopSyncInline() when sync is active.
        // Calling setSyncMode(.off) first would queue a fade that competes with
        // the incoming preset color (fade writes old color for 300ms).
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
    }

    func saveCurrentAsPreset(named name: String) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if let srgbColor = NSColor(ble.color).usingColorSpace(.sRGB) {
            srgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        } else if let deviceColor = NSColor(ble.color).usingColorSpace(.deviceRGB) {
            deviceColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        } else {
            let hsv = ble.color.hsvComponents
            let c = NSColor(hue: hsv.0, saturation: hsv.1, brightness: hsv.2, alpha: 1)
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        let p = Preset(name: name, red: Double(r), green: Double(g),
                       blue: Double(b), brightness: ble.brightness)
        presets.presets.append(p)
        presets.save()
    }

    var stateIcon: String {
        switch ble.connectionState {
        case .disconnected: return "wifi.slash"
        case .scanning:     return "antenna.radiowaves.left.and.right"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .connected:    return "checkmark.circle"
        }
    }

    var stateLabel: String {
        switch ble.connectionState {
        case .disconnected: return "Not connected"
        case .scanning:     return "Scanning…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        }
    }

    var connectionButtonLabel: String {
        switch ble.connectionState {
        case .disconnected: return "Connect"
        case .scanning:     return "Cancel"
        case .connecting:   return "Cancel"
        case .connected:    return "Disconnect"
        }
    }
}

private struct SavePresetSheet: View {
    @Binding var name: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Preset").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onAppear { focused = true }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
