import Foundation

/// Screen zones → lightbar frame. Runs on the capture queue, so the lightbar
/// gets each frame without waiting for the main thread (the UI, the strip,
/// audio). The main thread keeps `settings` current and uses the same pipe for
/// repaints after a settings change, so both share one smoother.
public final class LampZonePipe: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        /// Screen sync running, lights on, lightbar chosen with gradient sync.
        public var active = false
        public var responsiveness = 0.7
        public var brightness = 1.0
        /// Combined mode: the music's level, when it has one, sets brightness.
        public var musicLevel: Double?
        public init() {}
    }

    public struct Frame: Sendable {
        public var zones: [WizRGB]
        /// Edge colours for plain bulbs; nil hands them the lightbar's colour.
        public var sides: [LampGradient.Side: WizRGB]?
    }

    private let lock = NSLock()
    private var settings = Settings()
    private var zoneSmoother = LampZoneSmoother()
    private var sideSmoother = LampZoneSmoother()
    private var lastFrame = -Double.infinity
    private var eased: [WizRGB]?
    private var output: (@Sendable (Frame) -> Void)?

    public init() {}

    public func setOutput(_ output: (@Sendable (Frame) -> Void)?) {
        lock.lock(); self.output = output; lock.unlock()
    }

    public func update(_ change: (inout Settings) -> Void) {
        lock.lock()
        change(&settings)
        if !settings.active { eased = nil }
        lock.unlock()
    }

    /// Last eased zones at full brightness, for Combined's beat pulse between frames.
    public var easedZones: [WizRGB]? {
        lock.lock(); defer { lock.unlock() }
        return eased
    }

    /// Makes and sends one frame. `sides` is only read when a frame goes out.
    public func push(_ zones: [WizRGB], sides: () -> [LampGradient.Side: WizRGB], now: Double = ProcessInfo.processInfo.systemUptime) {
        // Sent under the lock: once `update` turns the pipe off, no frame
        // already in flight can reach the lightbar after it was handed back.
        lock.lock(); defer { lock.unlock() }
        guard let frame = process(zones, sides: sides, now: now) else { return }
        output?(frame)
    }

    /// Caller holds the lock.
    private func process(_ zones: [WizRGB], sides: () -> [LampGradient.Side: WizRGB], now: Double) -> Frame? {
        guard settings.active, LampGradient.enabled, !zones.isEmpty else { return nil }
        // Just under the 30 fps capture gap; at exactly 1/30 jitter dropped every other frame.
        guard now - lastFrame >= 1.0 / 45.0 else { return nil }
        lastFrame = now
        let profile = LightbarProfile.active
        let boost = LampGradient.colourBoost
        // Games land every frame at once; other apps ease as the slider says.
        let alpha = profile == .game ? 1 : settings.responsiveness
        var target = LampGradient.boosted(zones, by: boost)
        if profile == .work {
            let white = LampGradient.dayWhite()
            target = Array(repeating: WizRGB(hue: white.hue, saturation: white.saturation), count: zones.count)
        }
        let smoothed = zoneSmoother.next(target, alpha: alpha)
        eased = smoothed
        let level = settings.musicLevel ?? settings.brightness
        var frame = Frame(zones: LampGradient.scaled(smoothed, by: level), sides: nil)
        // Plain bulbs placed around the screen show their edge; with the
        // work light they take the lightbar's colour instead.
        if profile != .work {
            let found = sides()
            if !found.isEmpty {
                let order = LampGradient.Side.allCases.filter { $0 != .whole }
                let raw = LampGradient.boosted(order.map { found[$0] ?? .off }, by: boost)
                let lit = LampGradient.scaled(sideSmoother.next(raw, alpha: alpha), by: level)
                frame.sides = Dictionary(uniqueKeysWithValues: zip(order, lit))
            }
        }
        return frame
    }
}
