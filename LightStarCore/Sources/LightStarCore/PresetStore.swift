import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor @Observable
public final class PresetStore {
    public var presets: [Preset] = []
    public var iCloudEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudPresetSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iCloudPresetSync")
            if newValue { pushToiCloud() } else { save() }
        }
    }
    public var defaultPresetID: UUID? {
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
    // nonisolated(unsafe): observer token is set on the main actor; deinit must
    // be able to remove it under Swift 6 isolation rules.
    nonisolated(unsafe) private var iCloudObserver: NSObjectProtocol?

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    public init() {
        load()
        if presets.isEmpty { presets = Preset.defaults }
        observeiCloud()
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        if iCloudEnabled { pushToiCloud() }
    }

    // MARK: - iCloud

    public var iCloudAvailable: Bool { kvStore != nil }

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
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: Self.storeURL, options: .atomic) }
    }

    private func observeiCloud() {
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.iCloudEnabled else { return }
                    self.pullFromiCloud()
                }
            }
        // Pull on launch if enabled
        if iCloudEnabled { pullFromiCloud() }
    }
    
    deinit {
        if let observer = iCloudObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Export / Import

    public func encodedJSON() -> Data? {
        try? JSONEncoder().encode(presets)
    }

    public func mergeImported(_ imported: [Preset]) {
        presets.append(contentsOf: imported.filter { imp in
            !presets.contains(where: { $0.id == imp.id })
        })
        save()
    }

    #if os(macOS)
    public func exportToFile() {
        guard let data = encodedJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LightStar Presets.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    public func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let data = try? Data(contentsOf: url),
                      let imported = try? JSONDecoder().decode([Preset].self, from: data)
                else { return }
                self?.mergeImported(imported)
            }
        }
    }
    #endif

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else { return }
        presets = decoded
    }
}
