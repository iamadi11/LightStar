import SwiftUI
import AVFoundation

struct DebugTabView: View {
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
                    Button(ble.probeRunning ? "…" : "Segments") {
                        ble.probeSegments()
                    }
                    .disabled(ble.probeRunning)
                    .tint(.purple)
                    .help("Test per-LED / per-segment color — watch strip visually")
                    Button(ble.probeRunning ? "…" : "Anim Sweep") {
                        ble.sweepAnimations()
                    }
                    .disabled(ble.probeRunning)
                    .tint(.indigo)
                    .help("Sweep BC13 animation IDs to find audio beam — play music, watch strip")
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
struct LiveCameraCard: View {
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
struct CameraPickerRow: View {
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
