import SwiftUI
import LightStarCore

/// Mac system shortcuts and hardware keys.
struct MacControlsView: View {
    @ObservedObject var client: RemoteControlClient
    @ObservedObject var settings: RemoteInputSettings
    @StateObject private var mediaHUD = RemoteLevelHUDModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controlGroup("System", tiles: [
                        .init("Spotlight", "magnifyingglass") { client.sendMacAction(.spotlight) },
                        .init("Mission Control", "square.grid.3x3") { client.sendMacAction(.missionControl) },
                        .init("App Windows", "rectangle.stack") { client.sendMacAction(.applicationWindows) },
                        .init("Desktop", "desktopcomputer") { client.sendMacAction(.desktop) },
                        .init("Launchpad", "square.grid.2x2") { client.sendMacAction(.launchpad) },
                        .init("Lock Screen", "lock.fill") { client.sendMacAction(.lockScreen) },
                        .init("Wake Mac", "wake") { client.sendMacAction(.wakeDisplay) },
                    ])

                    controlGroup("Edit", tiles: [
                        .init("Undo", "arrow.uturn.backward") { client.sendMacAction(.undo) },
                        .init("Cut", "scissors") { client.sendMacAction(.cut) },
                        .init("Copy", "doc.on.doc") { client.sendMacAction(.copy) },
                        .init("Paste", "doc.on.clipboard") { client.sendMacAction(.paste) },
                        .init("Select All", "selection.pin.in.out") { client.sendMacAction(.selectAll) },
                        .init("Emoji", "face.smiling") { client.sendMacAction(.emoji) },
                    ])

                    controlGroup("Capture", tiles: [
                        .init("Screenshot", "rectangle.dashed") { client.sendMacAction(.screenshot) },
                        .init("Selection", "camera.viewfinder") { client.sendMacAction(.screenshotSelection) },
                    ])

                    controlGroup("Spaces", tiles: [
                        .init("Space Left", "chevron.left") { client.sendMacAction(.spaceLeft) },
                        .init("Space Right", "chevron.right") { client.sendMacAction(.spaceRight) },
                    ])

                    mediaGroup
                }
                .padding()
            }
            .navigationTitle("Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay {
                if mediaHUD.visible {
                    RemoteLevelHUD(icon: mediaHUD.icon, title: mediaHUD.title, level: mediaHUD.level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: mediaHUD.visible)
            .onChange(of: client.state) { _, newState in
                if case .connected = newState {
                    mediaHUD.reset()
                }
            }
        }
    }

    private func controlGroup(_ title: String, tiles: [MacControlTile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(tiles) { tile in
                    Button {
                        RemoteHaptics.select(enabled: settings.hapticClicks)
                        tile.action()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: tile.icon)
                                .font(.title3)
                                .accessibilityHidden(true)
                            Text(tile.title)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 76)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemFill))
                        )
                    }
                    .buttonStyle(RemotePressButtonStyle())
                    .accessibilityLabel(tile.title)
                }
            }
        }
    }

    private var mediaGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback")
                .font(.headline)
            HStack(spacing: 10) {
                mediaButton("Previous", "backward.fill") { sendMedia(.previousTrack) }
                mediaButton("Play/Pause", "playpause.fill") { sendMedia(.playPause) }
                mediaButton("Next", "forward.fill") { sendMedia(.nextTrack) }
            }
            HStack(spacing: 10) {
                mediaButton("Mute", "speaker.slash.fill") { sendMedia(.mute) }
                mediaButton("Volume Down", "speaker.minus.fill") { sendMedia(.volumeDown) }
                mediaButton("Volume Up", "speaker.plus.fill") { sendMedia(.volumeUp) }
            }
            HStack(spacing: 10) {
                mediaButton("Brightness Down", "sun.min") { sendMedia(.brightnessDown) }
                mediaButton("Brightness Up", "sun.max") { sendMedia(.brightnessUp) }
                Spacer()
            }
        }
    }

    private func sendMedia(_ key: MediaKeyMessage.MediaKey) {
        mediaHUD.handle(key)
        client.sendMediaKey(key)
    }

    private func mediaButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            RemoteHaptics.select(enabled: settings.hapticClicks)
            action()
        } label: {
            Image(systemName: icon)
                .font(.title3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel(title)
    }
}

private struct MacControlTile: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, _ icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }
}
