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

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
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
    @MainActor static var closePopover: (() -> Void)?
}

@MainActor func openLightStarSettings() {
    WindowActions.closePopover?()
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

@MainActor func openLightStarControlWindow() {
    NSApp.activate(ignoringOtherApps: true)
    WindowActions.openControl?()
}
