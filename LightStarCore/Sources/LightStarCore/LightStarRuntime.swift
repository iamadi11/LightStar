import Foundation

/// Shared process-wide handles so AppIntents (macOS + iOS) can reach BLE without
/// knowing about AppDelegate / UIApplicationDelegate.
@MainActor
public enum LightStarRuntime {
    public static weak var ble: LightBLEManager?
    public static weak var presets: PresetStore?
    public static weak var schedules: ScheduleStore?

    public static func register(ble: LightBLEManager, presets: PresetStore, schedules: ScheduleStore) {
        self.ble = ble
        self.presets = presets
        self.schedules = schedules
        schedules.ble = ble
    }
}
