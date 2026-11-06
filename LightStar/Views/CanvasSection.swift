import SwiftUI
import LightStarCore

private struct CanvasEngineKey: EnvironmentKey {
    static let defaultValue: CanvasEngine? = nil
}

extension EnvironmentValues {
    /// The app's Canvas liquid. A plain reference: it changes every frame, so
    /// it isn't observed (its `status` is).
    var canvasEngine: CanvasEngine? {
        get { self[CanvasEngineKey.self] }
        set { self[CanvasEngineKey.self] = newValue }
    }
}

/// The Canvas controls: lights follow it, mood, mode, animation, mirror,
/// sound, quality, session length, saved canvases and discoveries. The same
/// settings the window's control bar and the iPhone change.
struct CanvasSection: View {
    @Environment(LightBLEManager.self) private var ble
    @Environment(\.canvasEngine) private var engine
    @AppStorage(CanvasMode.defaultsKey) private var mode = CanvasMode.auto
    @AppStorage(CanvasStyle.defaultsKey) private var style = CanvasStyle.liquid
    @AppStorage(CanvasQuality.defaultsKey) private var quality = CanvasQuality.uhd
    @AppStorage(CanvasSymmetry.defaultsKey) private var symmetry = 1
    @AppStorage(CanvasMood.defaultsKey) private var mood = CanvasMood.none
    @AppStorage(CanvasMood.sessionDefaultsKey) private var sessionMinutes = 0
    @AppStorage(CanvasEngine.breatheMinutesKey) private var breatheMinutes = 3
    @AppStorage(CanvasSound.defaultsKey) private var soundOn = false
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Canvas", systemImage: "drop.halffull")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show Canvas") { openLightStarCanvas() }
                    .controlSize(.small)
                    .help("Opens the Canvas. The lights follow it.")
            }
            Toggle("Lights follow the Canvas", isOn: Binding(
                get: { ble.syncMode == .canvas },
                set: { ble.setSyncMode($0 ? .canvas : .off) }
            ))
            .font(.caption)
            .disabled(ble.syncTransitioning)
            .help("Straight from the Canvas: no screen recording. Keeps running with the window closed.")

            row("Mood") {
                Picker("Mood", selection: Binding(get: { mood }, set: { engine?.applyMood($0) })) {
                    ForEach(CanvasMood.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .help(mood.summary)
            }
            if mood.endsByItself {
                row("Ends after") {
                    Picker("Ends after", selection: $sessionMinutes) {
                        Text("Never").tag(0)
                        ForEach([15, 25, 30, 45, 50, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden()
                    .help(mood == .windDown ? "The room dims over this time, then the lights turn off." : "A gentle chime when it's time for a break.")
                }
            }
            row("Mode") {
                Picker("Mode", selection: $mode) {
                    ForEach(CanvasMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .help(mode.summary)
            }
            if mode == .breathe {
                row("Breathe for") {
                    Picker("Breathe for", selection: $breatheMinutes) {
                        Text("Open-ended").tag(0)
                        ForEach([1, 3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Text(mode.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            row("Animation") {
                Picker("Animation", selection: $style) {
                    ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            row("Mirror") {
                Picker("Mirror", selection: $symmetry) {
                    ForEach(CanvasSymmetry.choices, id: \.self) { Text(CanvasSymmetry.title($0)).tag($0) }
                }
                .labelsHidden()
                .help("Kaleidoscope: every stir, tap and well is repeated around the centre.")
            }
            Toggle("Soft tones as you play", isOn: $soundOn)
                .font(.caption)
                .help("Each stir rings a note: higher up, higher pitch. Silent in Music mode.")

            DisclosureGroup("More", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Quality", selection: $quality) {
                        ForEach(CanvasQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("4K draws the liquid finer than most screens and filters it down, so it stays sharp on 2K and 4K.")
                    SavedCanvasesView()
                    DiscoveriesView()
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .controlSize(.small)
        .onChange(of: mode) { _, _ in engine?.applySettings() }
        .onChange(of: style) { _, _ in engine?.applySettings() }
        .onChange(of: symmetry) { _, _ in engine?.applySettings() }
        .onChange(of: quality) { _, _ in engine?.applyQuality() }
        .onChange(of: soundOn) { _, on in engine?.sound?.enabled = on }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content()
        }
    }
}

/// Kept canvases as thumbnails: click to bring one back.
private struct SavedCanvasesView: View {
    @Environment(\.canvasEngine) private var engine
    private let library = CanvasLibrary.shared
    @State private var renaming: CanvasScene?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved canvases").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save this one") { if let engine { library.save(engine) } }
                    .help("Keeps the look, mode, mirror, mood and wells, with a thumbnail.")
            }
            if library.scenes.isEmpty {
                Text("Nothing saved yet.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(library.scenes) { scene in
                            Button {
                                if let engine { library.restore(scene, into: engine) }
                            } label: {
                                VStack(spacing: 2) {
                                    Group {
                                        if let image = library.thumbnail(scene) {
                                            Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                                        } else {
                                            Rectangle().fill(.quaternary)
                                        }
                                    }
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(scene.name).font(.caption2).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("\(scene.style.title), \(scene.mode.title)")
                            .contextMenu {
                                Button("Rename…") { newName = scene.name; renaming = scene }
                                Button("Delete", role: .destructive) { library.delete(scene) }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Save picture…") { if let engine { library.exportPicture(engine) } }
                Button("Set as wallpaper") { if let engine { library.setAsWallpaper(engine) } }
            }
        }
        .alert("Rename canvas", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { library.rename(r, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

/// Found discoveries by name; the rest as gentle hints.
private struct DiscoveriesView: View {
    @Environment(\.canvasEngine) private var engine

    var body: some View {
        let found = engine?.status.found ?? CanvasDiscovery.found
        VStack(alignment: .leading, spacing: 3) {
            Text("Discoveries \(found.count) of \(CanvasDiscovery.allCases.count)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(CanvasDiscovery.allCases) { d in
                HStack(spacing: 6) {
                    Image(systemName: found.contains(d) ? "sparkle" : "questionmark.circle")
                        .foregroundStyle(found.contains(d) ? Color.yellow : Color.secondary)
                        .frame(width: 14)
                    Text(found.contains(d) ? d.title : d.hint)
                        .font(.caption2)
                        .foregroundStyle(found.contains(d) ? .primary : .secondary)
                }
            }
        }
    }
}
