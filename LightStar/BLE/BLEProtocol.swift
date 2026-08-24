import SwiftUI

// MARK: - Command encoder (BC/55 protocol, confirmed via PacketLogger 2026-08-23)
// Frame: BC [cmd] [data_len] [data × data_len] 55

enum Cmd {
    // BC01: power. state=0x01 = ON, state=0x00 = OFF (confirmed by user 2026-08-23)
    // Miracles Star power-cycles on connect: sends OFF then ON as init reset
    static let powerOn:  [UInt8] = [0xBC, 0x01, 0x01, 0x01, 0x55]
    static let powerOff: [UInt8] = [0xBC, 0x01, 0x01, 0x00, 0x55]

    // BC04: hue (0–360°) + saturation (0–1000), big-endian 16-bit
    // Hue correction: strip's internal RGB mapping is non-linear.
    // LUT derived from color test 2026-08-23 + residual recal 2026-08-24:
    // (observed_display_deg, protocol_send_deg)
    // Inverts (sent→observed) pairs so user's intended color maps to correct protocol value.
    // 305-360° entries rederived from Phase 1 sweep residual errors (5-13° undershoot).
    private static let hueLUT: [(obs: Double, send: Double)] = [
        (0,   0), (8,   0), (20,  10), (32,  20), (41,  30), (60,  40),
        (89,  50), (109, 60), (123, 70), (135, 80), (145, 90),
        (149, 120),  // 100°-120° all display ~147-149°; send 120° as upper bound
        (173, 130), (188, 140), (198, 150), (203, 160), (206, 170),
        (209, 180), (212, 190), (215, 200), (217, 210), (220, 220),
        (222, 230), (226, 240), (229, 250), (239, 260), (247, 270),
        (252, 280), (255, 290), (259, 300), (264, 310), (269, 320),
        (276, 330), (286, 340),
        // Recalibrated from Phase 1 residuals — strip underperforms 5-13° in purple/magenta
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

    // BC05: brightness 100–1000 (min 100 observed in capture)
    static func brightness(_ value: Double) -> [UInt8] {
        let B = UInt16(max(100, min(1000, Int(100 + value * 900))))
        return [0xBC, 0x05, 0x06,
                UInt8(B >> 8), UInt8(B & 0xFF),
                0x00, 0x00, 0x00, 0x00, 0x55]
    }

    // BC06: select effect (IDs seen: 0x01, 0x03, 0x35)
    static func effect(id: UInt8) -> [UInt8] {
        [0xBC, 0x06, 0x02, 0x00, id, 0x55]
    }

    // BC08: effect speed 0–100
    static func speed(_ value: Double) -> [UInt8] {
        let s = UInt8(max(0, min(100, Int(value * 100))))
        return [0xBC, 0x08, 0x01, s, 0x55]
    }

    // BC13 animation ID 0 = stop / no animation (IDs 1–253 start firmware patterns)
    static let stopAnimation: [UInt8] = [0xBC, 0x13, 0x02, 0x00, 0x00, 0x55]

    // (BC0F mic-reactive mode intentionally not used — app drives color directly)
}

// MARK: - Color helper

extension Color {
    // Returns (hue: 0-1, saturation: 0-1, brightness: 0-1)
    var hsvComponents: (Double, Double, Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self))
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}
