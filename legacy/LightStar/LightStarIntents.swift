import AppIntents
import LightStarCore
import AppKit
import SwiftUI

// MARK: - Errors

enum LSIntentError: Error, LocalizedError {
    case notConnected
    case presetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:          return "LightStar is not connected to a light bar."
        case .presetNotFound(let n): return "No preset named \"\(n)\" found."
        }
    }
}

// MARK: - Helpers

@MainActor
private func appDelegate() -> AppDelegate? { NSApp.delegate as? AppDelegate }

@MainActor
private func requireConnected() throws -> LightBLEManager {
    guard let ble = LightStarRuntime.ble ?? (NSApp.delegate as? AppDelegate)?.ble else {
        throw LSIntentError.notConnected
    }
    guard ble.connectionState == .connected else { throw LSIntentError.notConnected }
    return ble
}

// MARK: - Preset entity (enables Siri autocomplete for preset names)

struct PresetEntity: AppEntity {
    var id: String      // preset name
    var displayRepresentation: DisplayRepresentation { .init(title: "\(id)") }
    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    nonisolated(unsafe) static var defaultQuery = PresetQuery()
}

struct PresetQuery: EntityQuery {
    @MainActor
    func entities(for ids: [String]) async throws -> [PresetEntity] {
        let presets = LightStarRuntime.presets ?? appDelegate()?.presets
        return ids.compactMap { id in
            guard presets?.presets.contains(where: { $0.name == id }) == true
            else { return nil }
            return PresetEntity(id: id)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        (LightStarRuntime.presets ?? appDelegate()?.presets)?.presets.map { PresetEntity(id: $0.name) } ?? []
    }
}

// MARK: - Sync mode enum

enum SyncModeOption: String, AppEnum {
    case off, video, audio, combined

    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sync Mode"
    nonisolated(unsafe) static var caseDisplayRepresentations: [SyncModeOption: DisplayRepresentation] = [
        .off:      "Off",
        .video:    "Screen",
        .audio:    "Audio",
        .combined: "Video + Audio",
    ]

    var syncMode: LightBLEManager.SyncMode {
        switch self {
        case .off:      return .off
        case .video:    return .video
        case .audio:    return .audio
        case .combined: return .combined
        }
    }
}

// MARK: - Power

struct TurnOnLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn On LightStar"
    nonisolated(unsafe) static var description = IntentDescription("Turn on the LED light bar.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: true)
        return .result()
    }
}

struct TurnOffLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn Off LightStar"
    nonisolated(unsafe) static var description = IntentDescription("Turn off the LED light bar.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: false)
        return .result()
    }
}

// MARK: - Brightness

struct SetBrightnessIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Brightness"
    nonisolated(unsafe) static var description = IntentDescription("Set the brightness of the LED bar (0–100).")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @Parameter(title: "Brightness", description: "0 = dim, 100 = full",
               default: 100, inclusiveRange: (0, 100))
    var brightness: Int

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setBrightness(Double(brightness) / 100.0)
        return .result()
    }
}

// MARK: - Color

struct SetLightColorIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Color"
    nonisolated(unsafe) static var description = IntentDescription("Set the LED bar to a specific hue and saturation.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @Parameter(title: "Hue", description: "0–360°", default: 0, inclusiveRange: (0, 360))
    var hue: Int

    @Parameter(title: "Saturation", description: "0 = white, 100 = vivid", default: 100, inclusiveRange: (0, 100))
    var saturation: Int

    @MainActor func perform() async throws -> some IntentResult {
        let ble = try requireConnected()
        ble.setHue(Double(hue) / 360.0, saturation: Double(saturation) / 100.0)
        return .result()
    }
}

// MARK: - Color temperature

enum ColorTempOption: String, AppEnum {
    case warm, neutral, cool, energizing

    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Color Temperature"
    nonisolated(unsafe) static var caseDisplayRepresentations: [ColorTempOption: DisplayRepresentation] = [
        .warm:       "Warm (2700 K)",
        .neutral:    "Neutral (4000 K)",
        .cool:       "Cool (5500 K)",
        .energizing: "Energizing (6500 K)",
    ]

    var kelvin: Double {
        switch self {
        case .warm: return 2700
        case .neutral: return 4000
        case .cool: return 5500
        case .energizing: return 6500
        }
    }
}

struct SetColorTemperatureIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Color Temperature"
    nonisolated(unsafe) static var description = IntentDescription("Set the LED bar to a warm, neutral, or cool white.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @Parameter(title: "Temperature", default: ColorTempOption.neutral)
    var temperature: ColorTempOption

    @MainActor func perform() async throws -> some IntentResult {
        let ble = try requireConnected()
        ble.setColorTemperature((temperature.kelvin - 2700) / 3800)
        return .result()
    }
}

// MARK: - Sync

struct SetSyncModeIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Sync Mode"
    nonisolated(unsafe) static var description = IntentDescription("Enable or disable screen/audio sync.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @Parameter(title: "Mode", default: SyncModeOption.video)
    var mode: SyncModeOption

    @MainActor func perform() async throws -> some IntentResult {
        guard let ble = LightStarRuntime.ble ?? appDelegate()?.ble else { throw LSIntentError.notConnected }
        ble.setSyncMode(mode.syncMode)
        return .result()
    }
}

struct ToggleSyncIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Toggle LightStar Sync"
    nonisolated(unsafe) static var description = IntentDescription("Toggle screen/audio sync on or off.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().toggleSync()
        return .result()
    }
}

// MARK: - Presets

struct ApplyPresetIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Apply LightStar Preset"
    nonisolated(unsafe) static var description = IntentDescription("Apply a saved color preset — Reading, Movie, Party, Relax, or any custom preset.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let p = (LightStarRuntime.presets ?? appDelegate()?.presets)?.presets.first(where: { $0.name == preset.id })
        else { throw LSIntentError.presetNotFound(preset.id) }
        let ble = try requireConnected()
        ble.apply(preset: p)
        return .result()
    }
}

// MARK: - State query

struct GetLightStateIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Get LightStar State"
    nonisolated(unsafe) static var description = IntentDescription("Returns whether the light is on, its brightness (0–100), and current sync mode.")
    nonisolated(unsafe) static var openAppWhenRun: Bool = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let ble = appDelegate()?.ble else { throw LSIntentError.notConnected }
        let state = ble.isOn ? "on" : "off"
        let brightness = Int(ble.brightness * 100)
        let sync = ble.syncMode == .off ? "sync off" : "\(ble.syncMode.displayName) sync"
        return .result(value: "Light is \(state), brightness \(brightness)%, \(sync)")
    }
}

// MARK: - Focus Filter

struct LightStarFocusFilter: SetFocusFilterIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Adjust LightStar"
    nonisolated(unsafe) static var description = IntentDescription("Dim or warm the light when a Focus mode is active.")
    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "LightStar Focus Filter"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(brightness)% · \(colorTemperature.rawValue)")
    }

    @Parameter(title: "Brightness", description: "0 = dim, 100 = full", default: 80, inclusiveRange: (0, 100))
    var brightness: Int

    @Parameter(title: "Color Temperature", default: ColorTempOption.neutral)
    var colorTemperature: ColorTempOption

    @MainActor func perform() async throws -> some IntentResult {
        guard let ble = appDelegate()?.ble else { return .result() }
        ble.setBrightness(Double(brightness) / 100.0)
        ble.setColorTemperature((colorTemperature.kelvin - 2700) / 3800)
        return .result()
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct LightStarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnLightIntent(),
            phrases: [
                "Turn on \(.applicationName)",
                "Turn on my lights with \(.applicationName)",
            ],
            shortTitle: "Turn On",
            systemImageName: "lightbulb.fill"
        )
        AppShortcut(
            intent: TurnOffLightIntent(),
            phrases: [
                "Turn off \(.applicationName)",
                "Turn off my lights with \(.applicationName)",
            ],
            shortTitle: "Turn Off",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: [
                "Set \(.applicationName) to \(\.$preset)",
                "Switch \(.applicationName) to \(\.$preset) mode",
                "Activate \(\.$preset) mode on \(.applicationName)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "dial.max.fill"
        )
        AppShortcut(
            intent: ToggleSyncIntent(),
            phrases: [
                "Toggle \(.applicationName) sync",
                "Toggle sync on \(.applicationName)",
            ],
            shortTitle: "Toggle Sync",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SetSyncModeIntent(),
            phrases: [
                "Set \(.applicationName) to \(\.$mode) sync",
                "Enable \(\.$mode) sync on \(.applicationName)",
            ],
            shortTitle: "Set Sync Mode",
            systemImageName: "waveform.badge.magnifyingglass"
        )
        AppShortcut(
            intent: SetColorTemperatureIntent(),
            phrases: [
                "Set \(.applicationName) to \(\.$temperature)",
                "Make \(.applicationName) \(\.$temperature)",
            ],
            shortTitle: "Set Temperature",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Set \(.applicationName) brightness",
                "Adjust \(.applicationName) brightness",
            ],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max.fill"
        )
        AppShortcut(
            intent: GetLightStateIntent(),
            phrases: [
                "Is \(.applicationName) on",
                "Check \(.applicationName) status",
            ],
            shortTitle: "Get State",
            systemImageName: "info.circle"
        )
    }
}
