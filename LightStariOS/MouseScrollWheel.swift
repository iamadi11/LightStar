import SwiftUI
import LightStarCore

/// Vertical notched wheel. Dragging it scrolls the Mac one tick per notch.
struct MouseScrollWheel: View {
    var hapticsEnabled: Bool
    var onNotches: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remainder: Double = 0
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            ridgeStack
                .mask(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .padding(3)
                )
        }
        .frame(width: 44)
        .frame(maxHeight: 220)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(drag)
        .accessibilityElement()
        .accessibilityLabel("Scroll wheel")
        .accessibilityHint("Drag up or down to scroll the Mac. Each notch clicks when haptics are on.")
        .accessibilityAdjustableAction { direction in
            let notches = direction == .increment ? -1 : 1
            emit(notches)
        }
    }

    private var ridgeStack: some View {
        let offset = reduceMotion ? 0 : remainder
        return VStack(spacing: 8) {
            ForEach(0..<9, id: \.self) { _ in
                Capsule()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 22, height: 3)
            }
        }
        .offset(y: offset)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = Double(value.translation.height - lastTranslation)
                lastTranslation = value.translation.height
                let step = ScrollWheelDetent.consume(accumulated: remainder, delta: delta)
                remainder = step.remainder
                if step.notches != 0 {
                    emit(step.notches)
                }
            }
            .onEnded { _ in
                lastTranslation = 0
            }
    }

    private func emit(_ notches: Int) {
        guard notches != 0 else { return }
        onNotches(notches)
        let ticks = min(abs(notches), 3)
        for _ in 0..<ticks {
            RemoteHaptics.tick(enabled: hapticsEnabled)
        }
    }
}
