import SwiftUI
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(ble.connectionState == .connected ? Color.yellow : .secondary)
                Text("LightStar")
                    .font(.headline)
                Spacer()
                connectionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Tab picker
            HStack(spacing: 0) {
                tabButton("Control", index: 0)
                tabButton("Debug", index: 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                if selectedTab == 0 {
                    if ble.connectionState == .connected {
                        controlsSection
                            .transition(.opacity)
                    } else {
                        statusSection
                            .transition(.opacity)
                    }
                } else {
                    DebugTabView()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: ble.connectionState)
        }
        .frame(width: 320)
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
        VStack(spacing: 8) {
            if ble.connectionState == .scanning {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: stateIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
            Text(stateLabel)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            if let err = ble.connectionError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ble.bleNeedsPermission {
                Button("Open Bluetooth Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            } else if ble.connectionState == .disconnected {
                Button("Connect") { ble.connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var controlsSection: some View {
        VStack(spacing: 16) {
            // Power row
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { ble.isOn },
                    set: { ble.setPower(on: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                Text(ble.isOn ? "On" : "Off")
                    .frame(width: 24, alignment: .leading)
                Spacer()
                Text("⌘⇧L")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Global shortcut: ⌘⇧L toggles power")
            }

            ColorControlView()

            // Brightness
            VStack(alignment: .leading, spacing: 4) {
                Label("Brightness", systemImage: "sun.max")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { ble.brightness },
                    set: { ble.setBrightness($0) }
                ), in: 0...1)
            }

            Divider()

            // Presets
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if presets.presets.isEmpty {
                        Button("Restore Defaults") {
                            presets.presets = Preset.defaults
                            presets.save()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                    }
                    Button { presets.importFromFile() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain).font(.caption).help("Import presets from JSON")
                    Button { presets.exportToFile() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain).font(.caption).help("Export presets to JSON")
                    Button {
                        newPresetName = "Custom"
                        showSaveSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
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

            Divider()

            // Sync mode (video / audio / combined)
            SyncControlView()

            Divider()

            // Effects
            EffectsView()

            Divider()

            AnimationsView()

            Divider()

            ScheduleView()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                Toggle("Auto-connect on Launch", isOn: $autoConnectOnLaunch)
                    .font(.caption)
                    .toggleStyle(.checkbox)
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
        .padding(16)
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
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(ble.connectionState == .connected ? .red : .accentColor)
    }

}

private struct SyncControlView: View {
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
            .animation(.easeInOut(duration: 0.3), value: ble.syncColor != nil)

            Picker("", selection: Binding(
                get: { ble.syncMode },
                set: { ble.setSyncMode($0) }
            )) {
                ForEach(LightBLEManager.SyncMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
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

                if ble.audioSyncMode == .rainbow || ble.syncMode == .combined {
                    HStack {
                        Text("Beat sensitivity")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { ble.beatSensitivity },
                            set: { ble.beatSensitivity = $0 }
                        ), in: 0...1)
                        .controlSize(.mini)
                        Text("\(Int(ble.beatSensitivity * 100))%")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
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
        case .off:      return "No sync — color picker and presets above are active"
        case .video:    return ble.videoSyncBrightness ? "Edges weighted 3× · screen brightness → strip · 20 Hz" : "Edges weighted 3× · brightness stays at slider · 20 Hz"
        case .audio:
            switch ble.audioSyncMode {
            case .rainbow:   return "Beats → hue · treble → drift · bass → brightness"
            case .pulse:     return "Bass → brightness · keeps current color"
            case .frequency: return "Bass → red · mid → green · treble → blue"
            }
        case .combined: return "Screen → color · audio beats → brightness · no mic needed"
        }
    }
}

// MARK: - MenuBarView helpers (private extension keeps them off the struct namespace)
private extension MenuBarView {
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
        (NSColor(ble.color).usingColorSpace(.sRGB) ?? NSColor(ble.color))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
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
