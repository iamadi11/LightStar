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

/// Whether the lights chosen under Control can take a command right now.
@MainActor
enum LightReach {
    static func miLampReady(_ lamp: HomeKitLampController) -> Bool {
        if case .following = lamp.state { return true }
        return false
    }

    static func lightbarReady(_ bar: WizLampController) -> Bool {
        if case .following = bar.state { return true }
        return false
    }

    static func any(_ ble: LightBLEManager, miLamp: HomeKitLampController, lightbar: WizLampController) -> Bool {
        let target = ble.outputTarget
        return (target.sendsToStrip && ble.connectionState == .connected)
            || (target.sendsToMiLamp && miLampReady(miLamp))
            || (target.sendsToLightbar && lightbarReady(lightbar))
    }
}

extension LightBLEManager {
    /// Live colour, following sync. Read it only in small views (`LiveAccent`):
    /// whatever reads it redraws each time sync changes colour.
    var stripAccent: Color {
        guard lightsLive else { return Color.primary.opacity(0.35) }
        return syncColor ?? color
    }

    /// The chosen colour, for tinting whole windows; doesn't follow sync.
    var controlAccent: Color {
        lightsLive ? color : Color.primary.opacity(0.35)
    }

    private var lightsLive: Bool {
        let stripLive = connectionState == .connected && outputTarget.sendsToStrip
        return isOn && (stripLive || outputTarget.sendsToLamp)
    }
}

/// The live sync colour as a capsule, dot, or tinted symbol. Its own view so
/// only it redraws when the colour moves, not the window around it.
struct LiveAccent<Content: View>: View {
    @Environment(LightBLEManager.self) private var ble
    @ViewBuilder var content: (Color) -> Content

    var body: some View { content(ble.stripAccent) }
}

struct LightTargetSection: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(HomeKitLampController.self) private var homeKitLamp
    @Environment(WizLampController.self) private var wizLamp
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

            if ble.outputTarget == .both {
                allLightsRow
            }

            if ble.outputTarget.sendsToStrip {
                stripRow
            }
            if ble.outputTarget.sendsToMiLamp {
                lampRow
            }
            if ble.outputTarget.sendsToLightbar {
                lightbarRow
            }
        }
    }

    /// The lights "All" runs. The last one can't be unticked.
    private var allLightsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(LightOutputTarget.allChoices) { light in
                    Toggle(light.title, isOn: Binding(
                        get: { ble.allLights.contains(light) },
                        set: { on in
                            if on { ble.allLights.insert(light) } else { ble.allLights.remove(light) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(ble.allLights == [light])
                }
            }
            // Each WiZ light on its own, once there is more than one.
            if ble.allLights.contains(.lightbar), wizLamp.lights.count > 1 {
                HStack(spacing: 12) {
                    ForEach(wizLamp.lights) { light in
                        Toggle(light.name, isOn: Binding(
                            get: { light.enabled },
                            set: { wizLamp.setLight(light.mac, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                    }
                }
            }
        }
        .accessibilityLabel("Lights that All controls")
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

    private var lightbarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lamp.floor")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(lightbarStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch wizLamp.state {
            case .notFound:
                Button("Search Again") { wizLamp.searchAgain() }
                    .controlSize(.small)
            case .blocked:
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    private var lightbarStatus: String {
        switch wizLamp.state {
        case .following(let name): return "\(name) · Connected"
        case .searching: return "Looking for the lightbar…"
        case .notFound: return "No lightbar found. Check it's on the same Wi-Fi."
        case .blocked: return "macOS is blocking the local network. Allow LightStar under Privacy & Security → Local Network."
        case .stopped: return "Lightbar"
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
