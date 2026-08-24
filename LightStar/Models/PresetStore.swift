import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable
final class PresetStore {
    var presets: [Preset] = []

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    init() {
        load()
        if presets.isEmpty { presets = Preset.defaults }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: Self.storeURL)
    }

    func exportToFile() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LightStar Presets.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // File I/O is fine off-main; mutations hop back to MainActor
            Task { @MainActor [weak self] in
                guard let data = try? Data(contentsOf: url),
                      let imported = try? JSONDecoder().decode([Preset].self, from: data)
                else { return }
                self?.presets.append(contentsOf: imported.filter { imp in
                    !(self?.presets.contains(where: { $0.id == imp.id }) ?? false)
                })
                self?.save()
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else { return }
        presets = decoded
    }
}
