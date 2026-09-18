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
