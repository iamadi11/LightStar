import SwiftUI
import AppKit
import MetalKit
import os
import LightStarCore

private let canvasLog = Logger(subsystem: "com.adityaraj.LightStar", category: "canvas")

/// Live liquid art (milestone 1: Auto mode, drag to stir). Doesn't drive the
/// lights yet; that comes from reading this view's own frames, not the screen.
struct CanvasView: View {
    /// Owns the GPU work; built once per window (compiling the shaders takes a moment).
    @State private var renderer = FluidRenderer()

    var body: some View {
        Group {
            if renderer.sim == nil {
                Text("Canvas needs Metal, which this Mac doesn't offer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FluidMetalView(renderer: renderer)
                    .accessibilityLabel("Canvas: flowing coloured liquid. Drag to stir it.")
            }
        }
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 300)
    }
}

private struct FluidMetalView: NSViewRepresentable {
    let renderer: FluidRenderer

    func makeNSView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: renderer.sim?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = renderer
        view.renderer = renderer
        return view
    }

    func updateNSView(_ view: CanvasMTKView, context: Context) {}

    static func dismantleNSView(_ view: CanvasMTKView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Pauses when its window is hidden or minimised, and turns drags into splats.
final class CanvasMTKView: MTKView {
    weak var renderer: FluidRenderer?
    private var occlusion: NSObjectProtocol?
    private var lastDrag: CGPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (closed) drops the observer, so no deinit is needed.
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { isPaused = true; return }
        // Up to 240; capped by the screen. ponytail: on the 120 Hz BenQ this
        // (and NSView/NSScreen display links, tried) still ticks at 60 in the
        // app, though a standalone link gets 120. Open item; the physics runs
        // at a fixed 240 steps/s regardless.
        preferredFramesPerSecond = FluidRenderer.stepsPerSecond
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        }
        updatePaused()
    }

    private func updatePaused() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPaused = !visible
        renderer?.resetClock()
    }

    override func mouseDown(with event: NSEvent) { lastDrag = point(event) }
    override func mouseUp(with event: NSEvent) { lastDrag = nil }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let last = lastDrag { renderer?.stir(from: last, to: p) }
        lastDrag = p
    }

    /// 0…1, y down.
    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x / max(1, bounds.width), y: 1 - local.y / max(1, bounds.height))
    }
}

final class FluidRenderer: NSObject, MTKViewDelegate {
    /// The liquid moves in fixed 1/240 s steps whatever the display shows, so
    /// motion is the same and as smooth at 60, 120 or 240 Hz.
    static let stepsPerSecond = 240
    let sim = FluidSimulation()
    private var unsimulated = 0.0
    private let queue: MTLCommandQueue?
    private var pilot = FluidAutoPilot()
    private var start = CACurrentMediaTime()
    private var last: CFTimeInterval?
    private var hueWalk = 0.0
    // Frame timing, logged every 2 s at debug level (`log stream --level debug`).
    private var frames = 0, simSteps = 0, statsFrom = CACurrentMediaTime()
    private let gpuTime = OSAllocatedUnfairLock(initialState: (total: 0.0, count: 0))

    override init() {
        queue = sim?.device.makeCommandQueue()
        super.init()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { pilot.speed = 0.4 }
    }

    /// After a pause, the next frame mustn't count the paused time as one long step.
    func resetClock() { last = nil }

    func stir(from a: CGPoint, to b: CGPoint) {
        guard let sim else { return }
        hueWalk = (hueWalk + 0.004).truncatingRemainder(dividingBy: 1)
        let c = WizRGB(hue: hueWalk, saturation: 1)
        let cells = Double(sim.settings.simResolution)
        sim.add(FluidSplat(x: b.x, y: b.y,
                           dx: (b.x - a.x) * cells * 45, dy: (b.y - a.y) * cells * 45,
                           color: SIMD3(Float(c.r), Float(c.g), Float(c.b)) / 255 * 0.25,
                           radius: 0.0025))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let sim else { return }
        // Colour at the drawable's own resolution, up to 1440 on the short side.
        sim.settings.dyeResolution = min(1440, max(256, Int(min(size.width, size.height))))
        sim.resize(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let sim, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let frame = min(1.0 / 30, last.map { now - $0 } ?? 1.0 / 60)
        last = now
        sim.resize(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))
        let step = 1.0 / Double(Self.stepsPerSecond)
        unsimulated += frame
        // At most 8 steps a frame; time beyond that is dropped, not owed, so a
        // slow frame can't snowball into slower ones.
        let steps = min(8, Int(unsimulated / step))
        unsimulated = min(step, max(0, unsimulated - Double(steps) * step))
        let simTime = now - start - unsimulated
        simSteps += steps
        for i in 0..<steps {
            let t = simTime - Double(steps - 1 - i) * step
            sim.add(pilot.splats(at: t, dt: step, simCells: Double(sim.settings.simResolution)))
            sim.stepPhysics(cb, dt: Float(step))
        }
        // Colour moves once per drawn frame, by the time the physics covered.
        if steps > 0 { sim.moveColour(cb, dt: Float(Double(steps) * step)) }
        sim.draw(cb, to: pass, format: view.colorPixelFormat)
        cb.present(drawable)
        let gpu = gpuTime
        cb.addCompletedHandler { done in
            let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
            gpu.withLock { $0.total += ms; $0.count += 1 }
        }
        cb.commit()
        logStats(now, view)
    }

    private func logStats(_ now: CFTimeInterval, _ view: MTKView) {
        frames += 1
        guard now - statsFrom >= 2 else { return }
        let (total, count) = gpuTime.withLock { s -> (Double, Int) in defer { s = (0, 0) }; return (s.total, s.count) }
        let fps = Double(frames) / (now - statsFrom)
        let gpuMs = count > 0 ? total / Double(count) : 0
        let size = view.drawableSize
        let stepsPerSecond = Double(simSteps) / (now - statsFrom)
        let screen = view.window?.screen
        canvasLog.debug("Canvas on \(screen?.localizedName ?? "no screen", privacy: .public) (max \(screen?.maximumFramesPerSecond ?? 0, privacy: .public) Hz)")
        canvasLog.debug("Canvas \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public): \(fps, format: .fixed(precision: 1), privacy: .public) fps, \(stepsPerSecond, format: .fixed(precision: 0), privacy: .public) sim steps/s, GPU \(gpuMs, format: .fixed(precision: 2), privacy: .public) ms/frame")
        frames = 0
        simSteps = 0
        statsFrom = now
    }
}
