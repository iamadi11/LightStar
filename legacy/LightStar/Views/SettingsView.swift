import SwiftUI
import AppKit
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

            Section("Scenes") {
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
        .frame(minWidth: 420, minHeight: 360)
        .padding()
    }
}

enum WindowActions {
    @MainActor static var openControl: (() -> Void)?
}

@MainActor func openLightStarSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

@MainActor func openLightStarControlWindow() {
    NSApp.activate(ignoringOtherApps: true)
    WindowActions.openControl?()
}
