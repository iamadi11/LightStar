import Foundation

/// Philips Hue ↔ LightStar colour conversions used by the Alexa Hue bridge.
public enum HueColorMapping: Sendable {

    /// Hue API brightness 1…254 → LightStar 0…1.
    public static func brightnessFromHueBri(_ bri: Int) -> Double {
        let clamped = max(1, min(254, bri))
        return Double(clamped) / 254.0
    }

    /// LightStar 0…1 → Hue API brightness 1…254.
    public static func hueBri(fromBrightness value: Double) -> Int {
        max(1, min(254, Int((value * 254.0).rounded())))
    }

    /// Hue API hue 0…65535 → LightStar hue 0…1.
    public static func hueFraction(fromHueHue hue: Int) -> Double {
        let clamped = max(0, min(65535, hue))
        return Double(clamped) / 65535.0
    }

    /// LightStar hue 0…1 → Hue API hue 0…65535.
    public static func hueHue(fromFraction value: Double) -> Int {
        max(0, min(65535, Int((value * 65535.0).rounded())))
    }

    /// Hue API sat 0…254 → LightStar sat 0…1.
    public static func saturationFromHueSat(_ sat: Int) -> Double {
        let clamped = max(0, min(254, sat))
        return Double(clamped) / 254.0
    }

    /// LightStar sat 0…1 → Hue API sat 0…254.
    public static func hueSat(fromSaturation value: Double) -> Int {
        max(0, min(254, Int((value * 254.0).rounded())))
    }

    /// Hue colour temperature in mireds → Kelvin for LightStar.
    public static func kelvin(fromMireds mireds: Int) -> Double {
        let clamped = max(153, min(500, mireds))
        return 1_000_000.0 / Double(clamped)
    }

    /// Kelvin → Hue mireds.
    public static func mireds(fromKelvin kelvin: Double) -> Int {
        let k = max(2000.0, min(6500.0, kelvin))
        return max(153, min(500, Int((1_000_000.0 / k).rounded())))
    }
}
