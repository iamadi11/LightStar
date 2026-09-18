import SwiftUI
import LightStarCore

// Inline hue + saturation picker — no popup window.
struct ColorControlView: View {
    @Environment(LightBLEManager.self) private var ble
    @State private var hue: Double = 0
    @State private var sat: Double = 1.0
    @State private var colorTemp: Double = 0.5   // 0=warm 2700K, 1=cool 6500K
    @State private var mode: ColorMode = .color
    @State private var ignoreNextBLEUpdate = false

    enum ColorMode { case color, white }

    private static let hueGradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0/12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    })
    private static let cctGradient = Gradient(colors: [
        Color(red: 1.0, green: 0.76, blue: 0.47),   // ~2700K warm
        Color(red: 1.0, green: 1.0,  blue: 1.0),    // ~4000K neutral
        Color(red: 0.87, green: 0.93, blue: 1.0),   // ~6500K cool
    ])

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Color", systemImage: "paintbrush")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $mode) {
                    Text("Color").tag(ColorMode.color)
                    Text("White").tag(ColorMode.white)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 110)
            }

            if mode == .color {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hue").font(.caption2).foregroundStyle(.secondary)
                    GradientSlider(gradient: Self.hueGradient, value: $hue)
                        .onChange(of: hue) { _, _ in sendColor() }
                }
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

                // Color history strip
                if !ble.colorHistory.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(ble.colorHistory.prefix(10).enumerated()), id: \.offset) { _, entry in
                            Circle()
                                .fill(Color(hue: entry.h, saturation: entry.s, brightness: 1))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .onTapGesture {
                                    hue = entry.h; sat = entry.s
                                    sendColor()
                                }
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Temperature").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if ble.circadianEnabled {
                            Text("auto").font(.caption2).foregroundStyle(.blue)
                        } else {
                            Text("\(Int(2700 + colorTemp * 3800))K")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    GradientSlider(gradient: Self.cctGradient, value: $colorTemp)
                        .onChange(of: colorTemp) { _, _ in sendCCT() }
                        .disabled(ble.circadianEnabled)
                        .opacity(ble.circadianEnabled ? 0.4 : 1)
                }

                Toggle(isOn: Binding(
                    get: { ble.circadianEnabled },
                    set: { ble.circadianEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Circadian (auto-adjust)").font(.caption2)
                        Text("Warm at night · Cool in morning")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
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
        if s > 0.05 { hue = h; sat = s }
    }

    private func sendColor() {
        ignoreNextBLEUpdate = true
        ble.setSyncMode(.off)
        ble.circadianEnabled = false
        ble.setHue(hue, saturation: sat)
    }

    private func sendCCT() {
        ignoreNextBLEUpdate = true
        ble.setSyncMode(.off)
        ble.setColorTemperature(colorTemp)
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
