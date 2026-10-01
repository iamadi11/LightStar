import Foundation

/// Hue LUT, CCT synthesis, circadian curve — kept free of CoreBluetooth so tests
/// and both app targets can share the expensive calibration data.
public enum ColorMath {
    // Strip RGB→hue mapping is non-linear. Hand-calibrated 2026-08-23; purple/magenta
    // (305–360°) recalibrated 2026-08-24 after a 5–13° undershoot.
    public static let hueLUT: [(obs: Double, send: Double)] = [
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

    /// Hue of the winning histogram bin, shifted toward the heavier neighbour.
    /// A flat 10° bin centre is up to 5° off the pixels that actually voted.
    public static func screenHue(histogram: [Double], peak: Int) -> Double {
        let n = histogram.count
        guard n > 0, histogram.indices.contains(peak), histogram[peak] > 0 else { return 0 }
        let left = histogram[(peak - 1 + n) % n]
        let right = histogram[(peak + 1) % n]
        let center = histogram[peak]
        let denom = left - 2 * center + right
        var delta = 0.0
        if abs(denom) > 1e-9 {
            delta = min(0.5, max(-0.5, 0.5 * (left - right) / denom))
        }
        var hue = (Double(peak) + 0.5 + delta) / Double(n)
        if hue < 0 { hue += 1 }
        if hue >= 1 { hue -= 1 }
        return hue
    }

    public static func correctedHueDeg(_ h: Double) -> Double {
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

    public static func kelvinToHS(_ k: Double) -> (Double, Double) {
        let k = max(2700, min(6500, k))
        switch k {
        case ..<3350:
            let t = (k - 2700) / 650
            return (0.08 - t * 0.02, 0.8 - t * 0.5)
        case ..<5000:
            let t = (k - 3350) / 1650
            return (0.06 - t * 0.06, 0.3 - t * 0.3)
        default:
            let t = min(1.0, (k - 5000) / 1500)
            return (0.55 + t * 0.08, t * 0.25)
        }
    }

    /// 0 = 2700K warm, 1 = 6500K cool.
    public static func circadianCCTValue(for date: Date = .now) -> Double {
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: date))
        let m = Double(cal.component(.minute, from: date))
        let t = h + m / 60.0
        switch t {
        case 6..<12:  return (t - 6) / 6.0
        case 12..<17: return 1.0
        case 17..<22: return 1.0 - (t - 17) / 5.0
        default:      return 0.0
        }
    }
}
