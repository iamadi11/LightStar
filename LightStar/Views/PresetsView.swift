import SwiftUI
import LightStarCore

struct PresetsView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets

    var body: some View {
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

            HStack(spacing: 8) {
                Button("Export…") { presets.exportToFile() }
                Button("Import…") { presets.importFromFile() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func applyPreset(_ preset: Preset) {
        if !ble.isOn { ble.setPower(on: true) }
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
    }
}
