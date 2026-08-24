import SwiftUI

struct SyncModePickerView: View {
    @Environment(LightBLEManager.self) private var ble

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Sync", systemImage: "waveform.and.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.syncTransitioning { ProgressView().controlSize(.mini) }
            }

            Picker("", selection: Binding(
                get: { ble.syncMode },
                set: { ble.setSyncMode($0) }
            )) {
                ForEach(LightBLEManager.SyncMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .disabled(ble.syncTransitioning)

            if let err = ble.syncError {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundStyle(ble.syncMode == .off ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if ble.syncMode == .audio {
                Picker("", selection: Binding(
                    get: { ble.audioSyncMode },
                    set: { ble.audioSyncMode = $0 }
                )) {
                    ForEach(LightBLEManager.AudioSyncMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }

            Text(modeDescription)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            if ble.isSyncingVideo {
                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { ble.selectedDisplayID },
                        set: { ble.selectedDisplayID = $0 }
                    )) {
                        Text("Primary display").tag(Optional<CGDirectDisplayID>.none)
                        ForEach(ble.availableDisplays, id: \.id) { d in
                            Text(d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).controlSize(.small)
                    Button { ble.loadAvailableDisplays() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).font(.caption).help("Refresh display list")
                }
                .onAppear { ble.loadAvailableDisplays() }
            }
        }
    }

    private var modeDescription: String {
        switch ble.syncMode {
        case .off:      return "No sync — color picker and presets above are active"
        case .video:    return "Edges weighted 3× · brightness stays at slider · 20 Hz"
        case .audio:
            switch ble.audioSyncMode {
            case .rainbow:   return "Beats → hue · treble → drift · bass → brightness"
            case .pulse:     return "Bass → brightness · keeps current color"
            case .frequency: return "Bass → red · mid → green · treble → blue"
            }
        case .combined: return "Screen → color · audio beats → brightness · no mic needed"
        }
    }
}
