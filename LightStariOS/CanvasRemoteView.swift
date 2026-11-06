import SwiftUI
import UIKit
import CoreMotion
import LightStarCore

/// The Mac's Canvas on the phone: mood, mode, look, mirror, tones, and a
/// multi-touch pad that plays it. Each phone paints in its own colour, so
/// friends can join from their phones; the lights follow all of it.
struct CanvasRemoteSection: View {
    let canvas: CanvasState
    let following: Bool
    let client: RemoteControlClient
    @StateObject private var tilt = CanvasTiltSender()
    /// When the Mac's current breath began, pinned when its state arrives
    /// (not on every redraw, which would drift).
    @State private var breathStart: Date?

    private var mode: CanvasMode { CanvasMode(rawValue: canvas.mode) ?? .auto }
    private let player = CanvasPlayerID.current

    var body: some View {
        Section {
            Toggle("Lights follow the Canvas", isOn: Binding(
                get: { following },
                set: { client.setSyncMode($0 ? "Canvas" : "Off") }
            ))
            Picker("Mood", selection: Binding(
                get: { canvas.mood ?? CanvasMood.none.rawValue },
                set: { send(SetCanvasMessage(mood: $0)) }
            )) {
                ForEach(CanvasMood.allCases) { Text($0.title).tag($0.rawValue) }
            }
            modeChips
            Picker("Animation", selection: Binding(
                get: { canvas.style },
                set: { send(SetCanvasMessage(style: $0)) }
            )) {
                ForEach(CanvasStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Mirror", selection: Binding(
                get: { canvas.symmetry ?? 1 },
                set: { send(SetCanvasMessage(symmetry: $0)) }
            )) {
                ForEach(CanvasSymmetry.choices, id: \.self) { Text(CanvasSymmetry.title($0)).tag($0) }
            }
            Toggle("Tones on the Mac", isOn: Binding(
                get: { canvas.sound ?? false },
                set: { send(SetCanvasMessage(sound: $0)) }
            ))
            CanvasPad(mode: mode, player: player, breath: breath, send: send)
            modeRow
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hue: CanvasPlayer.hue(for: player), saturation: 0.9, brightness: 1))
                    .frame(width: 14, height: 14)
                Text("Your colour").font(.footnote)
                Spacer()
                if let players = canvas.players, players > 0 {
                    Label("\(players) playing", systemImage: "iphone").font(.footnote).foregroundStyle(.secondary)
                }
                if let found = canvas.discoveries {
                    Label("\(found)/\(CanvasDiscovery.allCases.count)", systemImage: "sparkle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("\(found) of \(CanvasDiscovery.allCases.count) discoveries found")
                }
            }
            Picker("Quality", selection: Binding(
                get: { canvas.quality },
                set: { send(SetCanvasMessage(quality: $0)) }
            )) {
                ForEach(CanvasQuality.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Canvas")
        } footer: {
            Text(mode.summary + " Several phones can play at once, each in its own colour.")
        }
        .onAppear { tilt.update(active: mode == .tilt, send: send); pinBreath() }
        .onChange(of: canvas.breathPhase) { _, _ in pinBreath() }
        .onChange(of: canvas.mode) { _, _ in tilt.update(active: mode == .tilt, send: send) }
        .onDisappear { tilt.update(active: false, send: send) }
    }

    private var breath: (cycle: Double, start: Date)? {
        guard mode == .breathe, let cycle = canvas.breathCycle, cycle > 0, let breathStart else { return nil }
        return (cycle, breathStart)
    }

    private func pinBreath() {
        guard let cycle = canvas.breathCycle, let phase = canvas.breathPhase else { breathStart = nil; return }
        breathStart = Date().addingTimeInterval(-phase * cycle)
    }

    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CanvasMode.allCases) { m in
                    Button {
                        send(SetCanvasMessage(mode: m.rawValue))
                    } label: {
                        Label(m.title, systemImage: m.symbol)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(m == mode ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(m == mode ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var modeRow: some View {
        switch mode {
        case .wells:
            HStack {
                Text("Tap to plant a well, long-press for a repeller.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Clear (\(canvas.wells ?? 0))") { send(SetCanvasMessage(clearWells: true)) }
                    .disabled((canvas.wells ?? 0) == 0)
            }
        case .tilt:
            HStack {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                Text(tilt.active ? "Tilt the phone to pour; shake to splash." : "Motion isn't available on this device.")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func send(_ change: SetCanvasMessage) {
        var c = change
        c.player = player
        client.setCanvas(c)
    }
}

/// This phone's id on the canvas (its colour). Stays the same across launches.
@MainActor
enum CanvasPlayerID {
    static let current: String = {
        let key = "canvasPlayerID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
}

/// The 16:9 play surface. Every finger stirs (with a soft haptic tick as it
/// travels); a tap blooms or, in Wells mode, plants a well (long-press for a
/// repeller); in Breathe mode it shows the breath and taps with it.
private struct CanvasPad: View {
    let mode: CanvasMode
    let player: String
    let breath: (cycle: Double, start: Date)?
    let send: (SetCanvasMessage) -> Void

    var body: some View {
        let hue = CanvasPlayer.hue(for: player)
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.85, brightness: 0.9), .purple, .blue, .cyan],
                                     startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.35))
            if let breath {
                BreathCircle(cycle: breath.cycle, start: breath.start)
            } else {
                Image(systemName: mode.symbol).font(.title2).foregroundStyle(.secondary)
            }
            TouchPadRepresentable(mode: mode) { event in
                switch event {
                case let .stir(from, to, finger):
                    send(SetCanvasMessage(stir: [from.x, from.y, to.x, to.y], finger: finger))
                case let .end(finger):
                    send(SetCanvasMessage(finger: finger, strokeEnd: true))
                case let .tap(p):
                    send(mode == .wells ? SetCanvasMessage(well: [p.x, p.y, 1]) : SetCanvasMessage(tap: [p.x, p.y]))
                case let .longPress(p):
                    send(mode == .wells ? SetCanvasMessage(well: [p.x, p.y, -1]) : SetCanvasMessage(tap: [p.x, p.y]))
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Canvas pad")
        .accessibilityHint(mode == .wells ? "Tap to plant a well; long-press for a repeller" : "Drag with one or more fingers to stir the Canvas on the Mac")
    }
}

/// Grows while breathing in and shrinks while breathing out, in step with
/// the Mac, with a gentle haptic at each turn.
private struct BreathCircle: View {
    let cycle: Double
    let start: Date
    @State private var wasInhaling: Bool?

    var body: some View {
        TimelineView(.animation) { context in
            let pacer = BreathPacer(breathsPerMinute: 60 / cycle)
            let t = context.date.timeIntervalSince(start)
            let full = pacer.fullness(at: t)
            let inhaling = pacer.isInhaling(at: t)
            VStack(spacing: 6) {
                Circle()
                    .fill(.white.opacity(0.25 + 0.35 * full))
                    .frame(width: 30 + 60 * full, height: 30 + 60 * full)
                Text(inhaling ? "Breathe in" : "Breathe out").font(.footnote).foregroundStyle(.secondary)
            }
            .onChange(of: inhaling) { _, now in
                guard wasInhaling != nil else { wasInhaling = now; return }
                wasInhaling = now
                UIImpactFeedbackGenerator(style: now ? .soft : .light).impactOccurred(intensity: now ? 0.7 : 0.4)
            }
        }
        .allowsHitTesting(false)
    }
}

enum PadEvent {
    case stir(from: CGPoint, to: CGPoint, finger: Int)
    case end(finger: Int)
    case tap(CGPoint)
    case longPress(CGPoint)
}

private struct TouchPadRepresentable: UIViewRepresentable {
    let mode: CanvasMode
    let onEvent: (PadEvent) -> Void

    func makeUIView(context: Context) -> TouchPadView {
        let view = TouchPadView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ view: TouchPadView, context: Context) { view.onEvent = onEvent }
}

/// Multi-touch: each finger gets a small id and its own stroke. Sends at most
/// 60 moves a second per finger.
final class TouchPadView: UIView {
    var onEvent: ((PadEvent) -> Void)?
    private struct Finger { var id: Int; var last: CGPoint; var start: CGPoint; var began: TimeInterval; var moved = false; var sent: TimeInterval = 0; var travelled: CGFloat = 0 }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func point(_ t: UITouch) -> CGPoint {
        let p = t.location(in: self)
        return CGPoint(x: min(1, max(0, p.x / max(1, bounds.width))), y: min(1, max(0, p.y / max(1, bounds.height))))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        haptic.prepare()
        for t in touches {
            let used = Set(fingers.values.map(\.id))
            let id = (0..<10).first { !used.contains($0) } ?? 0
            let p = point(t)
            fingers[ObjectIdentifier(t)] = Finger(id: id, last: p, start: p, began: t.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard var f = fingers[ObjectIdentifier(t)] else { continue }
            let p = point(t)
            if hypot(p.x - f.start.x, p.y - f.start.y) > 0.015 { f.moved = true }
            if f.moved, t.timestamp - f.sent >= 1.0 / 60 {
                let step = hypot(p.x - f.last.x, p.y - f.last.y)
                onEvent?(.stir(from: f.last, to: p, finger: f.id))
                f.travelled += step
                // A soft tick every so often, firmer when moving fast.
                if f.travelled > 0.06 {
                    f.travelled = 0
                    haptic.impactOccurred(intensity: min(1, 0.3 + step * 12))
                }
                f.sent = t.timestamp
                f.last = p
            }
            fingers[ObjectIdentifier(t)] = f
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            guard let f = fingers.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            if !f.moved, !cancelled {
                let long = t.timestamp - f.began > 0.45
                onEvent?(long ? .longPress(f.start) : .tap(f.start))
                UIImpactFeedbackGenerator(style: long ? .heavy : .rigid).impactOccurred(intensity: 0.7)
            }
            onEvent?(.end(finger: f.id))
        }
    }
}

/// Streams the phone's gravity to the Mac in Tilt mode (30 a second, only
/// when it changed) and turns a shake into a splash.
@MainActor
final class CanvasTiltSender: ObservableObject {
    @Published private(set) var active = false
    private let motion = CMMotionManager()
    private var lastSent = SIMD2<Double>(9, 9)
    private var lastShake = Date.distantPast

    func update(active want: Bool, send: @escaping (SetCanvasMessage) -> Void) {
        guard want != active else { return }
        if want, motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                // Screen axes: x right, y down (the device's y points up the screen).
                let g = SIMD2(data.gravity.x, -data.gravity.y)
                if abs(g.x - self.lastSent.x) > 0.02 || abs(g.y - self.lastSent.y) > 0.02 {
                    self.lastSent = g
                    send(SetCanvasMessage(tilt: [g.x, g.y]))
                }
                let a = data.userAcceleration
                if (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 2.0, Date().timeIntervalSince(self.lastShake) > 0.7 {
                    self.lastShake = Date()
                    send(SetCanvasMessage(shake: true))
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
            active = true
        } else {
            motion.stopDeviceMotionUpdates()
            active = false
        }
    }
}
