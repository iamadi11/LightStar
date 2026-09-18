#if os(iOS)
import CoreGraphics
import Foundation

public typealias CGDirectDisplayID = UInt32

@MainActor
public final class ScreenColorSampler: NSObject {
    public var onColor: ((Double, Double, Double) -> Void)?
    public var selectedDisplayID: CGDirectDisplayID?
    public func start() async throws {
        throw NSError(domain: "ScreenCapture", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Screen sync is macOS only"])
    }
    public func stop() async {}
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] { [] }
}

@MainActor
public final class SystemAudioSampler: NSObject {
    public var onBands: ((FrequencyBands) -> Void)?
    public func start() async throws {
        throw NSError(domain: "SystemAudio", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "System audio capture is macOS only"])
    }
    public func stop() async {}
}
#endif
