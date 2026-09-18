#if os(macOS)
import Foundation
import AppKit

/// Diagnostics and guidance for screen capture issues, particularly DRM-protected content.
@MainActor
public final class CaptureDiagnostics: ObservableObject {
    
    // MARK: - Published State
    
    /// Current diagnostic status
    @Published public private(set) var status: DiagnosticStatus = .normal
    
    /// Whether protected content is currently suspected
    @Published public private(set) var protectedContentSuspected = false
    
    /// Running average of black pixel percentage
    @Published public private(set) var averageBlackPercentage: Double = 0
    
    /// Number of consecutive frames with suspected protection
    @Published public private(set) var consecutiveProtectedFrames = 0
    
    /// Detected browser in foreground (if any)
    @Published public private(set) var detectedBrowser: BrowserInfo?
    
    // MARK: - Types
    
    public enum DiagnosticStatus: String {
        case normal = "Normal"
        case suspectedProtection = "Suspected Protected Content"
        case confirmedProtection = "Protected Content Detected"
        case browserCompatibilityMode = "Browser Compatibility Mode Available"
    }
    
    public struct BrowserInfo: Equatable {
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
    
    public struct CompatibilityGuide {
        public let browser: BrowserInfo
        public let title: String
        public let steps: [String]
        public let notes: [String]
    }
    
    // MARK: - Configuration
    
    /// Threshold for black pixel percentage to suspect protected content
    public var blackPixelThreshold: Double = 0.6
    
    /// Number of consecutive frames before confirming protection
    public var confirmationFrameCount = 30
    
    /// Window size for averaging black percentage
    private let windowSize = 60
    private var recentBlackPercentages: [Double] = []
    
    // MARK: - Initialization
    
    public init() {
        startBrowserMonitoring()
    }
    
    // MARK: - Frame Analysis
    
    /// Process a frame analysis result to update diagnostics
    public func processFrame(_ analysis: FrameAnalysis) {
        // Update rolling average
        recentBlackPercentages.append(analysis.blackPixelPercentage)
        if recentBlackPercentages.count > windowSize {
            recentBlackPercentages.removeFirst()
        }
        averageBlackPercentage = recentBlackPercentages.reduce(0, +) / Double(recentBlackPercentages.count)
        
        // Check for protected content
        let isBlackFrame = analysis.suspectedProtectedContent
        
        if isBlackFrame {
            consecutiveProtectedFrames += 1
        } else {
            consecutiveProtectedFrames = 0
        }
        
        // Update status
        updateStatus()
    }
    
    private func updateStatus() {
        let previousStatus = status
        
        if consecutiveProtectedFrames >= confirmationFrameCount {
            protectedContentSuspected = true
            
            if let browser = detectedBrowser, browser.supportsHWAccelToggle {
                status = .browserCompatibilityMode
            } else {
                status = .confirmedProtection
            }
        } else if consecutiveProtectedFrames > 5 {
            protectedContentSuspected = true
            status = .suspectedProtection
        } else {
            protectedContentSuspected = false
            status = .normal
        }
        
        // Log status changes
        if status != previousStatus {
            print("[CaptureDiagnostics] Status changed: \(previousStatus.rawValue) → \(status.rawValue)")
        }
    }
    
    // MARK: - Browser Monitoring
    
    private var browserMonitorTimer: Timer?
    
    private func startBrowserMonitoring() {
        browserMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForegroundBrowser()
            }
        }
    }
    
    private func checkForegroundBrowser() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            detectedBrowser = nil
            return
        }
        
        let bundleID = frontApp.bundleIdentifier ?? ""
        detectedBrowser = BrowserInfo.allBrowsers.first { $0.bundleID == bundleID }
    }
    
    // MARK: - Compatibility Guides
    
    /// Get compatibility guide for the detected browser
    public func getCompatibilityGuide() -> CompatibilityGuide? {
        guard let browser = detectedBrowser, browser.supportsHWAccelToggle else {
            return nil
        }
        
        switch browser.bundleID {
        case BrowserInfo.chrome.bundleID, BrowserInfo.chromium.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Enable LightStar Compatibility Mode in Chrome",
                steps: [
                    "1. Open Chrome Settings (⌘,)",
                    "2. Click 'System' in the left sidebar",
                    "3. Toggle OFF 'Use hardware acceleration when available'",
                    "4. Click 'Relaunch' to restart Chrome",
                    "5. Return to your streaming content"
                ],
                notes: [
                    "This forces Widevine to use software decryption (L3)",
                    "Video quality may be limited to 720p on some services",
                    "You can re-enable hardware acceleration when not using LightStar"
                ]
            )
            
        case BrowserInfo.edge.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Enable LightStar Compatibility Mode in Edge",
                steps: [
                    "1. Open Edge Settings (⌘,)",
                    "2. Click 'System and performance' in the left sidebar",
                    "3. Toggle OFF 'Use hardware acceleration when available'",
                    "4. Click 'Restart' to restart Edge",
                    "5. Return to your streaming content"
                ],
                notes: [
                    "Similar to Chrome, this uses software video decoding",
                    "You can re-enable hardware acceleration when not using LightStar"
                ]
            )
            
        case BrowserInfo.brave.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Enable LightStar Compatibility Mode in Brave",
                steps: [
                    "1. Open Brave Settings (⌘,)",
                    "2. Click 'System' in the left sidebar",
                    "3. Toggle OFF 'Use hardware acceleration when available'",
                    "4. Click 'Relaunch' to restart Brave",
                    "5. Return to your streaming content"
                ],
                notes: [
                    "Brave uses the same Chromium engine as Chrome",
                    "You can re-enable hardware acceleration when not using LightStar"
                ]
            )
            
        case BrowserInfo.firefox.bundleID:
            return CompatibilityGuide(
                browser: browser,
                title: "Enable LightStar Compatibility Mode in Firefox",
                steps: [
                    "1. Type 'about:config' in the address bar and press Enter",
                    "2. Accept the warning if shown",
                    "3. Search for 'media.hardware-video-decoding.enabled'",
                    "4. Double-click to set it to 'false'",
                    "5. Restart Firefox",
                    "6. Return to your streaming content"
                ],
                notes: [
                    "Firefox uses a different DRM system but similar principles apply",
                    "This may affect video playback performance"
                ]
            )
            
        default:
            return nil
        }
    }
    
    /// Get a user-friendly message for the current status
    public func getUserMessage() -> String? {
        switch status {
        case .normal:
            return nil
            
        case .suspectedProtection:
            return "Detecting possible protected content..."
            
        case .confirmedProtection:
            if let browser = detectedBrowser {
                if browser == BrowserInfo.safari {
                    return "Protected content detected in Safari. Safari's FairPlay DRM cannot be captured. Try using Chrome with hardware acceleration disabled."
                }
                return "Protected content detected. The streaming video is using DRM protection."
            }
            return "Protected content detected. Screen capture is blocked for this content."
            
        case .browserCompatibilityMode:
            guard let browser = detectedBrowser else {
                return "Protected content detected."
            }
            return "Protected content detected in \(browser.name). You can enable compatibility mode by disabling hardware acceleration."
        }
    }
    
    // MARK: - Test Matrix Results
    
    /// Known test results for different content/browser combinations
    public struct TestResult {
        public let content: String
        public let browser: String
        public let hardwareAcceleration: Bool
        public let displayType: String
        public let capturable: Bool
        public let notes: String
    }
    
    /// Get documented test results from research
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
