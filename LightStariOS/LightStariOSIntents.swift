import AppIntents
import LightStarCore
import SwiftUI

enum LSIntentError: Error, LocalizedError {
    case notConnected
    case presetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "LightStar is not connected to a light bar."
        case .presetNotFound(let n): return "No preset named \"\(n)\" found."
        }
    }
}

@MainActor
private func requireConnected() throws -> LightBLEManager {
    guard let ble = LightStarRuntime.ble, ble.connectionState == .connected else {
        throw LSIntentError.notConnected
    }
    return ble
}

struct PresetEntity: AppEntity {
    var id: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(id)") }
    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    nonisolated(unsafe) static var defaultQuery = PresetQuery()
}

struct PresetQuery: EntityQuery {
    @MainActor
    func entities(for ids: [String]) async throws -> [PresetEntity] {
        ids.compactMap { id in
            guard LightStarRuntime.presets?.presets.contains(where: { $0.name == id }) == true else { return nil }
            return PresetEntity(id: id)
        }
    }
    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        (LightStarRuntime.presets?.presets ?? []).map { PresetEntity(id: $0.name) }
    }
}

struct TurnOnLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn On LightStar"
    nonisolated(unsafe) static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: true)
        return .result()
    }
}

struct TurnOffLightIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Turn Off LightStar"
    nonisolated(unsafe) static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setPower(on: false)
        return .result()
    }
}

struct SetBrightnessIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Set LightStar Brightness"
    nonisolated(unsafe) static var openAppWhenRun: Bool = false
    @Parameter(title: "Brightness", default: 100, inclusiveRange: (0, 100))
    var brightness: Int
    @MainActor func perform() async throws -> some IntentResult {
        try requireConnected().setBrightness(Double(brightness) / 100.0)
        return .result()
    }
}

struct ApplyPresetIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Apply LightStar Preset"
    nonisolated(unsafe) static var openAppWhenRun: Bool = false
    @Parameter(title: "Preset")
    var preset: PresetEntity
    @MainActor func perform() async throws -> some IntentResult {
        guard let p = LightStarRuntime.presets?.presets.first(where: { $0.name == preset.id }) else {
            throw LSIntentError.presetNotFound(preset.id)
        }
        try requireConnected().apply(preset: p)
        return .result()
    }
}

struct LightStarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnLightIntent(), phrases: ["Turn on \(.applicationName)"], shortTitle: "Turn On", systemImageName: "lightbulb.fill")
        AppShortcut(intent: TurnOffLightIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Turn Off", systemImageName: "lightbulb")
        AppShortcut(intent: ApplyPresetIntent(), phrases: ["Set \(.applicationName) to \(\.$preset)"], shortTitle: "Apply Preset", systemImageName: "dial.max.fill")
        AppShortcut(intent: SetBrightnessIntent(), phrases: ["Set \(.applicationName) brightness"], shortTitle: "Set Brightness", systemImageName: "sun.max.fill")
    }
}
