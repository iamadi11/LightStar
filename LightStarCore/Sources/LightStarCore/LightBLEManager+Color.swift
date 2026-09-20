import SwiftUI

public extension LightBLEManager {

    // MARK: - Color history

    public func recordColorHistory(_ h: Double, _ s: Double) {
        guard s > 0.05 else { return }   // skip near-whites
        colorHistory = ([(h, s)] + colorHistory.filter {
            abs($0.h - h) > 0.03 || abs($0.s - s) > 0.08
        }).prefix(12).map { $0 }
        let encoded = colorHistory.map { [$0.h, $0.s] }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: "colorHistory")
        }
    }

    // MARK: - Circadian auto color temperature

    public func startCircadianTimer() {
        circadianTimer?.invalidate()
        applyCircadianCCT()
        circadianTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyCircadianCCT() }
        }
    }

    public func stopCircadianTimer() {
        circadianTimer?.invalidate()
        circadianTimer = nil
    }

    public func applyCircadianCCT() {
        guard circadianEnabled, connectionState == .connected, isOn, syncMode == .off else { return }
        setColorTemperature(ColorMath.circadianCCTValue())
    }

    public static func circadianCCTValue(for date: Date = .now) -> Double {
        ColorMath.circadianCCTValue(for: date)
    }

    // MARK: - Color / brightness / effects

    // Preferred over setColor — avoids lossy Color→NSColor→getHue round-trip.
    public func apply(preset: Preset) {
        if !isOn { setPower(on: true) }
        setColor(preset.color)
        setBrightness(preset.brightness)
    }

    public func setHue(_ h: Double, saturation s: Double) {
        if syncMode != .off { stopSyncInline() }
        colorHue = h
        colorSat = s
        color = Color(hue: h, saturation: s, brightness: 1)
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

    public func setColor(_ newColor: Color) {
        let (h, s, _) = newColor.hsvComponents
        setHue(h, saturation: s)
    }

    // Color temperature 0=warm 2700K … 1=cool 6500K.
    public func setColorTemperature(_ t: Double) {
        colorTemperature = t
        let kelvin = 2700 + t * 3800
        let (h, s) = kelvinToHS(kelvin)
        setHue(h, saturation: s)
    }

    public func kelvinToHS(_ k: Double) -> (Double, Double) {
        ColorMath.kelvinToHS(k)
    }

    public func setBrightness(_ value: Double) {
        if syncMode != .off { stopSyncInline() }
        brightness = value
        write(Cmd.brightness(value))
    }

    public func setEffect(id: UInt8) {
        stopSyncInline()
        effectID = id
        effectModeActive = true
        write(Cmd.effect(id: id))
        write(Cmd.speed(effectSpeed))
    }

    public func setEffectSpeed(_ value: Double) {
        effectSpeed = value
        write(Cmd.speed(value))
    }

    public func setEffectDirection(forward: Bool) {
        effectForward = forward
        write(Cmd.effectDirection(forward: forward))
    }

    public func exitEffectMode() {
        effectModeActive = false
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            // BC06 effects run in device firmware — power-cycle is the only reliable reset.
            self.write(Cmd.powerOff)
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard self.isOn else { return }
            self.write(Cmd.powerOn)
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard self.isOn else { return }
            let (h, s, _) = self.color.hsvComponents
            self.write(Cmd.hue(h, saturation: s))
            self.write(Cmd.brightness(self.brightness))
        }
    }
}
