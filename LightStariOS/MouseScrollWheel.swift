import SwiftUI
import LightStarCore

/// A mouse wheel beside the trackpad. Ridges turn with the finger, faster when the flick is faster.
struct MouseScrollWheel: View {
    var hapticsEnabled: Bool
    var onScroll: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0
    @State private var fingerRemainder: Double = 0
    @State private var lastTranslation: CGFloat = 0
    @State private var lastTick = Date.distantPast
    @State private var dragging = false
    @State private var coastTask: Task<Void, Never>?

    private let pitch = 14.0

    var body: some View {
        VStack(spacing: 8) {
            nudgeButton(up: true)
            wheel
            nudgeButton(up: false)
        }
        .frame(width: 56)
        .onDisappear { coastTask?.cancel() }
    }

    private var wheel: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
            ridgeField
                .padding(.horizontal, 7)
                .padding(.vertical, 12)
                .mask(ridgeFade)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.02),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .allowsHitTesting(false)
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: 120)
        .scaleEffect(dragging && !reduceMotion ? 1.03 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dragging)
        .contentShape(Capsule(style: .continuous))
        .gesture(drag)
        .accessibilityElement()
        .accessibilityLabel("Scroll wheel")
        .accessibilityHint("Drag up or down. A faster drag scrolls further and the wheel keeps turning after you let go.")
        .accessibilityAdjustableAction { direction in
            nudge(up: direction == .increment)
        }
    }

    private var ridgeField: some View {
        Canvas { context, size in
            var phase = spin.truncatingRemainder(dividingBy: pitch)
            if phase < 0 { phase += pitch }
            var y = -pitch + phase
            while y < size.height + pitch {
                let ridge = Path(
                    roundedRect: CGRect(x: 2, y: y, width: max(0, size.width - 4), height: 3.5),
                    cornerRadius: 1.5
                )
                context.fill(ridge, with: .color(Color.primary.opacity(0.42)))
                let groove = Path(
                    roundedRect: CGRect(x: 2, y: y + 4.5, width: max(0, size.width - 4), height: 2),
                    cornerRadius: 1
                )
                context.fill(groove, with: .color(Color.black.opacity(0.18)))
                y += pitch
            }
        }
        .allowsHitTesting(false)
    }

    private var ridgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func nudgeButton(up: Bool) -> some View {
        Button {
            nudge(up: up)
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: 56, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel(up ? "Scroll up" : "Scroll down")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging { dragging = true }
                coastTask?.cancel()
                let delta = Double(value.translation.height - lastTranslation)
                lastTranslation = value.translation.height
                let speed = Double(value.velocity.height)
                emit(
                    pixels: ScrollWheelTracking.pixels(deltaPoints: delta, pointsPerSecond: speed),
                    travel: reduceMotion ? delta : ScrollWheelTracking.visualTravel(deltaPoints: delta, pointsPerSecond: speed)
                )
            }
            .onEnded { value in
                dragging = false
                lastTranslation = 0
                let pointsPerSecond = Double(value.velocity.height)
                var velocity = ScrollWheelTracking.coastVelocity(pointsPerSecond: pointsPerSecond)
                coastTask = Task { @MainActor in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        let step = ScrollWheelTracking.coast(velocityPixelsPerSecond: velocity, dt: 0.016)
                        velocity = step.velocity
                        guard step.delta != 0 else { return }
                        let travel = reduceMotion ? step.delta / ScrollWheelTracking.slowGain : step.delta / 8
                        emit(pixels: step.delta, travel: travel)
                    }
                }
            }
    }

    private func nudge(up: Bool) {
        coastTask?.cancel()
        dragging = false
        let pixels = up ? -240.0 : 240.0
        let travel = up ? -pitch * 2 : pitch * 2
        onScroll(pixels)
        if reduceMotion {
            spin += travel
        } else {
            withAnimation(.spring(duration: 0.28, bounce: 0.12)) {
                spin += travel
            }
        }
        RemoteHaptics.tick(enabled: hapticsEnabled)
    }

    private func emit(pixels: Double, travel: Double) {
        guard pixels.isFinite, pixels != 0 else { return }
        onScroll(pixels)
        spin += travel
        if abs(spin) > 100_000 {
            spin = spin.truncatingRemainder(dividingBy: pitch)
        }
        let step = ScrollWheelDetent.consume(accumulated: fingerRemainder, delta: travel)
        fingerRemainder = step.remainder
        guard step.notches != 0, hapticsEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.05 else { return }
        lastTick = now
        RemoteHaptics.tick(enabled: true)
    }
}
