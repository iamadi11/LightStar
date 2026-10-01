import SwiftUI
import AppKit
import LightStarCore

struct LightStarVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Quiet section padding — no fill, no shadow, no gradient.
struct GlassCard<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum LightStarMotion {
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08)
    }

    static func snappy(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22)
    }
}

extension LightBLEManager {
    var stripAccent: Color {
        let stripLive = connectionState == .connected && outputTarget.sendsToStrip
        let lampLive = outputTarget.sendsToLamp
        guard isOn, stripLive || lampLive else {
            return Color.primary.opacity(0.35)
        }
        return syncColor ?? color
    }
}

struct LightTargetSection: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(HomeKitLampController.self) private var homeKitLamp
    @State private var lampSetupCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Control", selection: Binding(
                get: { ble.outputTarget },
                set: { ble.outputTarget = $0 }
            )) {
                ForEach(LightOutputTarget.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Which lights to control")

            if ble.outputTarget.sendsToStrip {
                stripRow
            }
            if ble.outputTarget.sendsToLamp {
                lampRow
            }
        }
    }

    private var stripRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightstrip.2")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(stripStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if ble.bleNeedsPermission {
                Button("Bluetooth Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .controlSize(.small)
            } else if ble.connectionState != .connected {
                Button(ble.connectionState == .scanning || ble.connectionState == .connecting ? "Cancel" : "Connect") {
                    if ble.connectionState == .scanning || ble.connectionState == .connecting {
                        ble.disconnect()
                    } else {
                        ble.connect()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var lampRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lamp.desk")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(lampStatus)
                    .font(.caption)
                    .foregroundStyle(lampFailed ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if lampNeedsCode {
                    Button("Connect") {
                        homeKitLamp.connect(setupCode: lampSetupCode)
                    }
                    .controlSize(.small)
                    .disabled(lampSetupCode.filter(\.isNumber).count != 8)
                }
            }
            if lampNeedsCode {
                TextField("Code on the lamp base", text: $lampSetupCode)
                    .monospacedDigit()
                    .onAppear { prefillCode() }
            }
        }
    }

    private var stripStatus: String {
        if let err = ble.connectionError { return err }
        switch ble.connectionState {
        case .connected: return ble.isOn ? "LED strip · On" : "LED strip · Off"
        case .scanning: return "Looking for the LED strip…"
        case .connecting: return "Connecting to the LED strip…"
        case .disconnected: return "LED strip not connected"
        }
    }

    private var lampStatus: String {
        switch homeKitLamp.state {
        case .following(let name): return "\(name) · Connected"
        case .pairing: return "Connecting to the lamp…"
        case .searching: return "Looking for the lamp…"
        case .needsCode: return "Enter the 8-digit code on the lamp base"
        case .failed(let message): return message
        case .stopped: return "Mi lamp"
        }
    }

    private var lampFailed: Bool {
        if case .failed = homeKitLamp.state { return true }
        return false
    }

    private var lampNeedsCode: Bool {
        switch homeKitLamp.state {
        case .needsCode, .failed: return true
        default: return false
        }
    }

    private func prefillCode() {
        guard lampSetupCode.isEmpty else { return }
        lampSetupCode = UserDefaults.standard.string(forKey: "homekitLampSetupCode") ?? ""
    }
}
