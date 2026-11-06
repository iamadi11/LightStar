#if canImport(Metal)
import Metal
import QuartzCore
import CoreGraphics
import os

private let canvasLog = Logger(subsystem: "com.adityaraj.LightStar", category: "canvas")

/// Owns the Canvas liquid for the whole app: steps it at a fixed 240 Hz, draws
/// it into the Canvas window when that's showing, and, while canvas mode
/// drives the lights, reads a 48×27 copy of each frame for them. No screen
/// capture: the lights get exactly what the canvas draws, window open or not.
@MainActor
public final class CanvasEngine {
    public static let stepsPerSecond = 240
    /// Lights read the canvas this often.
    static let lightRate = 30.0
    public static let lightSize = (width: 48, height: 27)

    public let sim: FluidSimulation?
    private let queue: MTLCommandQueue?
    private(set) var pilot = FluidAutoPilot(style: .stored)
    private var mode = CanvasMode.stored
    private var style = CanvasStyle.stored
    /// Interactive mode plays a newly picked animation this long, so the pick shows.
    static let previewSeconds = 4.0
    private(set) var previewUntil = 0.0
    /// Reduce Motion: slower animations (the app sets 0.4).
    public var motionScale = 1.0 { didSet { applySettings() } }
    private var start = CACurrentMediaTime()
    private var last: CFTimeInterval?
    private var unsimulated = 0.0
    private var hueWalk = 0.0

    /// A 48×27 BGRA frame (bytes, bytes per row), on a Metal completion
    /// thread, while `drivesLights` is on.
    public var onLightFrame: (@Sendable ([UInt8], Int) -> Void)?
    /// Canvas mode: keep the liquid running for the lights, window or not.
    public var drivesLights = false { didSet { updateTimer() } }
    /// The window draws frames itself while it's visible.
    public var viewIsShowing = false { didSet { updateTimer() } }
    private var timer: Timer?
    private var lightTargets: [MTLTexture] = []
    private var lightIndex = 0
    private var lastLightFrame = 0.0
    private var sized = false

    private var frames = 0, simSteps = 0, statsFrom = CACurrentMediaTime()
    private let gpuTime = OSAllocatedUnfairLock(initialState: (total: 0.0, count: 0))

    public init() {
        sim = FluidSimulation()
        defer { applySettings() }
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
    }

    /// After a pause, the next frame mustn't count the paused time as one long step.
    public func resetClock() { last = nil }

    /// A drag from `a` to `b` (0…1, y down) stirs the liquid and adds colour.
    public func stir(from a: CGPoint, to b: CGPoint) {
        guard let sim else { return }
        // Stirring paints in the animation's own palette, walking through it.
        hueWalk = (hueWalk + 0.004).truncatingRemainder(dividingBy: 1)
        let c = WizRGB(hue: pilot.paletteHue(hueWalk), saturation: 1)
        let cells = Double(sim.settings.simResolution)
        sim.add(FluidSplat(x: b.x, y: b.y,
                           dx: (b.x - a.x) * cells * 45, dy: (b.y - a.y) * cells * 45,
                           color: SIMD3(Float(c.r), Float(c.g), Float(c.b)) / 255 * 0.25,
                           radius: 0.0025))
    }

    /// Size the canvas for a view's drawable.
    public func resize(_ size: CGSize) {
        guard let sim, size.width > 0, size.height > 0 else { return }
        lastSize = size
        // Lights only (no window) never needs more than a small canvas.
        let quality = viewIsShowing ? CanvasQuality.stored : .native
        sim.settings.dyeResolution = quality.colourResolution(screen: Int(min(size.width, size.height)))
        sim.resize(width: Int(size.width), height: Int(size.height))
        sized = true
    }

    private var lastSize: CGSize?

    /// Picks up the stored animation and mode (Settings, the Canvas section, the phone).
    public func applySettings() {
        let style = CanvasStyle.stored
        pilot = FluidAutoPilot(style: style, speedScale: motionScale)
        mode = CanvasMode.stored
        // Interactive never moves by itself, so a new pick would look like nothing happened.
        if style != self.style { previewUntil = CACurrentMediaTime() + Self.previewSeconds }
        self.style = style
        guard let sim else { return }
        let look = style.look
        sim.display = DisplayLook(style: style, time: sim.display.time)
        sim.settings.curl = look.curl
        sim.settings.dyeDissipation = look.dyeDissipation
        sim.settings.velocityDissipation = look.velocityDissipation
    }

    func runsPilot(at now: CFTimeInterval) -> Bool { mode == .auto || now < previewUntil }

    /// After the quality setting changes: rebuild the colour at the new size.
    public func applyQuality() {
        if let lastSize { resize(lastSize) }
    }

    /// One frame: physics catch-up at 240 Hz, colour, the lights' copy, and
    /// the view's drawable when there is one.
    public func frame(pass: MTLRenderPassDescriptor? = nil, format: MTLPixelFormat = .bgra8Unorm,
                      present drawable: MTLDrawable? = nil) {
        guard let sim, let queue, let cb = queue.makeCommandBuffer() else { return }
        // Lights only, never shown: the lights read 48×27, so a small 16:9
        // canvas is plenty (a window resizes it to its own size when it opens).
        if !sized { resize(CGSize(width: 480, height: 270)) }
        let now = CACurrentMediaTime()
        let frameTime = min(1.0 / 30, last.map { now - $0 } ?? 1.0 / 60)
        last = now
        let step = 1.0 / Double(Self.stepsPerSecond)
        unsimulated += frameTime
        // At most 8 steps a frame; time beyond that is dropped, not owed, so a
        // slow frame can't snowball into slower ones.
        let steps = min(8, Int(unsimulated / step))
        unsimulated = min(step, max(0, unsimulated - Double(steps) * step))
        let simTime = now - start - unsimulated
        simSteps += steps
        for i in 0..<steps {
            let t = simTime - Double(steps - 1 - i) * step
            if runsPilot(at: now) { sim.add(pilot.splats(at: t, dt: step, simCells: Double(sim.settings.simResolution))) }
            sim.stepPhysics(cb, dt: Float(step))
        }
        // Colour moves once per drawn frame, by the time the physics covered.
        if steps > 0 { sim.moveColour(cb, dt: Float(Double(steps) * step)) }

        sim.display.time = Float((now - start) * motionScale)
        if drivesLights, now - lastLightFrame >= 1 / Self.lightRate - 0.002, !lightTargets.isEmpty {
            lastLightFrame = now
            readForLights(cb)
        }
        if let pass {
            sim.draw(cb, to: pass, format: format)
        }
        if let drawable { cb.present(drawable) }
        let gpu = gpuTime
        cb.addCompletedHandler { done in
            let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
            gpu.withLock { $0.total += ms; $0.count += 1 }
        }
        cb.commit()
        logStats(now)
    }

    /// Draws into a small shared texture and hands its bytes over when the GPU
    /// is done; three textures rotate so a frame in flight is never overwritten.
    private func readForLights(_ cb: MTLCommandBuffer) {
        guard let sim, let onLightFrame else { return }
        let target = lightTargets[lightIndex]
        lightIndex = (lightIndex + 1) % lightTargets.count
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        sim.draw(cb, to: pass, format: .bgra8Unorm)
        let w = Self.lightSize.width, h = Self.lightSize.height
        cb.addCompletedHandler { _ in
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            onLightFrame(bytes, w * 4)
        }
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
        canvasLog.debug("Canvas \(self.viewIsShowing ? "window" : "lights only", privacy: .public): \(fps, format: .fixed(precision: 1), privacy: .public) fps, \(steps, format: .fixed(precision: 0), privacy: .public) sim steps/s, GPU \(gpuMs, format: .fixed(precision: 2), privacy: .public) ms/frame")
        frames = 0
        simSteps = 0
        statsFrom = now
    }
}
#endif
