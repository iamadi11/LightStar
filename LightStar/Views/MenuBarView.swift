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
                Text(err).font(.system(size: 9)).foregroundStyle(.red)
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

private struct EffectsView: View {
    @Environment(LightBLEManager.self) private var ble

    // Effect IDs confirmed from second PacketLogger capture (2026-08-23)
    private let effects: [(name: String, id: UInt8)] = [
        ("Effect 1", 0x01),
        ("Effect 3", 0x03),
        ("Effect 53", 0x35),
    ]

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

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(effects, id: \.id) { fx in
                    Button(fx.name) { ble.setEffect(id: fx.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(ble.effectModeActive && ble.effectID == fx.id ? .accentColor : nil)
                }
            }

            if ble.effectModeActive {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Speed", systemImage: "hare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { ble.effectSpeed },
                        set: { ble.setEffectSpeed($0) }
                    ), in: 0...1)
                }
            }
        }
    }
}

// BC13: 253 built-in animation scenes (0x00–0xFF, gaps at 0x3D 0x5B 0x96)
private struct AnimationsView: View {
    @Environment(LightBLEManager.self) private var ble
    // Valid IDs — skip the 3 gaps
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

// Inline hue + saturation picker — no popup window.
private struct ColorControlView: View {
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

private struct GradientSlider: View {
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

// MARK: - Debug Tab

private struct DebugTabView: View {
    @Environment(LightBLEManager.self) private var ble
    @State private var rawHex: String = "BC 13 02 00 00 55"
    @State private var hexError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live camera monitor
            LiveCameraCard()

            Divider()

            // Raw BLE commands
            VStack(alignment: .leading, spacing: 6) {
                Label("Raw Commands", systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("OFF")   { ble.sendRaw([0xBC,0x01,0x01,0x00,0x55]) }
                    Button("ON")    { ble.sendRaw([0xBC,0x01,0x01,0x01,0x55]) }
                    Button("Stop Anim") { ble.sendRaw([0xBC,0x13,0x02,0x00,0x00,0x55]) }
                        .tint(.orange)
                }
                HStack(spacing: 6) {
                    Button("Red")   { ble.sendRaw([0xBC,0x04,0x06,0x00,0x00,0x03,0xE8,0x00,0x00,0x55]) }
                    Button("Green") { ble.sendRaw([0xBC,0x04,0x06,0x00,0x78,0x03,0xE8,0x00,0x00,0x55]) }
                    Button("Blue")  { ble.sendRaw([0xBC,0x04,0x06,0x00,0xF0,0x03,0xE8,0x00,0x00,0x55]) }
                }
                HStack(spacing: 6) {
                    Button("Bri MAX") { ble.sendRaw([0xBC,0x05,0x06,0x03,0xE8,0x00,0x00,0x00,0x00,0x55]) }
                    Button("Bri MIN") { ble.sendRaw([0xBC,0x05,0x06,0x00,0x64,0x00,0x00,0x00,0x00,0x55]) }
                }

                // Free-form hex input
                HStack(spacing: 6) {
                    TextField("BC 13 02 00 00 55", text: $rawHex)
                        .font(.system(size: 10, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: rawHex) { _, _ in hexError = nil }
                    Button("Send") { sendHex() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                if let err = hexError {
                    Text(err).font(.system(size: 9)).foregroundStyle(.red)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Divider()

            // Probe tools
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Probe Tools", systemImage: "magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("📷 Camera", isOn: Binding(
                        get: { ble.cameraProbeEnabled },
                        set: { ble.cameraProbeEnabled = $0 }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Use camera to detect strip color during probe")
                }
                CameraPickerRow()
                HStack(spacing: 6) {
                    Button(ble.probeRunning ? "Running…" : "Color Test") {
                        ble.testColorMapping()
                    }
                    .disabled(ble.probeRunning)
                    Button(ble.probeRunning ? "Running…" : "Sweep") {
                        ble.sweepColorPalette()
                    }
                    .disabled(ble.probeRunning)
                    Button(ble.probeRunning ? "…" : "Broad") {
                        ble.probeProtocol()
                    }
                    .disabled(ble.probeRunning)
                    Button(ble.probeRunning ? "…" : "Deep") {
                        ble.probeDeep()
                    }
                    .disabled(ble.probeRunning)
                    .help("Full BC sweep ~5 min")
                    if !ble.probeLog.isEmpty && !ble.probeRunning {
                        Spacer()
                        Button("Clear") { ble.probeLog = [] }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if !ble.probeLog.isEmpty {
                    logView(lines: ble.probeLog)
                }
            }

            Divider()

            // Device info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Device Info", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !ble.deviceLog.isEmpty {
                        Button("Backup All") { ble.saveFullBackup() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(.orange)
                        Button("Save Log") { ble.saveDeviceLog() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                if ble.deviceLog.isEmpty {
                    Text("Connect to strip to discover services")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else {
                    logView(lines: ble.deviceLog)
                }
            }
        }
        .padding(16)
    }

    private func sendHex() {
        let tokens = rawHex.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var bytes: [UInt8] = []
        for tok in tokens {
            guard let val = UInt8(tok, radix: 16) else {
                hexError = "Bad byte: \"\(tok)\" — use hex pairs e.g. BC 13 02 00 00 55"
                return
            }
            bytes.append(val)
        }
        guard !bytes.isEmpty else { hexError = "Empty — enter hex bytes"; return }
        ble.sendRaw(bytes)
    }

    private func logView(lines: [String]) -> some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 140)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Live camera color monitor card
private struct LiveCameraCard: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live Camera", systemImage: "camera.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ble.liveHue >= 0 ? "Stop" : "Start") {
                    if ble.liveHue >= 0 { ble.stopLiveCamera() }
                    else { ble.startLiveCamera() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if ble.liveHue >= 0 {
                HStack(spacing: 12) {
                    // Detected color swatch
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hue: ble.liveHue, saturation: 1, brightness: 1))
                        .frame(width: 48, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                        .shadow(radius: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Hue").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                            Text(String(format: "%.0f°", ble.liveHue * 360))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        HStack {
                            Text("Bri").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                            Text(String(format: "%.0f%%", ble.liveBrightness * 100))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        // Hue arc indicator
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(LinearGradient(
                                        gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 1/12.0)
                                            .map { Color(hue: $0, saturation: 1, brightness: 1) }),
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(height: 6)
                                Circle()
                                    .fill(Color.white)
                                    .shadow(radius: 1)
                                    .frame(width: 10, height: 10)
                                    .offset(x: ble.liveHue * (geo.size.width - 10))
                            }
                        }
                        .frame(height: 10)
                    }
                }
                .animation(.easeInOut(duration: 0.1), value: ble.liveHue)
            } else {
                Text("Point iPhone at strip to read detected color")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Camera selector shown in the debug section.
// iPhone appears via Continuity Camera (macOS 14+) — must be nearby, same Apple ID.
// Tap ↺ to refresh the list after connecting iPhone.
private struct CameraPickerRow: View {
    @Environment(LightBLEManager.self) private var ble
    @State private var cameras: [AVCaptureDevice] = []

    private func icon(for cam: AVCaptureDevice) -> String {
        switch cam.deviceType {
        case .continuityCamera: return "iphone"
        case .external:         return "web.camera"
        default:                return "laptopcomputer"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Camera source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    cameras = CameraChangeDetector.availableCameras()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help("Refresh camera list (connect iPhone first)")
            }

            Picker("", selection: Binding(
                get: { ble.selectedCameraID },
                set: { ble.selectedCameraID = $0 }
            )) {
                Label("Auto (iPhone first)", systemImage: "wand.and.stars")
                    .tag(Optional<String>.none)
                if cameras.isEmpty {
                    Text("No cameras found — tap ↺").tag(Optional<String>.none)
                }
                ForEach(cameras, id: \.uniqueID) { cam in
                    Label(cam.localizedName, systemImage: icon(for: cam))
                        .tag(Optional(cam.uniqueID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if cameras.filter({ $0.deviceType == .continuityCamera }).isEmpty {
                Text("iPhone not detected — unlock iPhone & bring near Mac")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { cameras = CameraChangeDetector.availableCameras() }
    }
}

