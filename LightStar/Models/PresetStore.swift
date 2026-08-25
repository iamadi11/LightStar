import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable
final class PresetStore {
    var presets: [Preset] = []
    var iCloudEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudPresetSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iCloudPresetSync")
            if newValue { pushToiCloud() } else { save() }
        }
    }
    var defaultPresetID: UUID? {
        get {
            UserDefaults.standard.string(forKey: "defaultPresetID").flatMap { UUID(uuidString: $0) }
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: "defaultPresetID")
        }
    }

    // iCloud KV store — nil when iCloud account not signed in
    private var kvStore: NSUbiquitousKeyValueStore? {
        FileManager.default.ubiquityIdentityToken != nil ? .default : nil
    }
    private static let iCloudKey = "LightStarPresets"

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    init() {
        load()
        if presets.isEmpty { presets = Preset.defaults }
        observeiCloud()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: Self.storeURL)
        if iCloudEnabled { pushToiCloud() }
    }

    // MARK: - iCloud

    var iCloudAvailable: Bool { kvStore != nil }

    private func pushToiCloud() {
        guard let kv = kvStore,
              let data = try? JSONEncoder().encode(presets)
        else { return }
        kv.set(data, forKey: Self.iCloudKey)
        kv.synchronize()
    }

    private func pullFromiCloud() {
        guard let kv = kvStore,
              let data = kv.data(forKey: Self.iCloudKey),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else { return }
        // Merge: keep local presets not in iCloud, add iCloud presets not local
        let existing = Set(presets.map(\.id))
        let incoming = decoded.filter { !existing.contains($0.id) }
        presets.append(contentsOf: incoming)
        // Replace matching by id with iCloud version (remote wins)
        for remote in decoded {
            if let idx = presets.firstIndex(where: { $0.id == remote.id }) {
                presets[idx] = remote
            }
        }
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: Self.storeURL) }
    }

    private func observeiCloud() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main) { [weak self] _ in
                guard let self, self.iCloudEnabled else { return }
                Task { @MainActor in self.pullFromiCloud() }
            }
        // Pull on launch if enabled
        if iCloudEnabled { pullFromiCloud() }
    }

    // MARK: - Export / Import

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
