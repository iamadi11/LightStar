import Foundation

public extension LightBLEManager {
    /// Run an effect across the lightbar (nil stops it). Effects and sync both
    /// drive the lightbar's segments, so starting one stops the other. Speed
    /// is the strip's effect speed; brightness is applied live.
    func setLampEffect(_ effect: LampEffect?, followsStrip: Bool = false) {
        lampEffectTask?.cancel()
        lampEffectTask = nil
        let wasRunning = lampEffect != nil
        lampEffect = effect
        lampEffectFollowsStrip = effect != nil && followsStrip
        guard let effect else {
            if wasRunning { onLampZones?(nil, nil) }
            return
        }
        if syncMode != .off { stopSyncInline() }
        let start = Date()
        lampEffectTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = LampGradient.colourCount(for: LampGradient.Placement(), segments: LampGradient.segmentCount)
                let frame = effect.frame(time: Date().timeIntervalSince(start), speed: self.effectSpeed, count: count)
                self.onLampZones?(LampGradient.scaled(frame, by: self.brightness), nil)
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            }
        }
    }

    /// A strip effect picked with the lightbar chosen: run its lightbar version.
    func followStripEffect(id: UInt8) {
        guard outputTarget.sendsToLightbar else { return }
        for (group, effects) in knownEffects {
            if let effect = effects.first(where: { $0.id == id }) {
                setLampEffect(.matching(effect, in: group), followsStrip: true)
                return
            }
        }
    }
}
