import Foundation

/// HSV the strip should show from a screen frame.
public struct ScreenHSV: Sendable, Equatable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// DRM black frames must not drive the strip to black. Hold the last capturable color.
public enum ScreenColorWrite: Equatable, Sendable {
    case write(ScreenHSV)
    case holdLastColor
}

/// One detection path for persistent rectangular black (ScreenCaptureKit DRM substitute).
/// Dark IDE chrome is not a rectangular black region and must not trip the guide.
public enum ProtectedContentPolicy: Sendable {
    public static let blackPixelThreshold = 0.6
    public static let confirmationFrameCount = 30

    public static func isProtectedFrame(_ analysis: FrameAnalysis) -> Bool {
        analysis.blackPixelPercentage > blackPixelThreshold && analysis.hasRectangularBlackRegion
    }

    public static func screenColorWrite(for analysis: FrameAnalysis) -> ScreenColorWrite {
        if isProtectedFrame(analysis) { return .holdLastColor }
        return .write(ScreenHSV(
            hue: analysis.dominantHue,
            saturation: analysis.dominantSaturation,
            brightness: analysis.dominantBrightness
        ))
    }

    public static func shouldShowGuide(consecutiveProtectedFrames: Int) -> Bool {
        consecutiveProtectedFrames >= confirmationFrameCount
    }
}

/// Consecutive-frame tracker used by the sampler. UI shows the guide only when `showsGuide`.
public struct ProtectedContentTracker: Sendable, Equatable {
    public private(set) var consecutiveProtectedFrames = 0
    public private(set) var lastGood: ScreenHSV?

    public init() {}

    public var showsGuide: Bool {
        ProtectedContentPolicy.shouldShowGuide(consecutiveProtectedFrames: consecutiveProtectedFrames)
    }

    public mutating func ingest(_ analysis: FrameAnalysis) -> ScreenColorWrite {
        let write = ProtectedContentPolicy.screenColorWrite(for: analysis)
        switch write {
        case .write(let hsv):
            consecutiveProtectedFrames = 0
            lastGood = hsv
            return write
        case .holdLastColor:
            consecutiveProtectedFrames += 1
            return .holdLastColor
        }
    }

    public mutating func reset() {
        consecutiveProtectedFrames = 0
        lastGood = nil
    }
}

/// Copy shown in the Mac popover after N consecutive protected frames.
public struct ProtectedContentBanner: Equatable, Sendable {
    public let message: String
    public let steps: [String]
    public let notes: [String]
    public let settingsURL: URL?
    public let openSettingsTitle: String?

    public init(
        message: String,
        steps: [String],
        notes: [String],
        settingsURL: URL? = nil,
        openSettingsTitle: String? = nil
    ) {
        self.message = message
        self.steps = steps
        self.notes = notes
        self.settingsURL = settingsURL
        self.openSettingsTitle = openSettingsTitle
    }
}
