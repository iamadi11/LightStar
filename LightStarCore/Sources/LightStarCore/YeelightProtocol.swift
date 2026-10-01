import Foundation

/// What the strip was just told, in app units (hue and saturation 0…1, before the
/// strip hue LUT). The Wi-Fi lamp must not see the LUT or its colour drifts from
/// the bar.
public enum YeelightMirrorUpdate: Equatable, Sendable {
    case power(Bool)
    case color(hue: Double, saturation: Double)
    case brightness(Double)
}

public struct YeelightMirrorState: Equatable, Sendable {
    public var power: Bool?
    public var hue: Double?
    public var saturation: Double?
    public var brightness: Double?

    public init(power: Bool? = nil, hue: Double? = nil, saturation: Double? = nil, brightness: Double? = nil) {
        self.power = power
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    public mutating func apply(_ update: YeelightMirrorUpdate) {
        switch update {
        case .power(let on):
            power = on
        case .color(let hue, let saturation):
            self.hue = hue
            self.saturation = saturation
        case .brightness(let value):
            brightness = value
        }
    }
}

public struct YeelightAdvertisement: Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var model: String
    public var supportsHSV: Bool
    public var supportsMusic: Bool

    public var displayName: String {
        if !name.isEmpty { return name }
        if model.localizedCaseInsensitiveContains("lamp") { return "Mi Bedside Lamp" }
        return "Yeelight"
    }
}

public enum YeelightWireCommand: Equatable, Sendable {
    case power(Bool)
    case hsv(hue: Int, saturation: Int)
    case rgb(Int)
    case brightness(Int)
    case musicOn(host: String, port: UInt16)
    case musicOff
}

public enum YeelightColor {
    public static func hueDegrees(_ hue: Double) -> Int {
        guard hue.isFinite else { return 0 }
        var degrees = Int((hue * 360).rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    public static func saturationPercent(_ saturation: Double) -> Int {
        guard saturation.isFinite else { return 0 }
        return Int((max(0, min(1, saturation)) * 100).rounded())
    }

    /// Yeelight brightness is 1…100. Power-off is a separate command.
    public static func brightnessPercent(_ brightness: Double) -> Int {
        guard brightness.isFinite else { return 1 }
        return min(100, max(1, Int((max(0, min(1, brightness)) * 100).rounded())))
    }
}

public enum YeelightCommand {
    public static func encode(id: Int, _ command: YeelightWireCommand) -> String? {
        let params: String
        let method: String
        switch command {
        case .power(let on):
            method = "set_power"
            params = "\"\(on ? "on" : "off")\",\"sudden\",0"
        case .hsv(let hue, let saturation):
            method = "set_hsv"
            params = "\(hue),\(saturation),\"sudden\",0"
        case .rgb(let value):
            method = "set_rgb"
            params = "\(value),\"sudden\",0"
        case .brightness(let value):
            method = "set_bright"
            params = "\(value),\"sudden\",0"
        case .musicOn(let host, let port):
            guard host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else {
                return nil
            }
            method = "set_music"
            params = "1,\"\(host)\",\(port)"
        case .musicOff:
            method = "set_music"
            params = "0"
        }
        return "{\"id\":\(id),\"method\":\"\(method)\",\"params\":[\(params)]}\r\n"
    }
}

public enum YeelightFlush {
    /// Music mode may send every change. The normal socket is capped at one
    /// command per flush so a screen sync cannot trip the 60/minute quota.
    public static func commands(
        desired: YeelightMirrorState,
        sent: YeelightMirrorState,
        supportsHSV: Bool,
        musicMode: Bool
    ) -> [YeelightWireCommand] {
        var batch: [YeelightWireCommand] = []
        if let power = desired.power, power != sent.power {
            batch.append(.power(power))
        }
        if let hue = desired.hue, let saturation = desired.saturation {
            let nextHue = YeelightColor.hueDegrees(hue)
            let nextSat = YeelightColor.saturationPercent(saturation)
            let sentHue = sent.hue.map(YeelightColor.hueDegrees)
            let sentSat = sent.saturation.map(YeelightColor.saturationPercent)
            if nextHue != sentHue || nextSat != sentSat {
                if supportsHSV {
                    batch.append(.hsv(hue: nextHue, saturation: nextSat))
                } else {
                    batch.append(.rgb(rgbValue(hue: hue, saturation: saturation)))
                }
            }
        }
        if let brightness = desired.brightness {
            let next = YeelightColor.brightnessPercent(brightness)
            let previous = sent.brightness.map(YeelightColor.brightnessPercent)
            if next != previous {
                batch.append(.brightness(next))
            }
        }
        if musicMode || batch.count <= 1 { return batch }
        return Array(batch.prefix(1))
    }

    /// Full-scale RGB. Brightness stays on `set_bright` so it is not applied twice.
    static func rgbValue(hue: Double, saturation: Double) -> Int {
        let h = max(0, min(1, hue.isFinite ? hue : 0))
        let s = max(0, min(1, saturation.isFinite ? saturation : 0))
        let sector = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = 1 - s
        let q = 1 - f * s
        let t = 1 - (1 - f) * s
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (1, t, p)
        case 1: (r, g, b) = (q, 1, p)
        case 2: (r, g, b) = (p, 1, t)
        case 3: (r, g, b) = (p, q, 1)
        case 4: (r, g, b) = (t, p, 1)
        default: (r, g, b) = (1, p, q)
        }
        let R = Int((r * 255).rounded())
        let G = Int((g * 255).rounded())
        let B = Int((b * 255).rounded())
        return (R << 16) | (G << 8) | B
    }
}

public enum YeelightDiscovery {
    public static func parse(_ payload: String) -> YeelightAdvertisement? {
        let headers = headerMap(payload)
        guard let location = headers["location"]?.lowercased(), location.hasPrefix("yeelight://") else {
            return nil
        }
        let endpoint = location.dropFirst("yeelight://".count)
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<colon])
        guard let port = UInt16(endpoint[endpoint.index(after: colon)...]), !host.isEmpty else { return nil }
        let support = headers["support"] ?? ""
        let known = !support.isEmpty
        return YeelightAdvertisement(
            id: headers["id"] ?? "\(host):\(port)",
            name: headers["name"] ?? "",
            host: host,
            port: port,
            model: headers["model"] ?? "",
            supportsHSV: !known || support.contains("set_hsv"),
            supportsMusic: !known || support.contains("set_music")
        )
    }

    /// Same lamp as last time, otherwise a bedside lamp, otherwise the first reply.
    public static func choose(_ found: [YeelightAdvertisement], savedID: String?) -> YeelightAdvertisement? {
        if let savedID, let match = found.first(where: { $0.id == savedID }) { return match }
        if let lamp = found.first(where: { $0.model.localizedCaseInsensitiveContains("lamp") }) { return lamp }
        return found.first
    }

    static func headerMap(_ payload: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in payload.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }
}
