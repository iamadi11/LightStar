import SwiftUI
import LightStarCore

/// Full-size control surface — the answer to the 320pt popover being too cramped.
struct ControlWindowView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(HomeKitLampController.self) private var homeKitLamp
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
                    .disabled(!outputReachable)
                    Text("Effects, animations, and schedules live here. The menu-bar popover stays on power, color, presets, and sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LightTargetSection()
                    if !outputReachable {
                        Text(ble.outputTarget == .lamp
                             ? "Connect the Mi lamp above. Colour and power go to the lamp."
                             : "Connect a light above to change colour, brightness, and power.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        let live = ble.isOn && outputReachable
                        if !live {
                            Text("Turn the light on to change color, sync, and effects. Schedules still run when the light is off.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Group {
                            ColorControlView()
                            brightnessSlider
                            Divider()
                            presetsBlock
                            Divider()
                            SyncControlView()
                            if ble.outputTarget.sendsToStrip {
                                Divider()
                                EffectsView()
                                Divider()
                                AnimationsView()
                            }
                        }
                        .stripOutputEnabled(live)
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

    private var lampReady: Bool {
        if case .following = homeKitLamp.state { return true }
        return false
    }

    private var outputReachable: Bool {
        let strip = ble.outputTarget.sendsToStrip && ble.connectionState == .connected
        let lamp = ble.outputTarget.sendsToLamp && lampReady
        return strip || lamp
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
