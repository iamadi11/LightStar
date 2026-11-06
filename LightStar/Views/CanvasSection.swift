import SwiftUI
import LightStarCore

private struct CanvasEngineKey: EnvironmentKey {
    static let defaultValue: CanvasEngine? = nil
}

extension EnvironmentValues {
    /// The app's Canvas liquid. A plain reference: it changes every frame, so
    /// it isn't observed.
    var canvasEngine: CanvasEngine? {
        get { self[CanvasEngineKey.self] }
        set { self[CanvasEngineKey.self] = newValue }
    }
}

/// The Canvas controls: lights follow it, show it, mode, animation, quality.
/// The same settings the iPhone changes.
struct CanvasSection: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(\.canvasEngine) private var engine
    @AppStorage(CanvasMode.defaultsKey) private var mode = CanvasMode.auto
    @AppStorage(CanvasStyle.defaultsKey) private var style = CanvasStyle.liquid
    @AppStorage(CanvasQuality.defaultsKey) private var quality = CanvasQuality.uhd

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Canvas", systemImage: "drop.halffull")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show Canvas") { openLightStarCanvas() }
                    .controlSize(.small)
                    .help("Opens the Canvas. The lights follow it.")
            }
            Toggle("Lights follow the Canvas", isOn: Binding(
                get: { ble.syncMode == .canvas },
                set: { ble.setSyncMode($0 ? .canvas : .off) }
            ))
            .font(.caption)
            .disabled(ble.syncTransitioning)
            .help("Straight from the Canvas: no screen recording. Keeps running with the window closed.")

            Picker("Mode", selection: $mode) {
                ForEach(CanvasMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("Auto: it flows by itself, and you can still stir it. Interactive: it only moves when you stir it.")

            Picker("Animation", selection: $style) {
                ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
            }
            .controlSize(.small)

            Picker("Quality", selection: $quality) {
                ForEach(CanvasQuality.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("4K draws the liquid finer than most screens and filters it down, so it stays sharp on 2K and 4K.")
        }
        .onChange(of: mode) { _, _ in engine?.applySettings() }
        .onChange(of: style) { _, _ in engine?.applySettings() }
        .onChange(of: quality) { _, _ in engine?.applyQuality() }
    }
}
