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

    private var volume = 0.5
    private var brightness = 0.5
    private var hideTask: Task<Void, Never>?

    func handle(_ key: MediaKeyMessage.MediaKey) {
        switch key {
        case .volumeUp:
            volume = min(1, volume + 1.0 / 16.0)
            show(icon: "speaker.wave.3.fill", title: "Volume", level: volume)
        case .volumeDown:
            volume = max(0, volume - 1.0 / 16.0)
            show(icon: volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill", title: "Volume", level: volume)
        case .mute:
            show(icon: "speaker.slash.fill", title: "Mute", level: nil)
        case .brightnessUp:
            brightness = min(1, brightness + 1.0 / 16.0)
            show(icon: "sun.max.fill", title: "Brightness", level: brightness)
        case .brightnessDown:
            brightness = max(0, brightness - 1.0 / 16.0)
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
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            visible = false
        }
    }
}
