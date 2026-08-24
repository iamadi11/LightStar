import SwiftUI
import Foundation

// MARK: - LightState

struct LightState: Codable {
    var isOn: Bool = false
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var brightness: Double = 1.0  // 0.0–1.0
    var effectMode: UInt8 = 0
    var effectSpeed: UInt8 = 5

    // ponytail: Color is not Codable, store RGB components instead
    var color: Color {
        get { Color(red: red, green: green, blue: blue) }
        set {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            (NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue))
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            red = Double(r); green = Double(g); blue = Double(b)
        }
    }
}

// MARK: - Preset

struct Preset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var red: Double
    var green: Double
    var blue: Double
    var brightness: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static let defaults: [Preset] = [
        Preset(name: "Reading", red: 1.0, green: 0.95, blue: 0.8, brightness: 1.0),
        Preset(name: "Movie",   red: 0.1, green: 0.0,  blue: 0.3, brightness: 0.3),
        Preset(name: "Party",   red: 1.0, green: 0.0,  blue: 0.5, brightness: 1.0),
        Preset(name: "Relax",   red: 0.8, green: 0.4,  blue: 0.1, brightness: 0.5),
    ]
}

