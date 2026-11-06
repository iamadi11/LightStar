import SwiftUI
import AppKit
import MetalKit
import LightStarCore

/// Live liquid art. The app owns the liquid (`CanvasEngine`); this window
/// shows it, turns every kind of input into play, and floats a control bar
/// that appears when the pointer moves and fades when it rests.
struct CanvasView: View {
    let engine: CanvasEngine
    @State private var controlsVisible = true
    @State private var lastMove = Date()

    var body: some View {
        ZStack {
            if engine.sim == nil {
                Text("Canvas needs Metal, which this Mac doesn't offer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FluidMetalView(engine: engine)
                    .accessibilityLabel("Canvas: flowing coloured light. Drag to stir it; click to bloom.")
                CanvasOverlay(engine: engine, controlsVisible: controlsVisible)
            }
        }
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 300)
        .onContinuousHover { phase in
            if case .active = phase {
                lastMove = Date()
                if !controlsVisible { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true } }
            }
        }
        .task {
            // Fade the controls after the pointer has rested a while.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if controlsVisible, Date().timeIntervalSince(lastMove) > 2.8 {
                    withAnimation(.easeInOut(duration: 0.6)) { controlsVisible = false }
                }
            }
        }
    }
}

/// Toasts, the breathing cue, and the control bar.
private struct CanvasOverlay: View {
    let engine: CanvasEngine
    let controlsVisible: Bool
    @AppStorage(CanvasMode.defaultsKey) private var mode = CanvasMode.auto
    @AppStorage(CanvasStyle.defaultsKey) private var style = CanvasStyle.liquid
    @AppStorage(CanvasSymmetry.defaultsKey) private var symmetry = 1
    @AppStorage(CanvasMood.defaultsKey) private var mood = CanvasMood.none
    @AppStorage(CanvasSound.defaultsKey) private var soundOn = false

    var body: some View {
        let status = engine.status
        VStack {
            HStack(spacing: 8) {
                if let toast = status.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4), value: status.toast)
            .padding(.top, 14)
            Spacer()
            if mode == .breathe {
                Text(status.inhaling ? "Breathe in" : "Breathe out")
                    .font(.system(size: 22, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .animation(.easeInOut(duration: 1.2), value: status.inhaling)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            if controlsVisible { controls.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        let status = engine.status
        return HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(CanvasMode.allCases) { m in
                    Image(systemName: m.symbol).help("\(m.title): \(m.summary)").tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .onChange(of: mode) { _, _ in engine.applySettings() }

            Menu {
                Picker("Animation", selection: $style) {
                    ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label(style.title, systemImage: "paintpalette") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: style) { _, _ in engine.applySettings() }

            Menu {
                Picker("Mirror", selection: $symmetry) {
                    ForEach(CanvasSymmetry.choices, id: \.self) { Text(CanvasSymmetry.title($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label(symmetry > 1 ? "\(symmetry)×" : "Mirror", systemImage: "circle.hexagongrid") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Kaleidoscope: everything you do is repeated around the centre.")
            .onChange(of: symmetry) { _, _ in engine.applySettings() }

            Menu {
                Picker("Mood", selection: Binding(get: { mood }, set: { engine.applyMood($0) })) {
                    ForEach(CanvasMood.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label(mood == .none ? "Mood" : mood.title, systemImage: "sparkles") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(mood.summary)

            Divider().frame(height: 18)

            if mode == .wells, status.wellCount > 0 {
                Button { engine.clearWells() } label: { Image(systemName: "xmark.circle") }
                    .help("Clear the wells")
            }
            Toggle(isOn: $soundOn) { Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash") }
                .toggleStyle(.button)
                .help("Soft tones as you play")
                .onChange(of: soundOn) { _, on in engine.sound?.enabled = on }
            Menu {
                Button("Save canvas") { CanvasLibrary.shared.save(engine) }
                Button("Save picture…") { CanvasLibrary.shared.exportPicture(engine) }
                Button("Set as wallpaper") { CanvasLibrary.shared.setAsWallpaper(engine) }
            } label: { Image(systemName: "square.and.arrow.down") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Keep this canvas")

            if let remaining = status.sessionRemaining {
                Text(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if status.players > 0 {
                Label("\(status.players)", systemImage: "iphone")
                    .font(.caption)
                    .help("\(status.players) phone\(status.players == 1 ? "" : "s") playing")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

private struct FluidMetalView: NSViewRepresentable {
    let engine: CanvasEngine

    func makeCoordinator() -> CanvasViewDriver { CanvasViewDriver(engine: engine) }

    func makeNSView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: engine.sim?.device)
        // HDR screens (XDR, HDR monitors with HDR on): a float drawable in
        // extended sRGB lets glints and glow go brighter than white.
        if NSScreen.screens.contains(where: { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }) {
            view.colorPixelFormat = .rgba16Float
            view.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        } else {
            view.colorPixelFormat = .bgra8Unorm
        }
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
        coordinator.engine.windowClosed()
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
            // The headroom changes with screen brightness, so read it each frame.
            engine.headroom = view.colorPixelFormat == .rgba16Float
                ? Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) : 1
            engine.frame(pass: pass, format: view.colorPixelFormat, present: drawable)
            // Ask for no more frames than the GPU can finish: past ~7.5 ms a
            // frame, 120 Hz requests only queue up and every frame gets later.
            let gpu = engine.recentGPUms
            if gpu > 7.5, view.preferredFramesPerSecond > 60 {
                view.preferredFramesPerSecond = 60
            } else if gpu > 0, gpu < 5, view.preferredFramesPerSecond < CanvasEngine.stepsPerSecond {
                view.preferredFramesPerSecond = CanvasEngine.stepsPerSecond
            }
        }
    }
}

/// Every input on the Mac becomes play:
/// - drag stirs (pressure makes it bolder; a deep Force Touch press held ~1 s is a supernova),
/// - click without dragging blooms (in Wells mode: plants a well; Option-click a repeller; right-click removes one),
/// - two or more fingers on the trackpad each stir where they are on the pad,
/// - pinch pushes out or pulls in, rotate swirls,
/// - keys: 1–7 animations, M next mode, K mirror, Space bloom, C clear wells, arrows tilt.
final class CanvasMTKView: MTKView {
    weak var engine: CanvasEngine?
    private var occlusion: NSObjectProtocol?
    private var lastDrag: CGPoint?
    private var dragged = false
    private var pressure = 0.5
    private var touchPoints: [ObjectIdentifier: CGPoint] = [:]
    private var arrows = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }

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
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        window.makeFirstResponder(self)
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

    // MARK: pointer

    override func mouseDown(with event: NSEvent) {
        lastDrag = point(event)
        dragged = false
        pressure = 0.5
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let last = lastDrag, hypot(p.x - last.x, p.y - last.y) > 0.0005 {
            dragged = true
            engine?.stir(from: last, to: p, pressure: pressure)
        }
        lastDrag = p
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { engine?.tap(at: point(event), repel: event.modifierFlags.contains(.option)) }
        engine?.endStroke()
        lastDrag = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if engine?.mode == .wells { engine?.removeWell(near: point(event)) } else { super.rightMouseDown(with: event) }
    }

    override func pressureChange(with event: NSEvent) {
        // Stage 1 pressure 0…1; a deep press (stage 2) adds more and, held, a supernova.
        pressure = Double(event.pressure) + (event.stage >= 2 ? 0.6 : 0)
        engine?.press(at: lastDrag ?? CGPoint(x: 0.5, y: 0.5), deep: event.stage >= 2)
    }

    // MARK: trackpad

    override func touchesBegan(with event: NSEvent) { trackTouches(event) }
    override func touchesMoved(with event: NSEvent) { trackTouches(event) }
    override func touchesEnded(with event: NSEvent) { endTouches(event) }
    override func touchesCancelled(with event: NSEvent) { endTouches(event) }

    /// Two or more fingers: each stirs where it is on the pad (one finger moves the pointer as usual).
    private func trackTouches(_ event: NSEvent) {
        let touches = event.touches(matching: .touching, in: self)
        guard touches.count >= 2 else { touchPoints.removeAll(); return }
        for touch in touches {
            let id = ObjectIdentifier(touch.identity)
            let p = CGPoint(x: touch.normalizedPosition.x, y: 1 - touch.normalizedPosition.y)
            if let last = touchPoints[id], hypot(p.x - last.x, p.y - last.y) > 0.001 {
                engine?.stir(from: last, to: p, pressure: 0.35, pointer: "touch\(id.hashValue)")
            }
            touchPoints[id] = p
        }
    }

    private func endTouches(_ event: NSEvent) {
        for touch in event.touches(matching: [.ended, .cancelled], in: self) {
            let id = ObjectIdentifier(touch.identity)
            touchPoints[id] = nil
            engine?.endStroke(pointer: "touch\(id.hashValue)")
        }
    }

    override func magnify(with event: NSEvent) {
        engine?.vortex(at: point(event), amount: Double(event.magnification) * 6)
    }

    override func rotate(with event: NSEvent) {
        engine?.swirl(at: point(event), radians: -Double(event.rotation) * .pi / 180)
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        guard let engine else { return super.keyDown(with: event) }
        let d = UserDefaults.standard
        if [123, 124, 125, 126].contains(event.keyCode) {
            arrows.insert(event.keyCode)
            updateKeyTilt()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case let c where Int(c).map({ (1...CanvasStyle.allCases.count).contains($0) }) == true:
            d.set(CanvasStyle.allCases[Int(c)! - 1].rawValue, forKey: CanvasStyle.defaultsKey)
            engine.applySettings()
        case "m":
            let all = CanvasMode.allCases
            let next = all[((all.firstIndex(of: engine.mode) ?? 0) + 1) % all.count]
            d.set(next.rawValue, forKey: CanvasMode.defaultsKey)
            engine.applySettings()
            engine.showToast(next.title, seconds: 1.5)
        case "k":
            let all = CanvasSymmetry.choices
            let next = all[((all.firstIndex(of: engine.symmetry) ?? 0) + 1) % all.count]
            d.set(next, forKey: CanvasSymmetry.defaultsKey)
            engine.applySettings()
            engine.showToast("Mirror \(CanvasSymmetry.title(next))", seconds: 1.5)
        case " ":
            engine.tap(at: mouseInView())
        case "c":
            engine.clearWells()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if arrows.remove(event.keyCode) != nil { updateKeyTilt() } else { super.keyUp(with: event) }
    }

    private func updateKeyTilt() {
        let x = (arrows.contains(124) ? 1.0 : 0) - (arrows.contains(123) ? 1 : 0)
        let y = (arrows.contains(125) ? 1.0 : 0) - (arrows.contains(126) ? 1 : 0)
        engine?.setKeyTilt(x: x, y: y)
    }

    // MARK: geometry

    /// 0…1, y down.
    private func point(_ event: NSEvent) -> CGPoint {
        normalised(convert(event.locationInWindow, from: nil))
    }

    private func mouseInView() -> CGPoint {
        guard let window else { return CGPoint(x: 0.5, y: 0.5) }
        return normalised(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func normalised(_ local: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, local.x / max(1, bounds.width))), y: min(1, max(0, 1 - local.y / max(1, bounds.height))))
    }
}

