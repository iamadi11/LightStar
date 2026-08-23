import SwiftUI

struct MenuBarView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets

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
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if ble.connectionState == .connected {
                        controlsSection
                    } else {
                        statusSection
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 300)
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
            // Power + color row
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

                ColorPicker("Color", selection: Binding(
                    get: { ble.color },
                    set: { ble.setColor($0) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 28)
            }

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

            // Effects
            EffectsView()
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
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(ble.connectionState == .connected ? .red : .accentColor)
    }

    // MARK: - Helpers

    private func applyPreset(_ preset: Preset) {
        if !ble.isOn { ble.setPower(on: true) }
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
    }

    private var stateIcon: String {
        switch ble.connectionState {
        case .disconnected: return "wifi.slash"
        case .scanning:     return "antenna.radiowaves.left.and.right"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .connected:    return "checkmark.circle"
        }
    }

    private var stateLabel: String {
        switch ble.connectionState {
        case .disconnected: return "Not connected"
        case .scanning:     return "Scanning…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        }
    }

    private var connectionButtonLabel: String {
        switch ble.connectionState {
        case .disconnected: return "Connect"
        case .scanning:     return "Cancel"
        case .connecting:   return "Cancel"
        case .connected:    return "Disconnect"
        }
    }
}

// MARK: - Effects subview

private struct EffectsView: View {
    @Environment(LightBLEManager.self) private var ble

    private let effects: [(String, UInt8)] = [
        ("Jump RGB", 0x25), ("Fade RGB", 0x27),
        ("Flash", 0x29), ("Strobe", 0x2C),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effects")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(effects, id: \.1) { name, mode in
                    Button {
                        ble.setEffect(mode: mode, speed: ble.effectSpeed)
                    } label: {
                        Text(name)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(ble.effectMode == mode ? .accentColor : .primary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Speed", systemImage: "hare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Speed: 0x01 fast → 0x1F slow; invert slider so right = fast
                Slider(value: Binding(
                    get: { 1.0 - (Double(ble.effectSpeed) / 31.0) },
                    set: { ble.setEffect(mode: ble.effectMode, speed: UInt8(max(1, Int((1.0 - $0) * 31)))) }
                ), in: 0...1)
            }
        }
    }
}
