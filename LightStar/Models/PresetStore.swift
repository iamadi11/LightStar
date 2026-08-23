import Foundation

@Observable
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

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else { return }
        presets = decoded
    }
}
