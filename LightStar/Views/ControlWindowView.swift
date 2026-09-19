import SwiftUI
import LightStarCore

/// Full-size control surface — the answer to the 320pt popover being too cramped.
struct ControlWindowView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets

    var body: some View {
        NavigationSplitView {
            List {
                Section("Light") {
                    LabeledContent("Status", value: statusText)
                    Toggle("Power", isOn: Binding(
                        get: { ble.isOn },
                        set: { ble.setPower(on: $0) }
                    ))
                    .disabled(ble.connectionState != .connected)
                    Text("Effects, animations, and schedules live here. The menu-bar popover stays on power, color, presets, and sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if ble.connectionState != .connected {
                        ContentUnavailableView(
                            ble.connectionError ?? "Not connected",
                            systemImage: "lightbulb.slash",
                            description: Text("Use Connect in the menu bar, or tap below.")
                        )
                        Button("Connect") { ble.connect() }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    } else {
                        ColorControlView()
                        brightnessSlider
                        Divider()
                        presetsBlock
                        Divider()
                        SyncControlView()
                        Divider()
                        EffectsView()
                        Divider()
                        AnimationsView()
                        Divider()
                        ScheduleView()
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .background {
                LightStarVisualEffect(material: .menu)
                    .ignoresSafeArea()
            }
        }
        .tint(ble.stripAccent)
        .frame(minWidth: 640, minHeight: 520)
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

    private var brightnessSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Brightness", systemImage: "sun.max")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { ble.brightness },
                set: { ble.setBrightness($0) }
            ), in: 0...1)
        }
    }

    private var presetsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scenes").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(presets.presets) { preset in
                    Button {
                        ble.apply(preset: preset)
                    } label: {
                        HStack {
                            Circle().fill(preset.color).frame(width: 12, height: 12)
                            Text(preset.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
