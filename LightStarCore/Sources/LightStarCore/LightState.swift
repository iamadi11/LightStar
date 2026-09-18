import SwiftUI
import Foundation

// MARK: - Preset

public struct Preset: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public var brightness: Double

    public var color: Color { Color(red: red, green: green, blue: blue) }

    public init(id: UUID = UUID(), name: String, red: Double, green: Double, blue: Double, brightness: Double) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
    }

    public static let defaults: [Preset] = [
        Preset(name: "Reading", red: 1.0, green: 0.95, blue: 0.8, brightness: 1.0),
        Preset(name: "Movie",   red: 0.1, green: 0.0,  blue: 0.3, brightness: 0.3),
        Preset(name: "Party",   red: 1.0, green: 0.0,  blue: 0.5, brightness: 1.0),
        Preset(name: "Relax",   red: 0.8, green: 0.4,  blue: 0.1, brightness: 0.5),
    ]
}

