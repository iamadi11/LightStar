import SwiftUI
import AppKit
import MetalKit
import LightStarCore

/// Live liquid art. The app owns the liquid (`CanvasEngine`); this window
/// shows it and turns drags into stirs. In canvas mode the lights follow it.
struct CanvasView: View {
    let engine: CanvasEngine

    var body: some View {
        Group {
            if engine.sim == nil {
                Text("Canvas needs Metal, which this Mac doesn't offer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FluidMetalView(engine: engine)
                    .accessibilityLabel("Canvas: flowing coloured liquid. Drag to stir it.")
            }
        }
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 300)
    }
}

private struct FluidMetalView: NSViewRepresentable {
    let engine: CanvasEngine

    func makeCoordinator() -> CanvasViewDriver { CanvasViewDriver(engine: engine) }

    func makeNSView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: engine.sim?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        view.engine = engine
        return view
    }

    func updateNSView(_ view: CanvasMTKView, context: Context) {}

    static func dismantleNSView(_ view: CanvasMTKView, coordinator: CanvasViewDriver) {
        view.isPaused = true
        view.delegate = nil
        coordinator.engine.viewIsShowing = false
    }
}

/// Feeds the view's drawables to the engine.
final class CanvasViewDriver: NSObject, MTKViewDelegate {
    let engine: CanvasEngine
    init(engine: CanvasEngine) { self.engine = engine }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { engine.resize(size) }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            // AppKit still asks a hidden view to draw (layout, resizes); asking
            // it for a drawable then blocks the main thread waiting for one.
            // Hidden, the engine's own timer feeds the lights instead.
            guard engine.viewIsShowing, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            engine.frame(pass: pass, format: view.colorPixelFormat, present: drawable)
        }
    }
}

/// Pauses when its window is hidden or minimised, and turns drags into stirs.
final class CanvasMTKView: MTKView {
    weak var engine: CanvasEngine?
    private var occlusion: NSObjectProtocol?
    private var lastDrag: CGPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (closed) drops the observer, so no deinit is needed.
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else {
            isPaused = true
            engine?.viewIsShowing = false
            return
        }
        // Up to 240; capped by the screen. ponytail: on the 120 Hz BenQ this
        // (and NSView/NSScreen display links, tried) still ticks at 60 in the
        // app, though a standalone link gets 120. Open item; the physics runs
        // at a fixed 240 steps/s regardless.
        preferredFramesPerSecond = CanvasEngine.stepsPerSecond
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        }
        updatePaused()
    }

    /// Hidden: the engine takes over drawing for the lights, if canvas mode is on.
    private func updatePaused() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPaused = !visible
        engine?.viewIsShowing = visible
        engine?.resetClock()
    }

    override func mouseDown(with event: NSEvent) { lastDrag = point(event) }
    override func mouseUp(with event: NSEvent) { lastDrag = nil }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let last = lastDrag { engine?.stir(from: last, to: p) }
        lastDrag = p
    }

    /// 0…1, y down.
    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x / max(1, bounds.width), y: 1 - local.y / max(1, bounds.height))
    }
}
