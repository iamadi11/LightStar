import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import LightStarCore

struct SettingsView: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(PresetStore.self) private var presets
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoConnectOnLaunch") private var autoConnectOnLaunch = true
    @AppStorage(AlexaHueBridge.enabledDefaultsKey) private var alexaBridgeEnabled = false
    @AppStorage(YeelightLampController.enabledDefaultsKey) private var yeelightMirrorEnabled = false
    @Environment(YeelightLampController.self) private var yeelight
    @Environment(HomeKitLampController.self) private var homeKitLamp
    @State private var lampSetupCode = ""

    private var isLampCodeEntry: Bool {
        switch homeKitLamp.state {
        case .needsCode, .failed, .pairing: return true
        default: return false
        }
    }

    private var lampStatusText: String {
        switch homeKitLamp.state {
        case .following(let name): return "Following with \(name)"
        case .needsCode: return "Enter the code on the lamp base"
        case .pairing: return "Connecting…"
        case .failed(let message): return message
        case .searching where yeelightMirrorEnabled: return "Looking for the lamp…"
        default:
            break
        }
        switch yeelight.state {
        case .stopped: return "Off"
        case .searching: return "Looking on the network…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .following(let name): return "Following with \(name)"
        case .notFound: return "Not found"
        case .failed(let message): return message
        }
    }

    private var yeelightStatusText: String {
        switch yeelight.state {
        case .stopped: return "Off"
        case .searching: return "Looking on the network…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .following(let name): return "Following with \(name)"
        case .notFound: return "Not found"
        case .failed(let message): return message
        }
    }

    private var alexaBridgeStatusText: String? {
        guard let bridge = (NSApp.delegate as? AppDelegate)?.alexaBridge else { return nil }
        switch bridge.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Running on port \(port)"
        case .error(let message): return "Error: \(message)"
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    .onChange(of: launchAtLogin) { _, enabled in
                        let succeeded: Bool
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            succeeded = true
                        } catch {
                            succeeded = false
                        }
                        let next = LaunchAtLoginSync.displayedEnabled(
                            requested: enabled,
                            succeeded: succeeded,
                            currentlyEnabled: SMAppService.mainApp.status == .enabled
                        )
                        if next != launchAtLogin { launchAtLogin = next }
                    }
                Toggle("Auto-connect on Launch", isOn: $autoConnectOnLaunch)
                Toggle("Multi-light (connect all nearby bars)", isOn: Binding(
                    get: { ble.multiLightEnabled },
                    set: { ble.multiLightEnabled = $0 }
                ))
                if ble.multiLightEnabled && ble.connectedLightNames.count > 1 {
                    Text(ble.connectedLightNames.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Strip") {
                Picker("Channel order", selection: Binding(
                    get: { ble.ledChannelOrder },
                    set: { ble.ledChannelOrder = $0 }
                )) {
                    ForEach(LightBLEManager.LEDChannelOrder.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                Stepper("LED count: \(ble.ledPixelCount)", value: Binding(
                    get: { ble.ledPixelCount },
                    set: { ble.ledPixelCount = $0 }
                ), in: 8...300)
            }

            Section("iPhone Remote") {
                if AXIsProcessTrusted() {
                    LabeledContent("Pointer & keyboard", value: "Enabled")
                } else {
                    Text("Trackpad and keyboard from the iPhone need Accessibility access.")
                        .foregroundStyle(.secondary)
                    Button("Enable in System Settings…") {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
                        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("Mi Bedside Lamp") {
                Toggle("Follow the light bar", isOn: $yeelightMirrorEnabled)
                    .onChange(of: yeelightMirrorEnabled) { _, enabled in
                        (NSApp.delegate as? AppDelegate)?.setYeelightMirrorEnabled(enabled)
                    }
                Text("Same colour, brightness, and power as the Bluetooth bar. The bar’s commands are not changed. Screen and music sync follow along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This lamp has no LAN Control switch. Xiaomi removed it. LightStar uses the 8-digit HomeKit code on the bottom of the lamp, and in the little booklet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Lamp", value: lampStatusText)
                if yeelightMirrorEnabled && isLampCodeEntry {
                    TextField("Code on the lamp base", text: $lampSetupCode)
                        .monospacedDigit()
                    Button("Connect lamp") {
                        homeKitLamp.connect(setupCode: lampSetupCode)
                    }
                    .disabled(lampSetupCode.filter(\.isNumber).count != 8)
                }
            }

            Section("Alexa") {
                Toggle("Echo Hue bridge", isOn: $alexaBridgeEnabled)
                    .onChange(of: alexaBridgeEnabled) { _, enabled in
                        (NSApp.delegate as? AppDelegate)?.setAlexaBridgeEnabled(enabled)
                    }
                Text("LightStar pretends to be a Philips Hue bridge on your LAN. Mac stays the BLE brain; Alexa only sends on/off, brightness, colour, and temperature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Setup: enable this toggle → allow Local Network for LightStar → open the Alexa app → Add Device → Philips Hue → Discover. Then: “Alexa, turn on LightStar”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = alexaBridgeStatusText {
                    LabeledContent("Bridge", value: status)
                }
            }

            Section("Scenes") {
                Toggle("Sync Presets via iCloud", isOn: Binding(
                    get: { presets.iCloudEnabled },
                    set: { presets.iCloudEnabled = $0 }
                ))
                .disabled(!presets.iCloudAvailable)
                HStack {
                    Button("Import…") { presets.importFromFile() }
                    Button("Export…") { presets.exportToFile() }
                    if presets.presets.isEmpty {
                        Button("Restore Defaults") {
                            presets.presets = Preset.defaults
                            presets.save()
                        }
                    }
                }
            }

            Section {
                Button("Quit LightStar", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(ble.stripAccent)
        .frame(minWidth: 420, minHeight: 360)
        .padding()
        .background {
            LightStarVisualEffect(material: .sidebar)
                .ignoresSafeArea()
        }
    }
}

enum WindowActions {
    @MainActor static var openControl: (() -> Void)?
    @MainActor static var openSettings: (() -> Void)?
    @MainActor static var closePopover: (() -> Void)?
}

@MainActor func openLightStarSettings() {
    WindowActions.closePopover?()
    WindowActions.openSettings?()
}

@MainActor func openLightStarControlWindow() {
    NSApp.activate(ignoringOtherApps: true)
    WindowActions.openControl?()
}
