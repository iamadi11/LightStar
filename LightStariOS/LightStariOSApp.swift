import SwiftUI
import LightStarCore

@main
struct LightStariOSApp: App {
    @State private var ble = LightBLEManager()
    @State private var presets = PresetStore()
    @State private var schedules = ScheduleStore()

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .environment(ble)
                .environment(presets)
                .environment(schedules)
                .onAppear {
                    LightStarRuntime.register(ble: ble, presets: presets, schedules: schedules)
                    ble.onConnect = {
                        schedules.drainPendingActions()
                        schedules.pushFirmwareTimers()
                        guard ble.syncMode == .off,
                              let id = presets.defaultPresetID,
                              let preset = presets.presets.first(where: { $0.id == id })
                        else { return }
                        ble.setColor(preset.color)
                        ble.setBrightness(preset.brightness)
                    }
                    if UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true {
                        ble.connect()
                    }
                    schedules.reschedule()
                    schedules.fireDue()
                }
                .onOpenURL { _ in }
        }
    }
}
