#if canImport(Metal)
import Metal
import QuartzCore
import CoreGraphics
import Observation
import os

private let canvasLog = Logger(subsystem: "com.adityaraj.LightStar", category: "canvas")

/// What the Canvas UI shows; changes a few times a second at most, never per frame.
@MainActor @Observable
public final class CanvasStatus {
    /// A short message ("Discovered: Whirlpool"), cleared after a few seconds.
    public internal(set) var toast: String?
    public internal(set) var players = 0
    public internal(set) var wellCount = 0
    public internal(set) var inhaling = false
    /// Seconds left in a mood or breathing session.
    public internal(set) var sessionRemaining: TimeInterval?
    public internal(set) var found = CanvasDiscovery.found
    public init() {}
}

/// Owns the Canvas for the whole app: steps the liquid at a fixed 240 Hz,
/// turns every way of playing (stirs, taps, wells, tilt, music, breathing,
/// several phones) into pushes and colour, renders it, and, while canvas mode
/// drives the lights, reads a 48×27 copy of each frame for them. No screen
/// capture: the lights get exactly what the canvas draws, window open or not.
@MainActor
public final class CanvasEngine {
    public static let stepsPerSecond = 240
    /// Lights read the canvas this often.
    static let lightRate = 30.0
    public static let lightSize = (width: 48, height: 27)
    /// Stir mode plays a newly picked animation this long, so the pick shows.
    static let previewSeconds = 4.0
    /// Stir mode starts carrying on by itself this long after the last touch.
    static let idleAfter = 12.0
    public static let breatheMinutesKey = "canvasBreatheMinutes"

    public let sim: FluidSimulation?
    public let renderer: CanvasRenderer?
    private let queue: MTLCommandQueue?
    public let status = CanvasStatus()
#if os(macOS)
    /// Soft tones; set by the app (tests never start audio).
    public var sound: CanvasSound?
#endif

    private(set) var pilot = FluidAutoPilot(style: .stored)
    public private(set) var mode = CanvasMode.stored
    public private(set) var style = CanvasStyle.stored
    public private(set) var symmetry = CanvasSymmetry.stored
    public private(set) var mood = CanvasMood.stored
    private(set) var previewUntil = 0.0
    /// Reduce Motion: slower animations (the app sets 0.4).
    public var motionScale = 1.0 { didSet { applySettings() } }
    /// EDR headroom of the window's screen; the view keeps it current.
    public var headroom: Float = 1

    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval?
    private var unsimulated = 0.0
    private var hueWalk = 0.0

    // Play state.
    public private(set) var wells = CanvasWells()
    private var phoneTilt = SIMD2<Double>(0, 0), phoneTiltAt = -Double.infinity
    private var keyTilt = SIMD2<Double>(0, 0)
    private var lastUserInput = -Double.infinity
    private var gestures: [String: CanvasGestureDetector] = [:]
    private var players: [String: Double] = [:]
    private var lastChorus = -Double.infinity
    private var holdStart: Double?
    private var flash = FlashLimiter()
    private var flashBoost = 0.0
    private var pendingBurst = SIMD4<Float>(0, 0, 0, 0)
    private var bands = (bass: 0.0, mid: 0.0, high: 0.0, rms: 0.0, flux: 0.0)
    private var lastBass = 0.0
    private var musicPulse = 0.0
    private var pacer = BreathPacer()
    private var breatheStart = CACurrentMediaTime()
    private var wasInhaling = false
    private var moodStart: Double?
    private var toastUntil = 0.0
    private var lastStatusTick = 0.0

    /// A 48×27 BGRA frame (bytes, bytes per row), on a Metal completion
    /// thread, while `drivesLights` is on.
    public var onLightFrame: (@Sendable ([UInt8], Int) -> Void)?
    /// Music mode wants the Mac's sound (the app runs the audio tap).
    public var onNeedsAudio: ((Bool) -> Void)?
    /// A mood's session ran out (Wind-down: the app turns the lights off).
    public var onMoodEnded: ((CanvasMood) -> Void)?
    /// Something the phone shows changed (players, wells, discoveries, mode).
    public var onStateChange: (() -> Void)?
    /// Canvas mode: keep the liquid running for the lights, window or not.
    public var drivesLights = false { didSet { updateTimer(); updateAudioNeed() } }
    /// The window draws frames itself while it's visible.
    public var viewIsShowing = false { didSet { updateTimer(); updateAudioNeed() } }
    private var audioRunning = false
    private var timer: Timer?
    private var lightTargets: [MTLTexture] = []
    private var lightIndex = 0
    private var lastLightFrame = 0.0
    private var sized = false
    private var lastSize: CGSize?

    private var frames = 0, simSteps = 0, statsFrom = CACurrentMediaTime()
    /// Average GPU time per frame over the last two seconds (the view paces itself by it).
    public private(set) var recentGPUms = 0.0
    private let gpuTime = OSAllocatedUnfairLock(initialState: (total: 0.0, count: 0))

    public init() {
        sim = FluidSimulation()
        renderer = sim.flatMap { CanvasRenderer(device: $0.device) }
        queue = sim?.device.makeCommandQueue()
        if let device = sim?.device {
            lightTargets = (0..<3).compactMap { _ in
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.lightSize.width,
                                                                 height: Self.lightSize.height, mipmapped: false)
                d.usage = [.renderTarget]
                d.storageMode = .shared
                return device.makeTexture(descriptor: d)
            }
        }
        pacer = BreathPacer(breathsPerMinute: UserDefaults.standard.object(forKey: BreathPacer.defaultsKey) as? Double ?? 6)
        applySettings()
        if mood != .none { moodStart = CACurrentMediaTime() }
    }

    private var now: Double { CACurrentMediaTime() }

    /// After a pause, the next frame mustn't count the paused time as one long step.
    public func resetClock() { last = nil }

    // MARK: - Settings

    /// Picks up the stored animation, mode, symmetry and mood (the Canvas
    /// section, the window's controls, the phone all write the same defaults).
    public func applySettings() {
        let style = CanvasStyle.stored
        let mode = CanvasMode.stored
        mood = CanvasMood.stored
        symmetry = CanvasSymmetry.stored
        pilot = FluidAutoPilot(style: style, speedScale: motionScale * mood.pace)
        // Stir mode never moves by itself, so a new pick would look like nothing happened.
        if style != self.style { previewUntil = now + Self.previewSeconds }
        if mode != self.mode {
            if mode == .breathe { breatheStart = now }
            // A new mode pours for a moment too, so there is colour to play with.
            previewUntil = now + Self.previewSeconds
        }
        self.style = style
        self.mode = mode
        updateAudioNeed()
        guard let sim else { return }
        let look = style.look
        sim.settings.curl = look.curl
        sim.settings.dyeDissipation = look.dyeDissipation
        sim.settings.velocityDissipation = look.velocityDissipation
        switch mode {
        case .breathe:
            // A pulse: each breath's colour fades by the next instead of piling up.
            sim.settings.dyeDissipation = max(1.1, look.dyeDissipation)
        case .tilt:
            // Liquid in a glass: colour keeps, and calmer flow pools and sloshes rather than churns.
            sim.settings.dyeDissipation = 0.06
            sim.settings.velocityDissipation = max(0.9, look.velocityDissipation)
            sim.settings.curl = min(look.curl, 6)
        default:
            break
        }
        onStateChange?()
    }

    /// Sets a mood's mode, look and symmetry, and starts its session clock.
    public func applyMood(_ mood: CanvasMood) {
        let d = UserDefaults.standard
        d.set(mood.rawValue, forKey: CanvasMood.defaultsKey)
        if let p = mood.preset {
            d.set(p.mode.rawValue, forKey: CanvasMode.defaultsKey)
            d.set(p.style.rawValue, forKey: CanvasStyle.defaultsKey)
            d.set(p.symmetry, forKey: CanvasSymmetry.defaultsKey)
            d.set(p.sessionMinutes, forKey: CanvasMood.sessionDefaultsKey)
        }
        moodStart = mood == .none ? nil : now
        applySettings()
    }

    /// After the quality setting changes, or the window shows or hides:
    /// rebuild at the right size.
    public func applyQuality() {
        if let lastSize { resize(lastSize) }
    }

    /// The window closed: lights only from now on, on the small canvas
    /// (merely covering the window keeps the picture as it is).
    public func windowClosed() {
        viewIsShowing = false
        lastSize = nil
        if sized { resize(Self.lightsOnlySize) }
    }

    /// Lights only (no window): they read 48×27, so a small 16:9 canvas is plenty.
    static let lightsOnlySize = CGSize(width: 480, height: 270)

    /// Size the canvas for a view's drawable.
    public func resize(_ size: CGSize) {
        guard let sim, size.width > 0, size.height > 0 else { return }
        if size != Self.lightsOnlySize { lastSize = size }
        // Lights only (no window) never needs more than a small canvas.
        let quality = size == Self.lightsOnlySize ? .native : CanvasQuality.stored
        sim.settings.dyeResolution = quality.colourResolution(screen: Int(min(size.width, size.height)))
        sim.resize(width: Int(size.width), height: Int(size.height))
        sized = true
        if let dye = sim.dyeTexture {
            // Fewer, brighter particles read as silk strands; many dim ones read as haze (and cost ~1 ms per 100k at 4K).
            let budget = size == Self.lightsOnlySize ? 20_000 : (quality == .uhd ? 160_000 : 100_000)
            renderer?.prepare(dyeWidth: dye.width, dyeHeight: dye.height, particles: budget)
        }
    }

    // MARK: - Input

    private var cells: Double { Double(sim?.settings.simResolution ?? 256) }
    private var aspect: Double { Double(sim?.canvasAspect ?? 16 / 9) }

    private func noteInput() { lastUserInput = now }

    private func colour(hue: Double, _ scale: Double) -> SIMD3<Float> {
        FluidAutoPilot.rgb(hue: hue) * Float(scale)
    }

    /// The next stir colour: the animation's palette, walked slowly.
    private func nextPaletteHue() -> Double {
        hueWalk = (hueWalk + 0.004).truncatingRemainder(dividingBy: 1)
        return pilot.paletteHue(hueWalk)
    }

    private func addUser(_ s: FluidSplat) {
        let copies = CanvasSymmetry.expand(s, folds: symmetry, aspect: aspect)
        // Twelve copies at full strength flood the canvas in seconds; thin
        // each one so the kaleidoscope adds pattern, not just more paint.
        let thin = Float(pow(Double(copies.count), -0.75))
        sim?.add(copies.map { FluidSplat(x: $0.x, y: $0.y, dx: $0.dx, dy: $0.dy, color: $0.color * thin, radius: $0.radius) })
    }

    /// A drag from `a` to `b` (0…1, y down) stirs the liquid and adds colour.
    /// `pressure` 0…1 (Force Touch adds more), `player` is a phone's id
    /// (its own colour), `pointer` keeps each finger's gesture separate.
    public func stir(from a: CGPoint, to b: CGPoint, pressure: Double = 0.5, player: String? = nil, pointer: String = "mouse") {
        noteInput()
        let hue = player.map(CanvasPlayer.hue(for:)) ?? nextPaletteHue()
        let strength = 0.6 + min(1.5, max(0, pressure)) * 0.9
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        addUser(FluidSplat(x: b.x, y: b.y, dx: dx * cells * 45 * strength, dy: dy * cells * 45 * strength,
                           color: colour(hue: hue, 0.25 * strength), radius: 0.0025 * (0.8 + min(1, pressure) * 0.6)))
#if os(macOS)
        if mode != .music { sound?.stroke(x: b.x, y: b.y, speed: hypot(dx * aspect, dy) * 60) }
#endif
        if let player { join(player) }
        let key = player.map { "\($0)#\(pointer)" } ?? pointer
        var g = gestures[key] ?? CanvasGestureDetector()
        if let found = g.add(x: b.x, y: b.y, t: now, aspect: aspect) {
            let centre = found == .whirlpool ? g.centre ?? (b.x, b.y) : (b.x, b.y)
            trigger(found, x: centre.x, y: centre.y)
        }
        gestures[key] = g
    }

    /// A finger or the pointer lifted: the next stir starts a new gesture.
    public func endStroke(player: String? = nil, pointer: String = "mouse") {
        gestures[player.map { "\($0)#\(pointer)" } ?? pointer]?.reset()
        holdStart = nil
    }

    /// A click or tap without a drag: a small bloom (or a well in Wells mode).
    public func tap(at p: CGPoint, repel: Bool = false, player: String? = nil) {
        noteInput()
        if mode == .wells { plantWell(at: p, repel: repel, player: player); return }
        let hue = player.map(CanvasPlayer.hue(for:)) ?? nextPaletteHue()
        for k in 0..<6 {
            let a = Double(k) / 6 * 2 * .pi
            addUser(FluidSplat(x: p.x + cos(a) * 0.01 / aspect, y: p.y + sin(a) * 0.01, dx: cos(a) * 160, dy: sin(a) * 160,
                               color: colour(hue: hue, 0.12), radius: 0.0016))
        }
        if let player { join(player) }
#if os(macOS)
        sound?.note(x: p.x, y: p.y, velocity: 0.45)
#endif
    }

    public func plantWell(at p: CGPoint, repel: Bool = false, player: String? = nil) {
        noteInput()
        let hue = player.map(CanvasPlayer.hue(for:)) ?? nextPaletteHue()
        // The kaleidoscope plants mirrored wells too, within the cap (rotations only).
        var points = [(Double(p.x), Double(p.y))]
        if symmetry > 2 {
            let folds = min(symmetry, CanvasWells.maxCount)
            let px = (p.x - 0.5) * aspect, py = p.y - 0.5
            points = (0..<folds).map { k in
                let a = Double(k) * 2 * .pi / Double(folds)
                return ((px * cos(a) - py * sin(a)) / aspect + 0.5, px * sin(a) + py * cos(a) + 0.5)
            }
        } else if symmetry == 2 {
            points.append((1 - p.x, p.y))
        }
        // Each mirrored well pours its own colour, so a kaleidoscope of wells isn't one flat hue.
        for (k, (x, y)) in points.enumerated() {
            let wellHue = k == 0 ? hue : (player != nil ? (hue + Double(k) * 0.09).truncatingRemainder(dividingBy: 1)
                                                       : pilot.paletteHue(hueWalk + Double(k) / Double(points.count)))
            wells.plant(CanvasWell(x: x, y: y, strength: repel ? -1 : 1, hue: wellHue, phase: Double.random(in: 0...6)))
        }
        if let player { join(player) }
        status.wellCount = wells.wells.count
        onStateChange?()
#if os(macOS)
        sound?.note(x: p.x, y: p.y, velocity: 0.5, low: true)
#endif
    }

    public func removeWell(near p: CGPoint) {
        wells.removeNearest(x: p.x, y: p.y)
        status.wellCount = wells.wells.count
        onStateChange?()
    }

    public func clearWells() {
        wells.clear()
        status.wellCount = 0
        onStateChange?()
    }

    /// Tilt from the phone: gravity in screen axes (x right, y down), each −1…1.
    public func setTilt(x: Double, y: Double) {
        phoneTilt = SIMD2(max(-1, min(1, x)), max(-1, min(1, y)))
        phoneTiltAt = now
        noteInput()
    }

    /// Tilt from the arrow keys (Tilt mode on the Mac).
    public func setKeyTilt(x: Double, y: Double) { keyTilt = SIMD2(x, y); noteInput() }

    /// A shake: a splash of colour and motion across the canvas.
    public func shake() {
        noteInput()
        guard flash.allow(at: now, hue: 0.5) else { return }
        for _ in 0..<14 {
            let a = Double.random(in: 0..<(2 * .pi))
            sim?.add(FluidSplat(x: .random(in: 0.15...0.85), y: .random(in: 0.15...0.85), dx: cos(a) * 900, dy: sin(a) * 900,
                                color: colour(hue: nextPaletteHue(), 0.3), radius: 0.003))
        }
        pendingBurst = SIMD4(0.5, 0.5, 0.45, 1)
    }

    /// Trackpad pinch: spreading fingers push out from `p`, pinching pulls in.
    public func vortex(at p: CGPoint, amount: Double) {
        noteInput()
        let push = max(-1, min(1, amount)) * 1400
        let hue = nextPaletteHue()
        for k in 0..<10 {
            let a = Double(k) / 10 * 2 * .pi
            addUser(FluidSplat(x: p.x + cos(a) * 0.04 / aspect, y: p.y + sin(a) * 0.04, dx: cos(a) * push, dy: sin(a) * push,
                               color: colour(hue: hue, amount > 0 ? 0.08 : 0.02), radius: 0.002))
        }
    }

    /// Trackpad rotate: a swirl around `p`.
    public func swirl(at p: CGPoint, radians: Double) {
        noteInput()
        let spin = max(-1, min(1, radians * 4)) * 1600
        for k in 0..<12 {
            let a = Double(k) / 12 * 2 * .pi
            addUser(FluidSplat(x: p.x + cos(a) * 0.06 / aspect, y: p.y + sin(a) * 0.06, dx: -sin(a) * spin, dy: cos(a) * spin,
                               color: colour(hue: nextPaletteHue(), 0.04), radius: 0.002))
        }
    }

    /// Force Touch: holding a deep press for ~a second sets off a supernova.
    public func press(at p: CGPoint, deep: Bool) {
        guard deep else { holdStart = nil; return }
        if let started = holdStart {
            if now - started >= 0.8 { holdStart = nil; trigger(.supernova, x: p.x, y: p.y) }
        } else {
            holdStart = now
        }
    }

    /// The Mac's sound, for Music mode (values 0…1, ~40 times a second).
    public func feedAudio(bass: Double, mid: Double, high: Double, rms: Double, flux: Double) {
        func ease(_ old: Double, _ new: Double) -> Double { new > old ? old + (new - old) * 0.6 : old + (new - old) * 0.12 }
        bands = (ease(bands.bass, bass), ease(bands.mid, mid), ease(bands.high, high), ease(bands.rms, rms), flux)
    }

    /// A phone joined in (Together): counts as a player for 30 s; three
    /// stirring at once is the Chorus discovery.
    private func join(_ player: String) {
        players[player] = now
        let active = players.filter { now - $0.value < 3 }
        if active.count >= 3, now - lastChorus > 20 {
            lastChorus = now
            trigger(.chorus, x: 0.5, y: 0.5, hues: active.keys.map(CanvasPlayer.hue(for:)))
        }
    }

    // MARK: - Discoveries

    private func trigger(_ d: CanvasDiscovery, x: Double, y: Double, hues: [Double] = []) {
        guard let sim else { return }
        let hue = hues.first ?? nextPaletteHue()
        guard flash.allow(at: now, hue: hue) else { return }
        switch d {
        case .whirlpool:
            for k in 0..<16 {
                let a = Double(k) / 16 * 2 * .pi
                sim.add(FluidSplat(x: x + cos(a) * 0.07 / aspect, y: y + sin(a) * 0.07, dx: -sin(a) * 2200, dy: cos(a) * 2200,
                                   color: colour(hue: pilot.paletteHue(Double(k) / 16), 0.12), radius: 0.0022))
            }
        case .supernova:
            for k in 0..<20 {
                let a = Double(k) / 20 * 2 * .pi
                sim.add(FluidSplat(x: x, y: y, dx: cos(a) * 2600, dy: sin(a) * 2600,
                                   color: colour(hue: pilot.paletteHue(Double(k) / 20), 0.2), radius: 0.0018))
            }
            flashBoost = 0.25
        case .twinStars:
            sim.add(FluidSplat(x: x, y: y, dx: 0, dy: 0, color: SIMD3(1, 0.95, 0.85) * 0.9, radius: 0.004))
            for k in 0..<12 {
                let a = Double(k) / 12 * 2 * .pi
                sim.add(FluidSplat(x: x, y: y, dx: cos(a) * 1500, dy: sin(a) * 1500, color: colour(hue: hue, 0.12), radius: 0.0015))
            }
            flashBoost = 0.2
        case .sparkStorm:
            for _ in 0..<24 {
                let a = Double.random(in: 0..<(2 * .pi)), r = Double.random(in: 0...0.1)
                sim.add(FluidSplat(x: x + cos(a) * r / aspect, y: y + sin(a) * r, dx: cos(a) * 1800, dy: sin(a) * 1800,
                                   color: colour(hue: pilot.paletteHue(.random(in: 0...1)), 0.18), radius: 0.0006))
            }
        case .rainbowBridge:
            for k in 0..<14 {
                let fx = 0.05 + 0.9 * Double(k) / 13
                sim.add(FluidSplat(x: fx, y: y, dx: 0, dy: -600, color: colour(hue: Double(k) / 14, 0.25), radius: 0.003))
            }
        case .chorus:
            let ring = hues.isEmpty ? [hue] : hues
            for k in 0..<18 {
                let a = Double(k) / 18 * 2 * .pi
                sim.add(FluidSplat(x: x, y: y, dx: cos(a) * 2000, dy: sin(a) * 2000,
                                   color: colour(hue: ring[k % ring.count], 0.22), radius: 0.002))
            }
            flashBoost = 0.2
        }
        pendingBurst = SIMD4(Float(x), Float(y), 0.08, 1)
        let isNew = CanvasDiscovery.record(d)
        if isNew {
            status.found = CanvasDiscovery.found
            showToast("Discovered: \(d.title)")
            onStateChange?()
        }
#if os(macOS)
        sound?.chord(rising: d != .twinStars)
#endif
        canvasLog.info("Canvas discovery \(d.rawValue, privacy: .public)\(isNew ? " (new)" : "", privacy: .public)")
    }

    public func showToast(_ text: String, seconds: Double = 3.5) {
        status.toast = text
        toastUntil = now + seconds
    }

    // MARK: - Saved canvases

    /// Restores a kept canvas: its look, mode, symmetry, mood and wells.
    public func restore(_ scene: CanvasScene) {
        let d = UserDefaults.standard
        d.set(scene.style.rawValue, forKey: CanvasStyle.defaultsKey)
        d.set(scene.mode.rawValue, forKey: CanvasMode.defaultsKey)
        d.set(scene.symmetry, forKey: CanvasSymmetry.defaultsKey)
        d.set((scene.mood ?? .none).rawValue, forKey: CanvasMood.defaultsKey)
        wells = CanvasWells(scene.wells)
        status.wellCount = wells.wells.count
        moodStart = (scene.mood ?? .none) == .none ? nil : now
        applySettings()
        showToast("Restored \(scene.name)")
    }

    /// What a saved canvas keeps.
    public func currentScene(named name: String) -> CanvasScene {
        CanvasScene(name: name, style: style, mode: mode, symmetry: symmetry, mood: mood == .none ? nil : mood, wells: wells.wells)
    }

    /// The current picture (glow and roll-off, SDR) at any size, for a
    /// thumbnail, a PNG or a wallpaper.
    public func snapshot(width: Int, height: Int) -> CGImage? {
        guard let sim, let renderer, let queue, width > 0, height > 0 else { return nil }
        if !sized || sim.dyeTexture == nil { frame() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let target = sim.device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        var p = renderParams(dt: 1.0 / 60)
        p.headroom = 1
        renderer.renderFinal(cb, to: pass, format: .bgra8Unorm, params: p)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Remote

    /// What the phone shows.
    public func remoteState(quality: CanvasQuality) -> CanvasState {
        var s = CanvasState(mode: mode.rawValue, style: style.rawValue, quality: quality.rawValue)
        s.symmetry = symmetry
        s.mood = mood.rawValue
#if os(macOS)
        s.sound = CanvasSound.stored
#endif
        s.players = players.filter { now - $0.value < 30 }.count
        s.wells = wells.wells.count
        s.discoveries = CanvasDiscovery.found.count
        if mode == .breathe {
            s.breathCycle = pacer.cycle
            s.breathPhase = pacer.phase(at: now - breatheStart)
        }
        return s
    }

    // MARK: - Frame

    /// One frame: per-frame play (wells, tilt, music, breathing, moods),
    /// physics catch-up at 240 Hz, colour, the picture, the lights' copy, and
    /// the view's drawable when there is one.
    public func frame(pass: MTLRenderPassDescriptor? = nil, format: MTLPixelFormat = .bgra8Unorm,
                      present drawable: MTLDrawable? = nil) {
        guard let sim, let renderer, let queue, let cb = queue.makeCommandBuffer() else { return }
        // Never sized yet: lights only (a window resizes it to its own size when it shows).
        if !sized { resize(Self.lightsOnlySize) }
        let now = self.now
        let frameTime = min(1.0 / 30, last.map { now - $0 } ?? 1.0 / 60)
        last = now
        playFrame(now: now, dt: frameTime)

        let step = 1.0 / Double(Self.stepsPerSecond)
        unsimulated += frameTime
        // At most 8 steps a frame; time beyond that is dropped, not owed, so a
        // slow frame can't snowball into slower ones.
        let steps = min(8, Int(unsimulated / step))
        unsimulated = min(step, max(0, unsimulated - Double(steps) * step))
        let simTime = now - start - unsimulated
        simSteps += steps
        let emit = emitterStrength(now: now)
        for i in 0..<steps {
            if emit.amount > 0 {
                let t = simTime - Double(steps - 1 - i) * step
                let splats = pilot.splats(at: t, dt: step, simCells: cells).map {
                    FluidSplat(x: $0.x, y: $0.y, dx: $0.dx * emit.push, dy: $0.dy * emit.push,
                               color: $0.color * Float(emit.amount), radius: $0.radius)
                }
                sim.add(splats)
            }
            sim.stepPhysics(cb, dt: Float(step))
        }
        // Colour moves once per drawn frame, by the time the physics covered.
        if steps > 0 { sim.moveColour(cb, dt: Float(Double(steps) * step)) }

        let params = renderParams(dt: frameTime)
        pendingBurst = .zero
        if pass != nil || viewIsShowing {
            renderer.renderScene(cb, sim: sim, params: params)
        } else {
            renderer.renderLightsOnlyScene(cb, sim: sim, params: params)
        }
        if drivesLights, now - lastLightFrame >= 1 / Self.lightRate - 0.002, !lightTargets.isEmpty, let onLightFrame {
            lastLightFrame = now
            let target = lightTargets[lightIndex]
            lightIndex = (lightIndex + 1) % lightTargets.count
            renderer.renderLights(cb, into: target, light: params.light)
            let w = Self.lightSize.width, h = Self.lightSize.height
            cb.addCompletedHandler { _ in
                var bytes = [UInt8](repeating: 0, count: w * h * 4)
                target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                onLightFrame(bytes, w * 4)
            }
        }
        if let pass { renderer.renderFinal(cb, to: pass, format: format, params: params) }
        if let drawable { cb.present(drawable) }
        let gpu = gpuTime
        cb.addCompletedHandler { done in
            let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
            gpu.withLock { $0.total += ms; $0.count += 1 }
        }
        cb.commit()
        logStats(now)
    }

    /// How strongly the emitters pour this frame (colour ×, push ×).
    func emitterStrength(now: Double) -> (amount: Double, push: Double) {
        switch mode {
        case .auto: return (1, 1)
        case .music:
            // Quiet music barely pours; loud music floods; bass pushes.
            return (0.25 + 1.6 * bands.rms, 0.5 + 2.6 * bands.bass)
        case .interactive:
            if now < previewUntil { return (1, 1) }
            // Left alone, it slowly carries on by itself, gently.
            let idle = now - lastUserInput - Self.idleAfter
            return idle > 0 ? (0.35 * min(1, idle / 6), 0.5) : (0, 0)
        case .breathe, .tilt, .wells:
            return now < previewUntil ? (1, 1) : (0, 0)
        }
    }

    /// Per-frame play that isn't a stir: wells, tilt, music beats, breathing,
    /// mood sessions, the status the UI shows.
    private func playFrame(now: Double, dt: Double) {
        guard let sim else { return }
        // Wells live only in Wells mode; they drift, merge, and pour their colour.
        if mode == .wells, !wells.wells.isEmpty {
            if let merge = wells.drift(dt: dt, aspect: aspect) {
                status.wellCount = wells.wells.count
                trigger(.twinStars, x: merge.x, y: merge.y)
            }
            sim.wells = wells.wells.map { SIMD4(Float($0.x), Float($0.y), Float($0.strength), 1) }
            for w in wells.wells where w.strength > 0 {
                sim.add(FluidSplat(x: w.x + cos(w.phase * 5) * 0.01 / aspect, y: w.y + sin(w.phase * 5) * 0.01, dx: 0, dy: 0,
                                   color: colour(hue: w.hue, 0.01 * dt * 60 * w.strength), radius: 0.0014))
            }
        } else {
            sim.wells = []
        }

        // Tilt: the phone's gravity if it's recent, else the arrow keys.
        sim.walls = mode == .tilt
        if mode == .tilt {
            let g = now - phoneTiltAt < 1 ? phoneTilt : keyTilt
            sim.gravity = SIMD2(Float(g.x), Float(g.y)) * 450
        } else {
            sim.gravity = .zero
        }

        // Music: beats bloom (never more than three a second), treble cools the palette.
        musicPulse *= pow(0.5, dt / 0.18)
        if mode == .music {
            pilot.hueShift = (bands.high - bands.bass) * 0.18
            let rising = bands.bass - lastBass
            lastBass = bands.bass
            if bands.flux > 0.55, rising > 0.02, bands.rms > 0.08 {
                let emitters = pilot.splats(at: now - start, dt: 1.0 / 60)
                let p = emitters.isEmpty ? nil : emitters[Int.random(in: 0..<emitters.count)]
                let x = p?.x ?? 0.5, y = p?.y ?? 0.5
                let hue = pilot.paletteHue(.random(in: 0...1))
                if flash.allow(at: now, hue: hue) {
                    for k in 0..<10 {
                        let a = Double(k) / 10 * 2 * .pi
                        let push = 900 * (0.6 + bands.bass)
                        sim.add(CanvasSymmetry.expand(FluidSplat(x: x, y: y, dx: cos(a) * push, dy: sin(a) * push,
                                                                 color: colour(hue: hue, 0.1 + 0.15 * bands.bass), radius: 0.0018),
                                                      folds: symmetry, aspect: aspect))
                    }
                    musicPulse = min(0.3, 0.12 + bands.bass * 0.2)
                    pendingBurst = SIMD4(Float(x), Float(y), 0.06, 1)
                }
            }
        } else {
            pilot.hueShift = 0
        }

        // Breathing: an outward bloom while breathing in, a gentle pull back while breathing out.
        if mode == .breathe {
            let t = now - breatheStart
            let inhaling = pacer.isInhaling(at: t)
            if inhaling != wasInhaling {
                wasInhaling = inhaling
                status.inhaling = inhaling
#if os(macOS)
                sound?.breath(inhale: inhaling)
#endif
                onStateChange?()
            }
            if inhaling {
                // Six petals turning slowly outward: a flower opening, not a plain disc.
                for k in 0..<6 {
                    let a = Double(k) / 6 * 2 * .pi + t * 0.25
                    let petalHue = pilot.paletteHue(t / pacer.cycle * 0.25 + Double(k) / 12)
                    sim.add(FluidSplat(x: 0.5 + cos(a) * 0.06 / aspect, y: 0.5 + sin(a) * 0.06,
                                       dx: cos(a) * 140 - sin(a) * 90, dy: sin(a) * 140 + cos(a) * 90,
                                       color: colour(hue: petalHue, 0.018 * dt * 60), radius: 0.0022))
                }
            } else {
                sim.wells = [SIMD4(0.5, 0.5, 0.5, 0.2)]
            }
            let minutes = UserDefaults.standard.object(forKey: Self.breatheMinutesKey) as? Int ?? 3
            if minutes > 0, t > Double(minutes) * 60 {
                showToast("Breathing done. Well breathed.")
#if os(macOS)
                sound?.chord(rising: false)
#endif
                UserDefaults.standard.set(CanvasMode.auto.rawValue, forKey: CanvasMode.defaultsKey)
                applySettings()
            }
        }

        flashBoost *= pow(0.5, dt / 0.2)

        // Mood sessions that end by themselves.
        if let started = moodStart, mood.endsByItself {
            let minutes = UserDefaults.standard.integer(forKey: CanvasMood.sessionDefaultsKey)
            if minutes > 0, now - started >= Double(minutes) * 60 {
                moodStart = nil
                let ended = mood
                showToast(ended == .focus ? "Focus session done. Time for a break." : "Good night.")
#if os(macOS)
                sound?.chord(rising: false)
#endif
                onMoodEnded?(ended)
            }
        }

        if now - lastStatusTick >= 1 {
            lastStatusTick = now
            if status.toast != nil, now > toastUntil { status.toast = nil }
            let activePlayers = players.filter { now - $0.value < 30 }.count
            if activePlayers != status.players { status.players = activePlayers; onStateChange?() }
            var remaining: TimeInterval?
            if mode == .breathe {
                let minutes = UserDefaults.standard.object(forKey: Self.breatheMinutesKey) as? Int ?? 3
                if minutes > 0 { remaining = max(0, Double(minutes) * 60 - (now - breatheStart)) }
            } else if let started = moodStart, mood.endsByItself {
                let minutes = UserDefaults.standard.integer(forKey: CanvasMood.sessionDefaultsKey)
                if minutes > 0 { remaining = max(0, Double(minutes) * 60 - (now - started)) }
            }
            // Whole seconds, so the UI redraws at most once a second.
            let rounded = remaining.map { $0.rounded() }
            if rounded != status.sessionRemaining { status.sessionRemaining = rounded }
        }
    }

    private func renderParams(dt: Double) -> CanvasRenderer.Params {
        let t = now - start
        var p = CanvasRenderer.Params()
        p.look = DisplayLook(style: style, time: Float(t * motionScale * mood.pace))
        p.finish = style.finish
        p.dt = Float(dt)
        p.time = Float(t)
        p.headroom = headroom
        p.burst = pendingBurst
        let session = moodStart.map { now - $0 } ?? 0
        let lights = mood.lights(elapsed: session, minutes: UserDefaults.standard.integer(forKey: CanvasMood.sessionDefaultsKey))
        var exposure = 1 + musicPulse + flashBoost
        if mode == .breathe { exposure *= 0.5 + 0.5 * pacer.fullness(at: now - breatheStart) }
        // Wind-down dims the window with the room, more gently.
        if mood == .windDown { exposure *= sqrt(lights.gain) }
        p.look.exposure = Float(exposure)
        p.light = CanvasRenderer.LightParams(gain: Float(lights.gain), white: Float(lights.white), warm: lights.warm)
        return p
    }

    /// The audio tap runs only while Music mode is actually showing or lighting the room.
    private func updateAudioNeed() {
        let need = mode == .music && (viewIsShowing || drivesLights)
        guard need != audioRunning else { return }
        audioRunning = need
        onNeedsAudio?(need)
    }

    /// Lights-only frames at 60 Hz while canvas mode is on and no window draws.
    private func updateTimer() {
        let headless = drivesLights && !viewIsShowing
        guard headless != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard headless else { return }
        resetClock()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func logStats(_ now: CFTimeInterval) {
        frames += 1
        guard now - statsFrom >= 2 else { return }
        let (total, count) = gpuTime.withLock { s -> (Double, Int) in defer { s = (0, 0) }; return (s.total, s.count) }
        let fps = Double(frames) / (now - statsFrom)
        let steps = Double(simSteps) / (now - statsFrom)
        let gpuMs = count > 0 ? total / Double(count) : 0
        recentGPUms = gpuMs
        let particles = renderer?.particleCount ?? 0
        canvasLog.debug("Canvas \(self.viewIsShowing ? "window" : "lights only", privacy: .public): \(fps, format: .fixed(precision: 1), privacy: .public) fps, \(steps, format: .fixed(precision: 0), privacy: .public) sim steps/s, GPU \(gpuMs, format: .fixed(precision: 2), privacy: .public) ms/frame, \(particles, privacy: .public) particles")
        frames = 0
        simSteps = 0
        statsFrom = now
    }

    /// For tests: whether the autopilot pours at `now`.
    func runsPilot(at now: CFTimeInterval) -> Bool { emitterStrength(now: now).amount > 0 }
}
#endif
