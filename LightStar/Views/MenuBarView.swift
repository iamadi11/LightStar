import SwiftUI
import AVFoundation

struct MenuBarView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets
    @State private var selectedTab = 0

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
                    } else {
                        statusSection
                    }
                } else {
                    DebugTabView()
                }
            }
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
            Image(systemName: stateIcon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(stateLabel)
                .foregroundStyle(.secondary)
                .font(.subheadline)
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
                Text("Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(presets.presets) { preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 10, height: 10)
                                Text(preset.name)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                if ble.syncTransitioning { ProgressView().controlSize(.mini) }
            }

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
            }
        }
    }

    private var modeDescription: String {
        switch ble.syncMode {
        case .off:      return "No sync — color picker and presets above are active"
        case .video:    return "Edges weighted 3× · brightness stays at slider · 20 Hz"
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
        ble.setSyncMode(.off)
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
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
