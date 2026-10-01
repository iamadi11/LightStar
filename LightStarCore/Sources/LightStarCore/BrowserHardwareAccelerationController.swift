#if os(macOS)
import AppKit
import Foundation
import os

private let captureLog = Logger(subsystem: "com.adityaraj.LightStar", category: "capture")

private enum BrowserHWAccelStore {
    static let weChanged = "browserHWAccel.weChanged"
    static let previousEnabled = "browserHWAccel.previousEnabled"
    static let bundleID = "browserHWAccel.bundleID"
}

/// Quits a Chromium browser, writes Local State, relaunches. No-op under XCTest.
@MainActor
public final class BrowserHardwareAccelerationController {
    public private(set) var appliedThisSession = false
    public private(set) var statusMessage: String? {
        didSet { onStatusChange?(statusMessage) }
    }
    public var onStatusChange: ((String?) -> Void)?
    public var processControlEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    private var inFlight: Task<Void, Never>?
    private var siteProbeAt: TimeInterval = -.greatestFiniteMagnitude
    private var siteProbeBundleID: String?

    public init() {}

    /// Bundle id of a running Chromium browser whose front tab is Netflix or
    /// Prime Video. Nil for every other site, so we do not quit the browser.
    public func netflixOrPrimeBundleID() -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - siteProbeAt < 5 { return siteProbeBundleID }
        siteProbeAt = now
        siteProbeBundleID = probeNetflixOrPrimeBundleID()
        return siteProbeBundleID
    }

    public func reconcile(
        wantDisabled: Bool,
        detectedBundleID: String?
    ) {
        if wantDisabled {
            guard BrowserHardwareAccelerationPolicy.shouldPerformDisableRelaunch(
                wantDisabled: true,
                alreadyAppliedThisSession: appliedThisSession,
                disableInFlight: inFlight != nil
            ) else { return }
            appliedThisSession = true
            inFlight = Task { @MainActor in
                await self.apply(wantDisabled: true, detectedBundleID: detectedBundleID)
            }
            return
        }

        let needsRestore = appliedThisSession
            || UserDefaults.standard.bool(forKey: BrowserHWAccelStore.weChanged)
        inFlight?.cancel()
        inFlight = nil
        appliedThisSession = false
        guard needsRestore else { return }
        inFlight = Task { @MainActor in
            await self.apply(wantDisabled: false, detectedBundleID: detectedBundleID)
        }
    }

    public func restoreForTermination() async {
        inFlight?.cancel()
        inFlight = nil
        await apply(wantDisabled: false, detectedBundleID: UserDefaults.standard.string(forKey: BrowserHWAccelStore.bundleID))
    }

    private func apply(wantDisabled: Bool, detectedBundleID: String?) async {
        guard processControlEnabled else { return }
        if !wantDisabled {
            await restoreIfNeeded()
            appliedThisSession = false
            if statusMessage?.contains("Restarting") == true { statusMessage = nil }
            return
        }

        if detectedBundleID == CaptureDiagnostics.BrowserInfo.safari.bundleID {
            statusMessage = "Safari uses FairPlay. There is no hardware-acceleration toggle. Play in Chrome, Edge, or Brave."
            return
        }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let bundleID = BrowserHardwareAccelerationPolicy.preferredBundleID(
            detectedBundleID: detectedBundleID,
            runningBundleIDs: Array(running)
        ) else {
            return
        }

        let name = displayName(bundleID)
        statusMessage = "Restarting \(name) with hardware acceleration off so Screen sync can see this video. Press play again after it reopens. LightStar turns acceleration back on when you leave Screen or power off."
        do {
            try await setHardwareAcceleration(bundleID: bundleID, enabled: false, recordRestore: true)
            appliedThisSession = true
            statusMessage = "\(name) is running with hardware acceleration off (720p/1080p cap) until you leave Screen or turn the light off."
        } catch is CancellationError {
            return
        } catch {
            captureLog.error("Failed to set hardware acceleration off: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not restart \(name). Quit it yourself, then turn Screen sync on again."
        }
    }

    private func restoreIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: BrowserHWAccelStore.weChanged),
              let bundleID = defaults.string(forKey: BrowserHWAccelStore.bundleID) else {
            return
        }
        let previous = defaults.object(forKey: BrowserHWAccelStore.previousEnabled) as? Bool ?? true
        let name = displayName(bundleID)
        statusMessage = "Restoring \(name) hardware acceleration…"
        do {
            try await setHardwareAcceleration(bundleID: bundleID, enabled: previous, recordRestore: false)
            defaults.set(false, forKey: BrowserHWAccelStore.weChanged)
            defaults.removeObject(forKey: BrowserHWAccelStore.bundleID)
            statusMessage = nil
        } catch {
            captureLog.error("Failed to restore hardware acceleration: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not restore \(name) hardware acceleration. Turn it on in Settings → System."
        }
    }

    private func setHardwareAcceleration(bundleID: String, enabled: Bool, recordRestore: Bool) async throws {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let localState = BrowserHardwareAccelerationPolicy.localStateURL(
                applicationSupport: appSupport, bundleID: bundleID
              ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let bundleURL = apps.first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)

        if !apps.isEmpty {
            requestQuit(bundleID: bundleID)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if Task.isCancelled { throw CancellationError() }
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                throw CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let data = try Data(contentsOf: localState)
        let json = try ChromiumLocalState.parse(data)
        let previous = ChromiumLocalState.hardwareAccelerationEnabled(json)
        if recordRestore, previous != enabled {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: BrowserHWAccelStore.weChanged)
            defaults.set(previous, forKey: BrowserHWAccelStore.previousEnabled)
            defaults.set(bundleID, forKey: BrowserHWAccelStore.bundleID)
        }
        if previous != enabled {
            guard let text = String(data: data, encoding: .utf8),
                  let patched = ChromiumLocalState.patchingHardwareAcceleration(text, enabled: enabled),
                  let patchedData = patched.data(using: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let tmp = localState.appendingPathExtension("lightstar-tmp")
            try patchedData.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(localState, withItemAt: tmp)
        }

        if let bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.arguments = BrowserHardwareAccelerationPolicy.restoreSessionLaunchArguments
            try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
        }
    }

    private func probeNetflixOrPrimeBundleID() -> String? {
        if let match = onScreenChromiumTitleMatch() { return match }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        for bundleID in running where BrowserHardwareAccelerationPolicy.canAutoToggle(bundleID: bundleID) {
            guard let tab = activeTab(bundleID: bundleID) else { continue }
            if BrowserHardwareAccelerationPolicy.isNetflixOrPrime(url: tab.url, title: tab.title) {
                return bundleID
            }
        }
        return nil
    }

    private func onScreenChromiumTitleMatch() -> String? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let title = window[kCGWindowName as String] as? String, !title.isEmpty,
                  BrowserHardwareAccelerationPolicy.isNetflixOrPrime(url: nil, title: title),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  BrowserHardwareAccelerationPolicy.canAutoToggle(bundleID: bundleID) else {
                continue
            }
            return bundleID
        }
        return nil
    }

    private func activeTab(bundleID: String) -> (url: String, title: String)? {
        let source = """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            set tabURL to URL of active tab of front window
            set tabTitle to title of active tab of front window
            return tabURL & linefeed & tabTitle
        end tell
        """
        var appleError: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&appleError),
              appleError == nil else { return nil }
        let text = result.stringValue ?? ""
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let url = parts.first.map(String.init), !url.isEmpty else { return nil }
        let title = parts.count > 1 ? String(parts[1]) : ""
        return (url, title)
    }

    private func requestQuit(bundleID: String) {
        let source = "tell application id \"\(bundleID)\" to quit"
        var appleError: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&appleError)
        if appleError != nil {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                _ = app.terminate()
            }
        }
    }

    private func displayName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev":
            return "Google Chrome"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.brave.Browser": return "Brave"
        case "org.chromium.Chromium": return "Chromium"
        default: return "the browser"
        }
    }
}
#endif
