import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Command encoder (BC/55 protocol, confirmed via APK reverse-engineering 2026-08-26)
// Frame: BC [cmd] [data_len] [data × data_len] 55
// Service: FFF0  Write char: FFF3  Notify char: FFF4 (device never sends notifications)

public enum Cmd {
    // BC01: power
    public static let powerOn:  [UInt8] = [0xBC, 0x01, 0x01, 0x01, 0x55]
    public static let powerOff: [UInt8] = [0xBC, 0x01, 0x01, 0x00, 0x55]

    public static func hue(_ h: Double, saturation s: Double) -> [UInt8] {
        let H = UInt16(max(0, min(360, Int(ColorMath.correctedHueDeg(h).rounded()))))
        let S = UInt16(max(0, min(1000, Int((s * 1000).rounded()))))
        return [0xBC, 0x04, 0x06,
                UInt8(H >> 8), UInt8(H & 0xFF),
                UInt8(S >> 8), UInt8(S & 0xFF),
                0x00, 0x00, 0x55]
    }

    // BC09: streaming color — same encoding as BC04 but used for rapid audio-reactive updates.
    // OEM app (com.frok.mrstar VoiceUtils.java) sends this at 200ms intervals during mic mode.
    public static func audioHue(_ h: Double, saturation s: Double) -> [UInt8] {
        let H = UInt16(max(0, min(360, Int(ColorMath.correctedHueDeg(h).rounded()))))
        let S = UInt16(max(0, min(1000, Int((s * 1000).rounded()))))
        return [0xBC, 0x09, 0x06,
                UInt8(H >> 8), UInt8(H & 0xFF),
                UInt8(S >> 8), UInt8(S & 0xFF),
                0x00, 0x00, 0x55]
    }

    // BC05: brightness 100–1000
    public static func brightness(_ value: Double) -> [UInt8] {
        let B = UInt16(max(100, min(1000, Int(100 + value * 900))))
        return [0xBC, 0x05, 0x06,
                UInt8(B >> 8), UInt8(B & 0xFF),
                0x00, 0x00, 0x00, 0x00, 0x55]
    }

    // BC06: select effect (58 IDs confirmed from ha-findn-led-ble 2026-08-26)
    public static func effect(id: UInt8) -> [UInt8] {
        [0xBC, 0x06, 0x02, 0x00, id, 0x55]
    }

    // BC07: effect direction (0=backward, 1=forward)
    public static func effectDirection(forward: Bool) -> [UInt8] {
        [0xBC, 0x07, 0x01, forward ? 0x01 : 0x00, 0x55]
    }

    // BC08: effect speed 0–255
    public static func speed(_ value: Double) -> [UInt8] {
        let s = UInt8(max(0, min(255, Int(value * 255))))
        return [0xBC, 0x08, 0x01, s, 0x55]
    }

    // BC0F: strip's onboard hardware microphone.
    // true  = strip uses its own mic (ambient-reactive, no phone involvement)
    // false = disable strip mic (app drives color via BC09 from phone mic)
    public static func stripMic(enabled: Bool) -> [UInt8] {
        [0xBC, 0x0F, 0x01, enabled ? 0x01 : 0x00, 0x55]
    }

    // BC11: mic-reactive style. Values from MicroPhoneFragment.java:
    //   1 = Classic,  2 = Soft,  3 = Dynamic,  4 = Disco
    public static func micStyle(_ style: UInt8) -> [UInt8] {
        [0xBC, 0x11, 0x01, style, 0x55]
    }

    // BC12: mic sensitivity 0–255
    public static func micSensitivity(_ value: Int) -> [UInt8] {
        [0xBC, 0x12, 0x01, UInt8(max(0, min(255, value))), 0x55]
    }

    // BC02: LED channel order 1=RGB … 6=BGR
    public static func channelOrder(_ order: UInt8) -> [UInt8] {
        [0xBC, 0x02, 0x01, order, 0x55]
    }

    // BC03: pixel count 16-bit BE, 8–300
    public static func pixelCount(_ count: Int) -> [UInt8] {
        let n = UInt16(max(8, min(300, count)))
        return [0xBC, 0x03, 0x02, UInt8(n >> 8), UInt8(n & 0xFF), 0x55]
    }

    // BC0B: time sync — yr-2000, mo, day, hr, min, sec, weekday bitmask (bit0=Mon)
    public static func timeSync(year: UInt8, month: UInt8, day: UInt8,
                         hour: UInt8, minute: UInt8, second: UInt8, weekdayMask: UInt8) -> [UInt8] {
        [0xBC, 0x0B, 0x07, year, month, day, hour, minute, second, weekdayMask, 0x55]
    }

    // BC0D: weekly firmware timer. Slot is the leading 0x01 seen in the APK capture.
    // dayMask uses the same OEM bitmask as BC0B (bit0=Mon … bit6=Sun).
    // Unused slots must be rewritten with enabled=false so a deleted Mac schedule
    // cannot keep firing on the strip.
    public static func weeklyTimer(slot: UInt8, powerOn: Bool, enabled: Bool,
                            dayMask: UInt8, hour: UInt8, minute: UInt8) -> [UInt8] {
        [0xBC, 0x0D, 0x06, slot, powerOn ? 0x01 : 0x00, enabled ? 0x01 : 0x00,
         dayMask, hour, minute, 0x55]
    }

    /// Conservative BC0D slot cap. OEM captures used slot 0x01; unused slots
    /// are rewritten disabled so deleted firmware schedules cannot keep firing.
    public static let weeklyTimerSlotCount: UInt8 = 8

    // BC13: firmware animation scene 0x00–0xFF minus 0x3D/0x5B/0x96
    public static func animation(id: UInt8) -> [UInt8] {
        [0xBC, 0x13, 0x01, id, 0x55]
    }
}

// MARK: - Known effect list (confirmed from ha-findn-led-ble APK reverse-engineering 2026-08-26)

public struct Effect: Identifiable, Sendable {
    public let name: String
    public let id: UInt8
    public var identifierForUI: UInt8 { id }
    public init(name: String, id: UInt8) {
        self.name = name
        self.id = id
    }
}

// Groups for EffectsView sectioning
public enum EffectGroup: String, CaseIterable, Sendable {
    case loop       = "Loop"
    case flutter    = "Fluttering"
    case brush      = "Brushing"
    case openClose  = "Opening / Closing"
    case transition = "Transition"
    case water      = "Flowing Water"
    case tailing    = "Tailing"
    case running    = "Running"
}

public let knownEffects: [(group: EffectGroup, effects: [Effect])] = [
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

public extension Color {
    var hsvComponents: (Double, Double, Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(AppKit)
        (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self))
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return (Double(h), Double(s), Double(b))
    }
}
