import AppIntents
import AppKit
import SwiftUI

// MARK: - Errors

enum LSIntentError: Error, LocalizedError {
    case notConnected
    case presetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:      return "LightStar is not connected to a light bar."
        case .presetNotFound(let n): return "No preset named \"\(n)\" found."
        }
    }
}

// MARK: - Helpers

@MainActor
private func appDelegate() -> AppDelegate? {
    NSApp.delegate as? AppDelegate
}

@MainActor
private func requireConnected() throws -> LightBLEManager {
    guard let d = appDelegate() else { throw LSIntentError.notConnected }
    guard d.ble.connectionState == .connected else { throw LSIntentError.notConnected }
    return d.ble
}

// MARK: - Power

struct TurnOnLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn On LightStar"
    nonisolated(unsafe) static var description = IntentDescription("Turn on the LED light bar.")

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: true)
        return .result()
    }
}

struct TurnOffLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn Off LightStar"
    nonisolated(unsafe) static var description = IntentDescription("Turn off the LED light bar.")

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: false)
        return .result()
    }
}

// MARK: - Brightness

struct SetBrightnessIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Brightness"
    nonisolated(unsafe) static var description = IntentDescription("Set the brightness of the LED bar (0–100).")

    @Parameter(title: "Brightness", description: "0 = off, 100 = full", default: 100,
                inclusiveRange: (lowerBound: 0, upperBound: 100))
    var brightness: Int

    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setBrightness(Double(brightness) / 100.0)
        return .result()
    }
}

// MARK: - Color

struct SetLightColorIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Color"
    nonisolated(unsafe) static var description = IntentDescription("Set the LED bar to a specific color.")

    @Parameter(title: "Hue", description: "0–360 degrees", default: 0,
                inclusiveRange: (lowerBound: 0, upperBound: 360))
    var hue: Int

    @Parameter(title: "Saturation", description: "0 = white, 100 = vivid", default: 100,
                inclusiveRange: (lowerBound: 0, upperBound: 100))
    var saturation: Int

    @MainActor func perform() async throws -> some IntentResult {
        let ble = try requireConnected()
        ble.setHue(Double(hue) / 360.0, saturation: Double(saturation) / 100.0)
        return .result()
    }
}

// MARK: - Sync

struct ToggleSyncIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Toggle LightStar Sync"
    nonisolated(unsafe) static var description = IntentDescription("Toggle screen/audio sync on or off.")

    @MainActor func perform() async throws -> some IntentResult {
        appDelegate()?.ble.toggleSync()
        return .result()
    }
}

// MARK: - Presets

struct ApplyPresetIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Apply LightStar Preset"
    nonisolated(unsafe) static var description = IntentDescription("Apply a saved color preset by name.")

    @Parameter(title: "Preset Name")
    var presetName: String

    @MainActor func perform() async throws -> some IntentResult {
        guard let d = appDelegate() else { throw LSIntentError.notConnected }
        guard let preset = d.presets.presets.first(where: {
            $0.name.localizedCaseInsensitiveCompare(presetName) == .orderedSame
        }) else {
            throw LSIntentError.presetNotFound(presetName)
        }
        let ble = try requireConnected()
        if !ble.isOn { ble.setPower(on: true) }
        ble.setColor(preset.color)
        ble.setBrightness(preset.brightness)
        return .result()
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct LightStarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnLightIntent(),  phrases: ["Turn on \(.applicationName)"])
        AppShortcut(intent: TurnOffLightIntent(), phrases: ["Turn off \(.applicationName)"])
        AppShortcut(intent: ToggleSyncIntent(),   phrases: ["Toggle \(.applicationName) sync"])
    }
}
