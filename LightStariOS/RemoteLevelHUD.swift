import SwiftUI
import LightStarCore

struct RemoteLevelHUD: View {
    let icon: String
    let title: String
    var level: Double?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let level {
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { index in
                        Capsule()
                            .fill(Double(index) < level * 16 ? Color.primary : Color.primary.opacity(0.18))
                            .frame(width: 6, height: index == 15 ? 18 : 12)
                    }
                }
                .accessibilityValue("\(Int((level * 100).rounded())) percent")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

@MainActor
final class RemoteLevelHUDModel: ObservableObject {
    @Published private(set) var icon = "speaker.wave.2.fill"
    @Published private(set) var title = ""
    @Published private(set) var level: Double?
    @Published private(set) var visible = false

    private var volume: Double?
    private var brightness: Double?
    private var pendingVolume: Double?
    private var pendingBrightness: Double?
    private var hideTask: Task<Void, Never>?

    /// Drop learned levels so the next Mac snapshot can seed them.
    func reset() {
        volume = nil
        brightness = nil
        pendingVolume = nil
        pendingBrightness = nil
        visible = false
        hideTask?.cancel()
        hideTask = nil
    }

    /// Apply the Mac's live levels. While the HUD is on screen, hold the
    /// update until it hides so a press doesn't snap back to the previous value.
    func adopt(systemVolume: Double?, systemBrightness: Double?) {
        if visible {
            if let systemVolume { pendingVolume = systemVolume }
            if let systemBrightness { pendingBrightness = systemBrightness }
            return
        }
        apply(systemVolume: systemVolume, systemBrightness: systemBrightness)
    }

    func handle(_ key: MediaKeyMessage.MediaKey) {
        switch key {
        case .volumeUp:
            if let volume {
                self.volume = SystemLevelStep.next(current: volume, delta: SystemLevelStep.notch)
            }
            show(icon: "speaker.wave.3.fill", title: "Volume", level: volume)
        case .volumeDown:
            if let volume {
                self.volume = SystemLevelStep.next(current: volume, delta: -SystemLevelStep.notch)
            }
            show(icon: self.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill", title: "Volume", level: volume)
        case .mute:
            show(icon: "speaker.slash.fill", title: "Mute", level: nil)
        case .brightnessUp:
            if let brightness {
                self.brightness = SystemLevelStep.next(current: brightness, delta: SystemLevelStep.notch)
            }
            show(icon: "sun.max.fill", title: "Brightness", level: brightness)
        case .brightnessDown:
            if let brightness {
                self.brightness = SystemLevelStep.next(current: brightness, delta: -SystemLevelStep.notch)
            }
            show(icon: "sun.min.fill", title: "Brightness", level: brightness)
        case .playPause:
            show(icon: "playpause.fill", title: "Play / Pause", level: nil)
        case .nextTrack:
            show(icon: "forward.fill", title: "Next", level: nil)
        case .previousTrack:
            show(icon: "backward.fill", title: "Previous", level: nil)
        }
    }

    private func show(icon: String, title: String, level: Double?) {
        self.icon = icon
        self.title = title
        self.level = level
        visible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.visible = false
            self?.applyPending()
        }
    }

    private func apply(systemVolume: Double?, systemBrightness: Double?) {
        if let systemVolume, systemVolume.isFinite {
            volume = SystemLevelStep.clamped(systemVolume)
        }
        if let systemBrightness, systemBrightness.isFinite {
            brightness = SystemLevelStep.clamped(systemBrightness)
        }
    }

    private func applyPending() {
        apply(systemVolume: pendingVolume, systemBrightness: pendingBrightness)
        pendingVolume = nil
        pendingBrightness = nil
    }
}
