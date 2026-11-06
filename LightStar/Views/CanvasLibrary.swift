import AppKit
import Observation
import UniformTypeIdentifiers
import LightStarCore

/// Kept canvases on this Mac: save, restore, delete, and export a picture or
/// a wallpaper. The list and thumbnails live in Application Support.
@MainActor @Observable
final class CanvasLibrary {
    static let shared = CanvasLibrary()

    private(set) var scenes: [CanvasScene] = CanvasSceneStore.load()
    private var thumbnails: [UUID: NSImage] = [:]

    func thumbnail(_ scene: CanvasScene) -> NSImage? {
        if let cached = thumbnails[scene.id] { return cached }
        let image = NSImage(contentsOf: CanvasSceneStore.thumbnailURL(scene.id))
        thumbnails[scene.id] = image
        return image
    }

    /// Keeps the canvas as it is now, with a thumbnail.
    func save(_ engine: CanvasEngine) {
        let scene = engine.currentScene(named: CanvasSceneStore.nextName(after: scenes))
        if let image = engine.snapshot(width: 480, height: 270) {
            try? FileManager.default.createDirectory(at: CanvasSceneStore.folder, withIntermediateDirectories: true)
            if writePNG(image, to: CanvasSceneStore.thumbnailURL(scene.id)) {
                thumbnails[scene.id] = NSImage(cgImage: image, size: NSSize(width: 480, height: 270))
            }
        }
        scenes.insert(scene, at: 0)
        persist()
        engine.showToast("Saved as \(scene.name)")
    }

    func restore(_ scene: CanvasScene, into engine: CanvasEngine) { engine.restore(scene) }

    func delete(_ scene: CanvasScene) {
        scenes.removeAll { $0.id == scene.id }
        thumbnails[scene.id] = nil
        try? FileManager.default.removeItem(at: CanvasSceneStore.thumbnailURL(scene.id))
        persist()
    }

    func rename(_ scene: CanvasScene, to name: String) {
        guard let i = scenes.firstIndex(where: { $0.id == scene.id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        scenes[i].name = String(name.prefix(40))
        persist()
    }

    /// A 4K PNG of the canvas, saved where the person chooses.
    func exportPicture(_ engine: CanvasEngine) {
        guard let image = engine.snapshot(width: 3840, height: 2160) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LightStar Canvas.png"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if writePNG(image, to: url) { engine.showToast("Picture saved") }
    }

    /// Sets the canvas, as it is now, as the desktop picture on every screen.
    func setAsWallpaper(_ engine: CanvasEngine) {
        let screen = NSScreen.screens.map { $0.frame.size.applying(.init(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
            .max { $0.width < $1.width } ?? CGSize(width: 3840, height: 2160)
        guard let image = engine.snapshot(width: min(6144, Int(screen.width)), height: min(3456, Int(screen.height))) else { return }
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A new name each time: macOS caches the picture by its path.
        let url = folder.appendingPathComponent("Canvas wallpaper \(Int(Date().timeIntervalSince1970)).png")
        guard writePNG(image, to: url) else { return }
        for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
        engine.showToast("Set as wallpaper")
    }

    private func persist() { try? CanvasSceneStore.save(scenes) }

    private func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
