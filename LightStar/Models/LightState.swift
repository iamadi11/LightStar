import SwiftUI

struct LightState {
    var isOn: Bool = false
    var color: Color = .white
    var brightness: Double = 1.0  // 0.0–1.0
    var effectMode: UInt8 = 0
    var effectSpeed: UInt8 = 5
}

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
