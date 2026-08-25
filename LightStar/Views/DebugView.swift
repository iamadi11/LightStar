import SwiftUI

struct DebugTabView: View {
    @Environment(LightBLEManager.self) private var ble
    @State private var rawHex: String = "BC 06 00 55"
    @State private var hexError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Raw command sender ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Label("Raw BLE Command", systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("BC 06 00 55", text: $rawHex)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: rawHex) { _, _ in hexError = nil }
                    Button("Send") { sendHex() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let err = hexError {
                    Text(err).font(.system(size: 9)).foregroundStyle(.red)
                }

                // Quick-access known commands
                HStack(spacing: 6) {
                    Button("ON")  { ble.sendRaw([0xBC,0x01,0x01,0x01,0x55]) }
                    Button("OFF") { ble.sendRaw([0xBC,0x01,0x01,0x00,0x55]) }
                    Button("Status") { ble.sendRaw([0xBC,0x06,0x00,0x55]) }
                    Button("Stop Anim") { ble.sendRaw([0xBC,0x13,0x02,0x00,0x00,0x55]) }
                        .tint(.orange)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Divider()

            // ── Protocol dump ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Protocol Dump", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if ble.probeRunning {
                        Button("Cancel") {
                            ble.probeTask?.cancel()
                            ble.probeRunning = false
                            ble.notifyTapHandler = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.red)
                    } else {
                        Button("Run Dump") { ble.protocolDump() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(ble.connectionState != .connected)
                    }
                }

                if ble.probeRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Running — TX/RX logged below. Auto-saves to Desktop on finish.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                } else if ble.probeLog.isEmpty {
                    Text("Connect to strip, then Run Dump. Captures all TX/RX and saves to Desktop.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }

                if !ble.probeLog.isEmpty {
                    logView(lines: ble.probeLog)
                    if !ble.probeRunning {
                        Button("Clear") { ble.probeLog = [] }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // ── Device info ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Device Info", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !ble.deviceLog.isEmpty {
                        Button("Save") { ble.saveDeviceLog() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                if ble.deviceLog.isEmpty {
                    Text("Connect to strip to discover services")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
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
                hexError = "Bad byte: \"\(tok)\" — use hex pairs e.g. BC 06 00 55"
                return
            }
            bytes.append(val)
        }
        guard !bytes.isEmpty else { hexError = "Empty — enter hex bytes"; return }
        ble.sendRaw(bytes)
    }

    private func logView(lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("log")
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onChange(of: lines.count) { _, _ in
                proxy.scrollTo("log", anchor: .bottom)
            }
        }
    }
}
