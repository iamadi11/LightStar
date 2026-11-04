import SwiftUI
import Foundation

// MARK: - Preset

/// What a preset shows on the lightbar on top of its colour: one of an
/// effect, a WiZ scene, or per-segment colours.
public struct LightbarLook: Codable, Equatable, Sendable {
    /// Name of a `LampEffect.builtIn` effect.
    public var effect: String?
    /// WiZ scene id (1…32).
    public var scene: Int?
    /// One RGB triple per segment; [0, 0, 0] is off.
    public var segments: [[Int]]?
    /// The effect's colours when they weren't its own (custom colours).
    public var palette: [[Int]]?

    public init(effect: String? = nil, scene: Int? = nil, segments: [[Int]]? = nil, palette: [[Int]]? = nil) {
        self.effect = effect
        self.scene = scene
        self.segments = segments
        self.palette = palette
    }

    /// The look of a running effect: its name, plus its colours if custom.
    public init(effect: LampEffect) {
        let own = LampEffect.named(effect.name)?.palette
        self.init(effect: effect.name, palette: effect.palette == own ? nil : effect.palette.map { [$0.r, $0.g, $0.b] })
    }

    /// The effect this look runs, in its saved colours.
    public var lampEffect: LampEffect? {
        guard let effect else { return nil }
        return LampEffect.named(effect, palette: palette?.map { $0.count == 3 ? WizRGB(r: $0[0], g: $0[1], b: $0[2]) : .off })
    }

    public var segmentColours: [WizRGB]? {
        segments?.map { $0.count == 3 ? WizRGB(r: $0[0], g: $0[1], b: $0[2]) : .off }
    }
}

public struct Preset: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public var brightness: Double
    /// Optional so presets saved before the lightbar existed still decode.
    public var lightbar: LightbarLook?

    public var color: Color { Color(red: red, green: green, blue: blue) }

    public init(id: UUID = UUID(), name: String, red: Double, green: Double, blue: Double, brightness: Double,
                lightbar: LightbarLook? = nil) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
        self.lightbar = lightbar
    }

    public static let defaults: [Preset] = [
        Preset(name: "Reading", red: 1.0, green: 0.95, blue: 0.8, brightness: 1.0),
        Preset(name: "Movie",   red: 0.1, green: 0.0,  blue: 0.3, brightness: 0.3),
        Preset(name: "Party",   red: 1.0, green: 0.0,  blue: 0.5, brightness: 1.0),
        Preset(name: "Relax",   red: 0.8, green: 0.4,  blue: 0.1, brightness: 0.5),
    ]
}

