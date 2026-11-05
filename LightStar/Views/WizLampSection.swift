import SwiftUI
import AppKit
import LightStarCore

/// The WiZ gradient lightbar: built-in scenes, one colour per segment, and the
/// segment layout (detected from the lamp; saved widths override it).
struct WizLampSection: View {
    @Environment(WizLampController.self) private var wizLamp
    @Environment(LightBLEManager.self) private var ble
    @State private var colors: [Color] = []
    @State private var lit: [Bool] = []
    @State private var sceneID = 0
    @State private var widthsText = ""
    @State private var slot = 258
    @AppStorage(LampGradient.enabledDefaultsKey) private var gradientSync = true
    @AppStorage(LampGradient.orientationDefaultsKey) private var orientation = LampGradient.Orientation.vertical
    @AppStorage(LampGradient.flippedDefaultsKey) private var flipped = false
    @AppStorage(LampGradient.musicStyleDefaultsKey) private var musicStyle = LampGradient.MusicStyle.meter
    @AppStorage(WizLampController.whiteToneDefaultsKey) private var whiteTone = 1.0
    @AppStorage(LampEffect.customColoursDefaultsKey) private var customColours = false
    @State private var paletteColours: [Color] = []

    private var ready: Bool {
        if case .following = wizLamp.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            lightsList

            HStack(spacing: 6) {
                Text("White").font(.caption)
                Text("Warm").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { whiteTone }, set: { whiteTone = $0; wizLamp.setWhiteTone($0) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("White tone")
                    .accessibilityValue(whiteTone < 0.34 ? "Warm" : whiteTone > 0.66 ? "Cool" : "Neutral")
                Text("Cool").font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("Gradient sync", isOn: $gradientSync)
            Picker("Music", selection: $musicStyle) {
                ForEach(LampGradient.MusicStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!gradientSync)
            Picker("Orientation", selection: $orientation) {
                ForEach(LampGradient.Orientation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!gradientSync)
            Toggle(orientation.flipTitle, isOn: $flipped)
                .disabled(!gradientSync)
            LightbarFitControls(orientation: orientation)
                .disabled(!gradientSync)
            Text(orientationHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            effectControls

            Picker("Scene", selection: $sceneID) {
                Text("None").tag(0)
                ForEach(WizScene.all, id: \.id) { scene in
                    Text(scene.name).tag(scene.id)
                }
            }
            .onChange(of: sceneID) { _, id in
                if id > 0 {
                    ble.setLampEffect(nil)
                    wizLamp.setScene(id)
                }
            }

            HStack(spacing: 6) {
                ForEach(colors.indices, id: \.self) { index in
                    VStack(spacing: 4) {
                        ColorPicker("Segment \(index + 1)", selection: $colors[index], supportsOpacity: false)
                            .labelsHidden()
                        Toggle("Segment \(index + 1) on", isOn: $lit[index])
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                Button("Apply Segments") { applySegments() }
                Button("Rainbow") {
                    colors = colors.indices.map { Color(hue: Double($0) / Double(max(1, colors.count)), saturation: 1, brightness: 1) }
                    lit = lit.map { _ in true }
                    applySegments()
                }
            }

            HStack {
                TextField("Segment widths", text: $widthsText)
                    .frame(maxWidth: 160)
                Stepper("Slot \(slot)", value: $slot, in: WizSegmentLayout.slots)
                Button("Save Layout") { saveLayout() }
                    .disabled(WizSegmentLayout.parse(widthsText) == nil)
                Button("Reset") {
                    wizLamp.resetLayout()
                    load(.stored)
                }
            }
            Text("Widths: segments each colour covers, bottom first\(detectedText). Slot: an empty WiZ custom mode (256–265). Allow local communication in the WiZ app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!ready)
        .onAppear {
            load(WizSegmentLayout.stored)
            loadPalette()
        }
    }

    private var detectedText: String {
        let count = UserDefaults.standard.integer(forKey: WizSegmentLayout.countDefaultsKey)
        return count > 0 ? "; the lamp reports \(count)" : ""
    }

    /// Every WiZ light found. Only switched-on ones follow LightStar, so a
    /// bulb elsewhere in the house is left alone until chosen.
    @ViewBuilder
    private var lightsList: some View {
        if wizLamp.lights.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text("WiZ lights on this network").font(.caption).foregroundStyle(.secondary)
                ForEach(wizLamp.lights) { light in
                    Toggle(isOn: Binding(get: { light.enabled }, set: { wizLamp.setLight(light.mac, enabled: $0) })) {
                        HStack(spacing: 6) {
                            Text(light.name)
                            if light.enabled {
                                Text(light.connected ? "Connected" : "Looking…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Bulbs without segments show one colour: the average of the lightbar's.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Name of the running built-in effect ("" for none or a strip-following one).
    private var builtInEffectName: String {
        guard let effect = ble.lampEffect, LampEffect.named(effect.name) != nil else { return "" }
        return effect.name
    }

    @ViewBuilder
    private var effectControls: some View {
        Picker("Effect", selection: Binding(
            get: { builtInEffectName },
            set: { name in
                sceneID = 0
                ble.setLampEffect(LampEffect.named(name)?.withUserPalette())
            }
        )) {
            Text("None").tag("")
            ForEach(LampEffect.builtIn) { Text($0.name).tag($0.name) }
        }
        if let effect = ble.lampEffect {
            if builtInEffectName.isEmpty {
                Text("Following the strip: \(effect.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Speed").font(.caption)
                Slider(value: Binding(get: { ble.effectSpeed }, set: { ble.setEffectSpeed($0) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Effect speed")
                Toggle("Reverse", isOn: Binding(get: { !ble.effectForward }, set: { ble.setEffectDirection(forward: !$0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Run flows and chases from the far end. Shared with the strip.")
            }
        }
        Toggle("Custom colours", isOn: Binding(get: { customColours }, set: { customColours = $0; restartEffectWithColours() }))
        if customColours {
            HStack(spacing: 8) {
                ForEach(paletteColours.indices, id: \.self) { i in
                    ColorPicker("Effect colour \(i + 1)", selection: Binding(
                        get: { paletteColours[i] },
                        set: { paletteColours[i] = $0; savePalette() }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            }
        }
        Text("Strip effects you pick also run on the lightbar in matching colours. Custom colours apply to the effects listed here.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func loadPalette() {
        let palette = (UserDefaults.standard.array(forKey: LampEffect.customPaletteDefaultsKey) as? [[Int]])?
            .compactMap { $0.count == 3 ? WizRGB(r: $0[0], g: $0[1], b: $0[2]) : nil } ?? LampEffect.defaultCustomPalette
        paletteColours = palette.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
    }

    private func savePalette() {
        let rgb = paletteColours.compactMap { NSColor($0).usingColorSpace(.sRGB) }.map {
            [Int(($0.redComponent * 255).rounded()), Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded())]
        }
        UserDefaults.standard.set(rgb, forKey: LampEffect.customPaletteDefaultsKey)
        restartEffectWithColours()
    }

    /// A running built-in effect picks up colour changes straight away.
    private func restartEffectWithColours() {
        guard let base = LampEffect.named(builtInEffectName) else { return }
        ble.setLampEffect(base.withUserPalette())
    }

    private var orientationHint: String {
        let screen = orientation == .vertical
            ? "reads the screen top to bottom"
            : "reads the screen left to right"
        return "Screen sync \(screen) onto the lightbar. In Combined, beats pulse it too."
    }

    private func load(_ layout: WizSegmentLayout) {
        widthsText = layout.widths.map(String.init).joined(separator: ",")
        slot = layout.slot
        let sent = wizLamp.segments
        colors = layout.widths.indices.map { index in
            guard index < sent.count, !sent[index].isOff else { return .white }
            let c = sent[index]
            return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
        lit = layout.widths.indices.map { index in index < sent.count ? !sent[index].isOff : true }
    }

    private func applySegments() {
        sceneID = 0
        let rgb = colors.indices.map { index -> WizRGB in
            guard lit[index], let c = NSColor(colors[index]).usingColorSpace(.sRGB) else { return .off }
            return WizRGB(r: Int((c.redComponent * 255).rounded()),
                          g: Int((c.greenComponent * 255).rounded()),
                          b: Int((c.blueComponent * 255).rounded()))
        }
        ble.setLampEffect(nil)
        wizLamp.setSegments(rgb)
    }

    private func saveLayout() {
        guard let widths = WizSegmentLayout.parse(widthsText) else { return }
        let layout = WizSegmentLayout(widths: widths, slot: slot)
        wizLamp.setLayout(layout)
        load(layout)
    }
}

/// How much of each end of the lightbar stays off in screen sync, for a bar
/// longer than the monitor. The screen fills the stretch in between.
struct LightbarFitControls: View {
    let orientation: LampGradient.Orientation
    @AppStorage(LampGradient.trimStartDefaultsKey) private var trimStart = 0.0
    @AppStorage(LampGradient.trimEndDefaultsKey) private var trimEnd = 0.0
    @AppStorage(LampGradient.edgeDefaultsKey) private var edge = LampGradient.Edge.whole
    @AppStorage(LampGradient.edgeDepthDefaultsKey) private var edgeDepth = 0.25
    @AppStorage(LampGradient.ignoreBarsDefaultsKey) private var ignoreBars = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Read", selection: $edge) {
                ForEach(LampGradient.Edge.allCases) { Text($0.title(for: orientation)).tag($0) }
            }
            .font(.caption)
            .help("Follow the edge of the screen next to the lightbar, like an ambient light.")
            if edge != .whole {
                HStack(spacing: 6) {
                    Text("Edge depth")
                        .font(.caption)
                        .frame(width: 78, alignment: .leading)
                    Slider(value: $edgeDepth, in: LampGradient.edgeDepthRange)
                        .controlSize(.small)
                        .accessibilityLabel("Edge depth")
                        .accessibilityValue("\(Int((edgeDepth * 100).rounded()))% of the screen")
                    Text("\(Int((edgeDepth * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Toggle("Ignore black bars", isOn: $ignoreBars)
                .font(.caption)
                .help("Films and 4:3 video: map the lightbar to the picture, not the black bars around it.")
            trimRow(orientation == .vertical ? "Off at bottom" : "Off at left",
                    value: Binding(get: { trimStart },
                                   set: { trimStart = min($0, 1 - LampGradient.minLit - trimEnd) }))
            trimRow(orientation == .vertical ? "Off at top" : "Off at right",
                    value: Binding(get: { trimEnd },
                                   set: { trimEnd = min($0, 1 - LampGradient.minLit - trimStart) }))
            HStack {
                Text("Screen sync lights only the stretch in between.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Reset") { trimStart = 0; trimEnd = 0 }
                    .controlSize(.small)
                    .disabled(trimStart == 0 && trimEnd == 0)
            }
        }
    }

    private func trimRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: 0...(1 - LampGradient.minLit))
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))% of the lightbar")
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
