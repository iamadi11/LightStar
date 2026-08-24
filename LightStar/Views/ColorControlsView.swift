import SwiftUI

// Inline hue + saturation picker — no popup window.
struct ColorControlView: View {
    @Environment(LightBLEManager.self) private var ble
    @State private var hue: Double = 0        // red
    @State private var sat: Double = 1.0      // full saturation — never start at white
    @State private var ignoreNextBLEUpdate = false

    private static let hueGradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0/12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    })

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Preview swatch
            HStack(spacing: 8) {
                Label("Color", systemImage: "paintbrush")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // White shortcut
                Button("White") {
                    sat = 0
                    sendColor()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hue: hue, saturation: sat, brightness: 1))
                    .frame(width: 36, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }

            // Hue slider
            VStack(alignment: .leading, spacing: 2) {
                Text("Hue").font(.caption2).foregroundStyle(.secondary)
                GradientSlider(gradient: Self.hueGradient, value: $hue)
                    .onChange(of: hue) { _, _ in sendColor() }
            }

            // Saturation slider (white → full color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saturation").font(.caption2).foregroundStyle(.secondary)
                GradientSlider(
                    gradient: Gradient(colors: [
                        Color(hue: hue, saturation: 0, brightness: 1),
                        Color(hue: hue, saturation: 1, brightness: 1)
                    ]),
                    value: $sat
                )
                .onChange(of: sat) { _, _ in sendColor() }
            }
        }
        .onAppear { syncFromBLE() }
        .onChange(of: ble.color) { _, _ in
            guard !ignoreNextBLEUpdate else { ignoreNextBLEUpdate = false; return }
            syncFromBLE()
        }
    }

    private func syncFromBLE() {
        let (h, s, _) = ble.color.hsvComponents
        if s > 0.05 {
            hue = h
            sat = s
        }
        // If color is white/near-white, keep sliders as-is so dragging hue
        // immediately shows color. Don't reset sat to 0.
    }

    private func sendColor() {
        ignoreNextBLEUpdate = true
        ble.setSyncMode(.off)
        ble.setHue(hue, saturation: sat)
    }
}

struct GradientSlider: View {
    let gradient: Gradient
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let thumbSize: CGFloat = 16
            let trackWidth = geo.size.width - thumbSize
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                    .padding(.horizontal, thumbSize / 2)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: value * trackWidth)
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = max(0, min(1, (drag.location.x - thumbSize / 2) / trackWidth))
            })
        }
        .frame(height: 16)
    }
}
