import SwiftUI

struct EffectsView: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Effects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.effectModeActive {
                    Button("Solid Color") { ble.exitEffectMode() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            ForEach(knownEffects, id: \.group.rawValue) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.group.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(section.effects) { fx in
                            Button(fx.name) { ble.setEffect(id: fx.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(ble.effectModeActive && ble.effectID == fx.id ? .accentColor : nil)
                                .font(.system(size: 10))
                        }
                    }
                }
            }

            if ble.effectModeActive {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Speed", systemImage: "hare")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(ble.effectSpeed * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { ble.effectSpeed },
                        set: { ble.setEffectSpeed($0) }
                    ), in: 0...1)
                }
            }
        }
    }
}

// BC13: 253 built-in firmware animation scenes (0x00–0xFF, gaps at 0x3D 0x5B 0x96)
// Separate from BC06 effects — these are device-firmware patterns, not the HA effect table.
struct AnimationsView: View {
    @Environment(LightBLEManager.self) private var ble
    private static let validIDs: [UInt8] = (0x00...0xFF).compactMap { v in
        [0x3D, 0x5B, 0x96].contains(v) ? nil : UInt8(v)
    }
    @State private var sceneIndex: Double = 0

    private var currentID: UInt8 { Self.validIDs[min(Int(sceneIndex), Self.validIDs.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Animations", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Scene \(Int(sceneIndex) + 1)/\(Self.validIDs.count)  (0x\(String(format: "%02X", currentID)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $sceneIndex, in: 0...Double(Self.validIDs.count - 1), step: 1) {
                EmptyView()
            } onEditingChanged: { _ in
                sendAnimation()
            }
            HStack(spacing: 6) {
                Button("◀") {
                    sceneIndex = max(0, sceneIndex - 1)
                    sendAnimation()
                }
                Button("▶") {
                    sceneIndex = min(Double(Self.validIDs.count - 1), sceneIndex + 1)
                    sendAnimation()
                }
                Button("▶ Play") { sendAnimation() }
                Button("Random") {
                    sceneIndex = Double(Int.random(in: 0..<Self.validIDs.count))
                    sendAnimation()
                }
                Spacer()
                Button("Stop") { ble.exitEffectMode() }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func sendAnimation() {
        ble.setSyncMode(.off)
        ble.sendRaw([0xBC, 0x13, 0x01, currentID, 0x55])
    }
}
