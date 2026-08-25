import SwiftUI

extension LightBLEManager {

    // MARK: - Color history

    func recordColorHistory(_ h: Double, _ s: Double) {
        guard s > 0.05 else { return }   // skip near-whites
        colorHistory = ([(h, s)] + colorHistory.filter {
            abs($0.h - h) > 0.03 || abs($0.s - s) > 0.08
        }).prefix(12).map { $0 }
        let encoded = colorHistory.map { [$0.h, $0.s] }
        UserDefaults.standard.set(try? JSONEncoder().encode(encoded), forKey: "colorHistory")
    }

    // MARK: - Circadian auto color temperature

    func startCircadianTimer() {
        circadianTimer?.invalidate()
        applyCircadianCCT()
        circadianTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyCircadianCCT() }
        }
    }

    func stopCircadianTimer() {
        circadianTimer?.invalidate()
        circadianTimer = nil
    }

    func applyCircadianCCT() {
        guard circadianEnabled, connectionState == .connected, isOn, syncMode == .off else { return }
        setColorTemperature(Self.circadianCCTValue())
    }

    // Maps current time to a 0–1 CCT value (0=2700K warm, 1=6500K cool).
    static func circadianCCTValue(for date: Date = .now) -> Double {
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: date))
        let m = Double(cal.component(.minute, from: date))
        let t = h + m / 60.0        // 0…24
        switch t {
        case 6..<12:  return (t - 6) / 6.0
        case 12..<17: return 1.0
        case 17..<22: return 1.0 - (t - 17) / 5.0
        default:      return 0.0
        }
    }

    // MARK: - Color / brightness / effects

    // Preferred over setColor — avoids lossy Color→NSColor→getHue round-trip.
    func setHue(_ h: Double, saturation s: Double) {
        if syncMode != .off { stopSyncInline() }
        color = Color(hue: h, saturation: s, brightness: 1)
        UserDefaults.standard.set(h, forKey: "colorHue")
        UserDefaults.standard.set(s, forKey: "colorSat")
        recordColorHistory(h, s)
        audioPulseH = h
        effectModeActive = false
        fadeTask?.cancel()
        colorDebounce?.cancel()
        colorDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self.write(Cmd.hue(h, saturation: s))
            self.write(Cmd.brightness(self.brightness))
        }
    }

    func setColor(_ newColor: Color) {
        let (h, s, _) = newColor.hsvComponents
        setHue(h, saturation: s)
    }

    // Color temperature 0=warm 2700K … 1=cool 6500K.
    func setColorTemperature(_ t: Double) {
        let kelvin = 2700 + t * 3800
        let (h, s) = kelvinToHS(kelvin)
        setHue(h, saturation: s)
    }

    func kelvinToHS(_ k: Double) -> (Double, Double) {
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

    func setBrightness(_ value: Double) {
        if syncMode != .off { stopSyncInline() }
        brightness = value
        write(Cmd.brightness(value))
    }

    func setEffect(id: UInt8) {
        stopSyncInline()
        effectID = id
        effectModeActive = true
        write(Cmd.effect(id: id))
        write(Cmd.speed(effectSpeed))
    }

    func setEffectSpeed(_ value: Double) {
        effectSpeed = value
        write(Cmd.speed(value))
    }

    func exitEffectMode() {
        effectModeActive = false
        Task { @MainActor in
            // BC06 effects run in device firmware — power-cycle is the only reliable reset.
            self.write(Cmd.powerOff)
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.write(Cmd.powerOn)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let (h, s, _) = self.color.hsvComponents
            self.write(Cmd.hue(h, saturation: s))
            self.write(Cmd.brightness(self.brightness))
        }
    }
}
