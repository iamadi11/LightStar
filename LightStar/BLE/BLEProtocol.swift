import SwiftUI

// MARK: - Command encoder (BC/55 protocol, confirmed via APK reverse-engineering 2026-08-26)
// Frame: BC [cmd] [data_len] [data × data_len] 55
// Service: FFF0  Write char: FFF3  Notify char: FFF4 (device never sends notifications)

enum Cmd {
    // BC01: power
    static let powerOn:  [UInt8] = [0xBC, 0x01, 0x01, 0x01, 0x55]
    static let powerOff: [UInt8] = [0xBC, 0x01, 0x01, 0x00, 0x55]

    // BC04: static color — hue (0–360°) + saturation (0–1000), big-endian 16-bit
    // Hue correction LUT: strip's internal RGB mapping is non-linear.
    // Derived from color test 2026-08-23 + Phase 1 sweep residuals 2026-08-24.
    private static let hueLUT: [(obs: Double, send: Double)] = [
        (0,   0), (8,   0), (20,  10), (32,  20), (41,  30), (60,  40),
        (89,  50), (109, 60), (123, 70), (135, 80), (145, 90),
        (149, 120),
        (173, 130), (188, 140), (198, 150), (203, 160), (206, 170),
        (209, 180), (212, 190), (215, 200), (217, 210), (220, 220),
        (222, 230), (226, 240), (229, 250), (239, 260), (247, 270),
        (252, 280), (255, 290), (259, 300), (264, 310), (269, 320),
        (276, 330), (286, 340),
        (305, 351), (310, 353), (320, 355), (330, 357), (340, 358), (360, 360)
    ]

    private static func correctedHueDeg(_ h: Double) -> Double {
        let deg = (h * 360).truncatingRemainder(dividingBy: 360)
        for i in 0..<hueLUT.count - 1 {
            let lo = hueLUT[i], hi = hueLUT[i + 1]
            if deg >= lo.obs && deg <= hi.obs {
                let t = (hi.obs - lo.obs) < 0.001 ? 0.0
                      : (deg - lo.obs) / (hi.obs - lo.obs)
                return lo.send + t * (hi.send - lo.send)
            }
        }
        return deg
    }

    static func hue(_ h: Double, saturation s: Double) -> [UInt8] {
        let H = UInt16(max(0, min(360, Int(correctedHueDeg(h)))))
        let S = UInt16(max(0, min(1000, Int(s * 1000))))
        return [0xBC, 0x04, 0x06,
                UInt8(H >> 8), UInt8(H & 0xFF),
                UInt8(S >> 8), UInt8(S & 0xFF),
                0x00, 0x00, 0x55]
    }

    // BC09: streaming color — same encoding as BC04 but used for rapid audio-reactive updates.
    // OEM app (com.frok.mrstar VoiceUtils.java) sends this at 200ms intervals during mic mode.
    static func audioHue(_ h: Double, saturation s: Double) -> [UInt8] {
        let H = UInt16(max(0, min(360, Int(correctedHueDeg(h)))))
        let S = UInt16(max(0, min(1000, Int(s * 1000))))
        return [0xBC, 0x09, 0x06,
                UInt8(H >> 8), UInt8(H & 0xFF),
                UInt8(S >> 8), UInt8(S & 0xFF),
                0x00, 0x00, 0x55]
    }

    // BC05: brightness 100–1000
    static func brightness(_ value: Double) -> [UInt8] {
        let B = UInt16(max(100, min(1000, Int(100 + value * 900))))
        return [0xBC, 0x05, 0x06,
                UInt8(B >> 8), UInt8(B & 0xFF),
                0x00, 0x00, 0x00, 0x00, 0x55]
    }

    // BC06: select effect (58 IDs confirmed from ha-findn-led-ble 2026-08-26)
    static func effect(id: UInt8) -> [UInt8] {
        [0xBC, 0x06, 0x02, 0x00, id, 0x55]
    }

    // BC07: effect direction (0=backward, 1=forward)
    static func effectDirection(forward: Bool) -> [UInt8] {
        [0xBC, 0x07, 0x01, forward ? 0x01 : 0x00, 0x55]
    }

    // BC08: effect speed 0–255
    static func speed(_ value: Double) -> [UInt8] {
        let s = UInt8(max(0, min(255, Int(value * 255))))
        return [0xBC, 0x08, 0x01, s, 0x55]
    }

    // BC0F: strip's onboard hardware microphone.
    // true  = strip uses its own mic (ambient-reactive, no phone involvement)
    // false = disable strip mic (app drives color via BC09 from phone mic)
    static func stripMic(enabled: Bool) -> [UInt8] {
        [0xBC, 0x0F, 0x01, enabled ? 0x01 : 0x00, 0x55]
    }

    // BC11: mic-reactive style. Values from MicroPhoneFragment.java:
    //   1 = Classic,  2 = Soft,  3 = Dynamic,  4 = Disco
    static func micStyle(_ style: UInt8) -> [UInt8] {
        [0xBC, 0x11, 0x01, style, 0x55]
    }

    // BC12: mic sensitivity 0–255
    static func micSensitivity(_ value: Int) -> [UInt8] {
        [0xBC, 0x12, 0x01, UInt8(max(0, min(255, value))), 0x55]
    }
}

// MARK: - Known effect list (confirmed from ha-findn-led-ble APK reverse-engineering 2026-08-26)

struct Effect: Identifiable {
    let name: String
    let id: UInt8
    var identifierForUI: UInt8 { id }
}

// Groups for EffectsView sectioning
enum EffectGroup: String, CaseIterable {
    case loop       = "Loop"
    case flutter    = "Fluttering"
    case brush      = "Brushing"
    case openClose  = "Opening / Closing"
    case transition = "Transition"
    case water      = "Flowing Water"
    case tailing    = "Tailing"
    case running    = "Running"
}

let knownEffects: [(group: EffectGroup, effects: [Effect])] = [
    (.loop, [
        Effect(name: "Auto Loop",           id: 0x01),
        Effect(name: "Symphony",            id: 0x02),
        Effect(name: "Colorful Energy",     id: 0x03),
        Effect(name: "Colorful Jumps",      id: 0x04),
        Effect(name: "7 Colors Strobe",     id: 0x07),
        Effect(name: "7 Colors Gradient",   id: 0x0A),
    ]),
    (.flutter, [
        Effect(name: "Colorful",            id: 0x1A),
        Effect(name: "Red-Green-Blue",      id: 0x1B),
    ]),
    (.brush, [
        Effect(name: "Colorful",            id: 0x1D),
        Effect(name: "Red-Green-Blue",      id: 0x1E),
        Effect(name: "Yellow-Cyan-Purple",  id: 0x1F),
        Effect(name: "Colorful Pull",       id: 0x20),
    ]),
    (.openClose, [
        Effect(name: "7 Colors",            id: 0x23),
        Effect(name: "Red-Green-Blue",      id: 0x24),
        Effect(name: "Yellow-Cyan-Purple",  id: 0x25),
        Effect(name: "Red",                 id: 0x26),
        Effect(name: "Green",               id: 0x27),
        Effect(name: "Blue",                id: 0x28),
        Effect(name: "Yellow",              id: 0x29),
        Effect(name: "Cyan",                id: 0x2A),
        Effect(name: "Purple",              id: 0x2B),
        Effect(name: "White",               id: 0x2C),
    ]),
    (.transition, [
        Effect(name: "7 Colors",            id: 0x2D),
        Effect(name: "Blue-Red-Green",      id: 0x2E),
        Effect(name: "Violet-Green-Yellow", id: 0x2F),
        Effect(name: "Red",                 id: 0x30),
        Effect(name: "Green",               id: 0x31),
        Effect(name: "Blue",                id: 0x32),
        Effect(name: "Cyan",                id: 0x33),
        Effect(name: "Yellow",              id: 0x34),
        Effect(name: "Purple",              id: 0x35),
        Effect(name: "White",               id: 0x36),
    ]),
    (.water, [
        Effect(name: "7 Colors",            id: 0x37),
        Effect(name: "Blue-Green-Red",      id: 0x38),
        Effect(name: "Purple-Green-Yellow", id: 0x39),
        Effect(name: "Red-Green",           id: 0x3A),
        Effect(name: "Green-Blue",          id: 0x3B),
        Effect(name: "Yellow-Blue",         id: 0x3C),
        Effect(name: "Yellow-Cyan",         id: 0x3D),
        Effect(name: "Blue-Purple",         id: 0x3E),
    ]),
    (.tailing, [
        Effect(name: "7 Colors",            id: 0x4C),
        Effect(name: "Red",                 id: 0x4D),
        Effect(name: "Green",               id: 0x4E),
        Effect(name: "Blue",                id: 0x4F),
        Effect(name: "Yellow",              id: 0x50),
        Effect(name: "Cyan",                id: 0x51),
        Effect(name: "Purple",              id: 0x52),
        Effect(name: "White",               id: 0x53),
    ]),
    (.running, [
        Effect(name: "Red",                 id: 0x54),
        Effect(name: "Green",               id: 0x55),
        Effect(name: "Blue",                id: 0x56),
        Effect(name: "Yellow",              id: 0x57),
        Effect(name: "Cyan",                id: 0x58),
        Effect(name: "Purple",              id: 0x59),
        Effect(name: "White",               id: 0x5A),
        Effect(name: "7 Colors",            id: 0x5B),
        Effect(name: "Blue-Green-Red",      id: 0x5C),
        Effect(name: "Purple-Cyan-Yellow",  id: 0x5D),
    ]),
]

// MARK: - Color helper

extension Color {
    var hsvComponents: (Double, Double, Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self))
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}
