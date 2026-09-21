#if os(macOS)
import Foundation
import AppKit

/// Browser detection and honest DRM copy. Frame classification lives in `ProtectedContentPolicy`.
@MainActor
public final class CaptureDiagnostics: ObservableObject {

    @Published public private(set) var status: DiagnosticStatus = .normal
    @Published public private(set) var protectedContentSuspected = false
    @Published public private(set) var averageBlackPercentage: Double = 0
    @Published public private(set) var consecutiveProtectedFrames = 0
    @Published public private(set) var detectedBrowser: BrowserInfo?
    public private(set) var isBrowserMonitoring = false

    public enum DiagnosticStatus: String {
        case normal = "Normal"
        case suspectedProtection = "Suspected Protected Content"
        case confirmedProtection = "Protected Content Detected"
        case browserCompatibilityMode = "Browser Compatibility Mode Available"
    }

    public struct BrowserInfo: Equatable, Sendable {
        public let name: String
        public let bundleID: String
        public let supportsHWAccelToggle: Bool

        public static let chrome = BrowserInfo(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            supportsHWAccelToggle: true
        )

        public static let chromium = BrowserInfo(
            name: "Chromium",
            bundleID: "org.chromium.Chromium",
            supportsHWAccelToggle: true
        )

        public static let edge = BrowserInfo(
            name: "Microsoft Edge",
            bundleID: "com.microsoft.edgemac",
            supportsHWAccelToggle: true
        )

        public static let brave = BrowserInfo(
            name: "Brave",
            bundleID: "com.brave.Browser",
            supportsHWAccelToggle: true
        )

        public static let safari = BrowserInfo(
            name: "Safari",
            bundleID: "com.apple.Safari",
            supportsHWAccelToggle: false
        )

        public static let firefox = BrowserInfo(
            name: "Firefox",
            bundleID: "org.mozilla.firefox",
            supportsHWAccelToggle: true
        )

        public static let allBrowsers: [BrowserInfo] = [
            .chrome, .chromium, .edge, .brave, .safari, .firefox
        ]
    }

    public struct CompatibilityGuide: Sendable {
        public let browser: BrowserInfo
        public let title: String
        public let steps: [String]
        public let notes: [String]
    }

    private let windowSize = 60
    private var recentBlackPercentages: [Double] = []

    public init() {}

    public func processFrame(_ analysis: FrameAnalysis, consecutiveProtectedFrames consecutive: Int) {
        recentBlackPercentages.append(analysis.blackPixelPercentage)
        if recentBlackPercentages.count > windowSize {
            recentBlackPercentages.removeFirst()
        }
        averageBlackPercentage = recentBlackPercentages.reduce(0, +) / Double(recentBlackPercentages.count)
        consecutiveProtectedFrames = consecutive
        if consecutive >= ProtectedContentPolicy.confirmationFrameCount {
            checkForegroundBrowser()
        }
        updateStatus()
    }

    public func reset() {
        status = .normal
        protectedContentSuspected = false
        averageBlackPercentage = 0
        consecutiveProtectedFrames = 0
        recentBlackPercentages = []
    }

    public func makeBanner(showsGuide: Bool) -> ProtectedContentBanner? {
        guard showsGuide else { return nil }
        return Self.banner(for: detectedBrowser)
    }

    public static func banner(for browser: BrowserInfo?) -> ProtectedContentBanner {
        if let browser, browser == .safari {
            return ProtectedContentBanner(
                message: "Safari uses FairPlay DRM. There is no capture workaround. Play in Chrome, Edge, or Brave with hardware acceleration off (720p/1080p cap).",
                steps: [],
                notes: [
                    "Native streaming apps (Apple TV, Disney+, Netflix app) also cannot be captured.",
                    "The strip keeps its last color instead of going black."
                ]
            )
        }

        if let browser, browser.supportsHWAccelToggle {
            let guide = compatibilityGuide(for: browser)
            return ProtectedContentBanner(
                message: "\(browser.name) is sending a black frame for this video while hardware acceleration is on. The strip will keep its last color until the picture is capturable.",
                steps: guide.steps,
                notes: guide.notes,
                settingsURL: hardwareAccelerationSettingsURL(for: browser),
                openSettingsTitle: "Open \(browser.name) System settings"
            )
        }

        return ProtectedContentBanner(
            message: "This video is protected. Screen capture gets a black rectangle, so the strip holds its last color.",
            steps: [
                "In Chrome, Edge, or Brave: Settings → System",
                "Turn OFF “Use hardware acceleration when available”",
                "Relaunch the browser",
                "Playback is capped at 720p or 1080p"
            ],
            notes: [
                "Hardware-acceleration-on Chrome, Edge, or Brave will stay black.",
                "Safari and native streaming apps use FairPlay — there is no capture workaround."
            ]
        )
    }

    private func updateStatus() {
        if ProtectedContentPolicy.shouldShowGuide(consecutiveProtectedFrames: consecutiveProtectedFrames) {
            protectedContentSuspected = true
            if let browser = detectedBrowser, browser.supportsHWAccelToggle {
                status = .browserCompatibilityMode
            } else {
                status = .confirmedProtection
            }
        } else {
            protectedContentSuspected = false
            status = .normal
        }
    }

    // nonisolated(unsafe): Timer is only created/invalidated on the main actor;
    // deinit must be able to invalidate it under Swift 6 isolation rules.
    nonisolated(unsafe) private var browserMonitorTimer: Timer?

    deinit {
        browserMonitorTimer?.invalidate()
    }

    public func startBrowserMonitoring() {
        guard !isBrowserMonitoring else { return }
        isBrowserMonitoring = true
        checkForegroundBrowser()
        browserMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForegroundBrowser()
            }
        }
    }

    public func stopBrowserMonitoring() {
        browserMonitorTimer?.invalidate()
        browserMonitorTimer = nil
        isBrowserMonitoring = false
        detectedBrowser = nil
    }

    private func checkForegroundBrowser() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            detectedBrowser = nil
            return
        }
        let bundleID = frontApp.bundleIdentifier ?? ""
        detectedBrowser = BrowserInfo.allBrowsers.first { $0.bundleID == bundleID }
    }

    public func getCompatibilityGuide() -> CompatibilityGuide? {
        guard let browser = detectedBrowser else { return nil }
        return Self.compatibilityGuide(for: browser)
    }

    public static func compatibilityGuide(for browser: BrowserInfo) -> CompatibilityGuide {
        switch browser.bundleID {
        case BrowserInfo.chrome.bundleID, BrowserInfo.chromium.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Turn off hardware acceleration in \(browser.name)",
                steps: [
                    "Open \(browser.name) Settings → System (chrome://settings/system)",
                    "Turn OFF “Use hardware acceleration when available”",
                    "Relaunch \(browser.name)",
                    "Playback is capped at 720p or 1080p"
                ],
                notes: [
                    "Hardware-acceleration-on Chrome, Edge, or Brave will stay black.",
                    "Safari and native streaming apps use FairPlay — there is no capture workaround."
                ]
            )

        case BrowserInfo.edge.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Turn off hardware acceleration in Edge",
                steps: [
                    "Open Edge Settings → System and performance (edge://settings/system)",
                    "Turn OFF “Use hardware acceleration when available”",
                    "Restart Edge",
                    "Playback is capped at 720p or 1080p"
                ],
                notes: [
                    "Hardware-acceleration-on Chrome, Edge, or Brave will stay black.",
                    "Safari and native streaming apps use FairPlay — there is no capture workaround."
                ]
            )

        case BrowserInfo.brave.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Turn off hardware acceleration in Brave",
                steps: [
                    "Open Brave Settings → System (brave://settings/system)",
                    "Turn OFF “Use hardware acceleration when available”",
                    "Relaunch Brave",
                    "Playback is capped at 720p or 1080p"
                ],
                notes: [
                    "Hardware-acceleration-on Chrome, Edge, or Brave will stay black.",
                    "Safari and native streaming apps use FairPlay — there is no capture workaround."
                ]
            )

        case BrowserInfo.firefox.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Turn off hardware video decoding in Firefox",
                steps: [
                    "Type about:config in the address bar and press Enter",
                    "Search for media.hardware-video-decoding.enabled",
                    "Set it to false and restart Firefox",
                    "Playback may cap at 720p or 1080p"
                ],
                notes: [
                    "Safari and native streaming apps use FairPlay — there is no capture workaround."
                ]
            )

        default:
            return CompatibilityGuide(
                browser: browser,
                title: "Protected video cannot be captured in \(browser.name)",
                steps: [],
                notes: [
                    "Safari and native streaming apps use FairPlay — there is no capture workaround.",
                    "Chrome, Edge, or Brave can work if you turn off hardware acceleration (720p/1080p cap)."
                ]
            )
        }
    }

    public static func hardwareAccelerationSettingsURL(for browser: BrowserInfo) -> URL? {
        switch browser.bundleID {
        case BrowserInfo.chrome.bundleID:
            return URL(string: "googlechrome://settings/system")
        case BrowserInfo.chromium.bundleID:
            return URL(string: "chromium://settings/system")
        case BrowserInfo.edge.bundleID:
            return URL(string: "microsoft-edge://settings/system")
        case BrowserInfo.brave.bundleID:
            return URL(string: "brave://settings/system")
        default:
            return nil
        }
    }

    public func getUserMessage() -> String? {
        makeBanner(showsGuide: ProtectedContentPolicy.shouldShowGuide(
            consecutiveProtectedFrames: consecutiveProtectedFrames
        ))?.message
    }

    public struct TestResult: Sendable {
        public let content: String
        public let browser: String
        public let hardwareAcceleration: Bool
        public let displayType: String
        public let capturable: Bool
        public let notes: String
    }

    public static var documentedTestResults: [TestResult] {
        [
            TestResult(content: "Desktop", browser: "N/A", hardwareAcceleration: false, displayType: "Any", capturable: true, notes: "Standard desktop content always works"),
            TestResult(content: "YouTube", browser: "Chrome", hardwareAcceleration: true, displayType: "Any", capturable: true, notes: "YouTube doesn't use Widevine for most content"),
            TestResult(content: "Netflix", browser: "Chrome", hardwareAcceleration: true, displayType: "Any", capturable: false, notes: "Widevine L1 hardware DRM - black frame"),
            TestResult(content: "Netflix", browser: "Chrome", hardwareAcceleration: false, displayType: "Any", capturable: true, notes: "Widevine L3 software - capturable at 720p max"),
            TestResult(content: "Netflix", browser: "Safari", hardwareAcceleration: false, displayType: "Any", capturable: false, notes: "FairPlay DRM - no workaround"),
            TestResult(content: "Prime Video", browser: "Chrome", hardwareAcceleration: true, displayType: "Any", capturable: false, notes: "Widevine L1 hardware DRM - black frame"),
            TestResult(content: "Prime Video", browser: "Chrome", hardwareAcceleration: false, displayType: "Any", capturable: true, notes: "Widevine L3 software - capturable"),
            TestResult(content: "Disney+", browser: "Chrome", hardwareAcceleration: true, displayType: "Any", capturable: false, notes: "Widevine L1 hardware DRM - black frame"),
            TestResult(content: "Disney+", browser: "Chrome", hardwareAcceleration: false, displayType: "Any", capturable: true, notes: "Widevine L3 software - capturable"),
        ]
    }
}

#endif
