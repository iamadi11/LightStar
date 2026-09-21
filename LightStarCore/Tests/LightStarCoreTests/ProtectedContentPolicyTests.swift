import XCTest
@testable import LightStarCore

final class ProtectedContentPolicyTests: XCTestCase {

    private func frame(
        hue: Double = 0,
        sat: Double = 0,
        bri: Double = 0,
        black: Double,
        rect: Bool
    ) -> FrameAnalysis {
        FrameAnalysis(
            dominantHue: hue,
            dominantSaturation: sat,
            dominantBrightness: bri,
            blackPixelPercentage: black,
            hasRectangularBlackRegion: rect
        )
    }

    func testProtectedFrameDoesNotWriteNearBlack() {
        let drm = frame(hue: 0.5, sat: 0.3, bri: 0.2, black: 0.75, rect: true)
        let allBlack = frame(bri: 0, black: 1.0, rect: true)
        XCTAssertEqual(ProtectedContentPolicy.screenColorWrite(for: drm), .holdLastColor)
        XCTAssertEqual(ProtectedContentPolicy.screenColorWrite(for: allBlack), .holdLastColor)
        if case .write(let hsv) = ProtectedContentPolicy.screenColorWrite(for: drm) {
            XCTFail("DRM frame must not write hue=\(hsv.hue) brightness=\(hsv.brightness)")
        }
    }

    func testHoldLastColorUntilNonBlackFrame() {
        var tracker = ProtectedContentTracker()
        let blue = frame(hue: 0.667, sat: 1, bri: 1, black: 0, rect: false)
        guard case .write(let good) = tracker.ingest(blue) else {
            return XCTFail("first capturable frame must write")
        }
        XCTAssertEqual(good.hue, 0.667, accuracy: 0.01)
        XCTAssertEqual(good.brightness, 1.0, accuracy: 0.01)

        let drm = frame(hue: 0.5, sat: 0.3, bri: 0.2, black: 0.75, rect: true)
        XCTAssertEqual(tracker.ingest(drm), .holdLastColor)
        XCTAssertEqual(tracker.lastGood?.hue ?? -1, 0.667, accuracy: 0.01)
        XCTAssertEqual(tracker.lastGood?.brightness ?? -1, 1.0, accuracy: 0.01)

        XCTAssertEqual(tracker.ingest(frame(bri: 0, black: 1, rect: true)), .holdLastColor)
        XCTAssertEqual(tracker.lastGood?.hue ?? -1, 0.667, accuracy: 0.01)

        let red = frame(hue: 0, sat: 1, bri: 1, black: 0, rect: false)
        guard case .write(let next) = tracker.ingest(red) else {
            return XCTFail("non-black frame must resume writes")
        }
        XCTAssertEqual(next.hue, 0.0, accuracy: 0.01)
        XCTAssertEqual(tracker.consecutiveProtectedFrames, 0)
    }

    func testGuideAppearsOnlyAfterNConsecutiveProtectedFrames() {
        var tracker = ProtectedContentTracker()
        let drm = frame(hue: 0.5, sat: 0.3, bri: 0.2, black: 0.75, rect: true)
        let n = ProtectedContentPolicy.confirmationFrameCount
        for _ in 0..<(n - 1) {
            XCTAssertEqual(tracker.ingest(drm), .holdLastColor)
            XCTAssertFalse(tracker.showsGuide)
        }
        XCTAssertEqual(tracker.ingest(drm), .holdLastColor)
        XCTAssertTrue(tracker.showsGuide)

        _ = tracker.ingest(frame(hue: 0.6, sat: 0.4, bri: 0.7, black: 0.1, rect: false))
        XCTAssertFalse(tracker.showsGuide)
        XCTAssertEqual(tracker.consecutiveProtectedFrames, 0)
    }

    func testDarkCodeEditorDoesNotTripDRM() {
        let vsCode = frame(hue: 0.55, sat: 0.35, bri: 0.42, black: 0.48, rect: false)
        XCTAssertFalse(ProtectedContentPolicy.isProtectedFrame(vsCode))
        guard case .write(let hsv) = ProtectedContentPolicy.screenColorWrite(for: vsCode) else {
            return XCTFail("dark UI must still drive hue")
        }
        XCTAssertEqual(hsv.hue, 0.55, accuracy: 0.01)
        XCTAssertGreaterThan(hsv.brightness, 0.2)

        var tracker = ProtectedContentTracker()
        for _ in 0..<ProtectedContentPolicy.confirmationFrameCount {
            _ = tracker.ingest(vsCode)
        }
        XCTAssertFalse(tracker.showsGuide)

        let darkNoRect = frame(hue: 0.58, sat: 0.4, bri: 0.35, black: 0.8, rect: false)
        XCTAssertFalse(ProtectedContentPolicy.isProtectedFrame(darkNoRect))
        XCTAssertFalse(ProtectedContentPolicy.shouldShowGuide(consecutiveProtectedFrames: 0))
    }

    func testHoldLastWhenFirstFramesAreProtected() {
        var tracker = ProtectedContentTracker()
        XCTAssertNil(tracker.lastGood)
        XCTAssertEqual(
            tracker.ingest(frame(bri: 0, black: 1, rect: true)),
            .holdLastColor
        )
    }
}

#if os(macOS)
@MainActor
final class CaptureDiagnosticsGuideTests: XCTestCase {

    func testBrowserMonitorDoesNotStartOnInit() {
        let diagnostics = CaptureDiagnostics()
        XCTAssertFalse(diagnostics.isBrowserMonitoring)
        diagnostics.startBrowserMonitoring()
        XCTAssertTrue(diagnostics.isBrowserMonitoring)
        diagnostics.stopBrowserMonitoring()
        XCTAssertFalse(diagnostics.isBrowserMonitoring)
    }

    func testChromeGuideHasHonestHardwareAccelerationCopy() {
        let banner = CaptureDiagnostics.banner(for: .chrome)
        XCTAssertTrue(banner.message.contains("hardware acceleration"))
        XCTAssertTrue(banner.steps.contains(where: { $0.localizedCaseInsensitiveContains("hardware acceleration") }))
        XCTAssertTrue(banner.steps.contains(where: { $0.contains("720p") || $0.contains("1080p") }))
        XCTAssertTrue(banner.notes.contains(where: { $0.localizedCaseInsensitiveContains("Safari") && $0.localizedCaseInsensitiveContains("no capture workaround") }))
        XCTAssertEqual(banner.settingsURL, URL(string: "googlechrome://settings/system"))
        XCTAssertEqual(banner.openSettingsTitle, "Open Google Chrome System settings")
    }

    func testEdgeAndBraveGuidesMatchChromePolicy() {
        for browser in [CaptureDiagnostics.BrowserInfo.edge, .brave] {
            let banner = CaptureDiagnostics.banner(for: browser)
            XCTAssertTrue(banner.message.contains("hardware acceleration"), browser.name)
            XCTAssertTrue(banner.steps.contains(where: { $0.contains("720p") || $0.contains("1080p") }), browser.name)
            XCTAssertNotNil(banner.settingsURL, browser.name)
        }
    }

    func testSafariGuideSaysNoWorkaround() {
        let banner = CaptureDiagnostics.banner(for: .safari)
        XCTAssertTrue(banner.message.localizedCaseInsensitiveContains("FairPlay"))
        XCTAssertTrue(banner.message.localizedCaseInsensitiveContains("no capture workaround"))
        XCTAssertTrue(banner.steps.isEmpty)
        XCTAssertNil(banner.settingsURL)
    }

    func testUnknownFrontmostAppStillNamesChromiumPathAndSafariLimit() {
        let banner = CaptureDiagnostics.banner(for: nil)
        XCTAssertTrue(banner.steps.contains(where: { $0.localizedCaseInsensitiveContains("hardware acceleration") }))
        XCTAssertTrue(banner.notes.contains(where: { $0.localizedCaseInsensitiveContains("Safari") && $0.localizedCaseInsensitiveContains("no capture workaround") }))
        XCTAssertTrue(banner.notes.contains(where: { $0.localizedCaseInsensitiveContains("Hardware-acceleration-on") }))
    }

    func testSamplerDoesNotEmitColorWritesForProtectedFrames() {
        let sampler = ScreenColorSampler()
        var writes: [(Double, Double, Double)] = []
        var banners: [ProtectedContentBanner?] = []
        sampler.onColor = { h, s, v in writes.append((h, s, v)) }
        sampler.onDiagnosticsUpdate = { banners.append($0) }

        sampler.handleFrame(FrameAnalysis(
            dominantHue: 0.667, dominantSaturation: 1, dominantBrightness: 1,
            blackPixelPercentage: 0, hasRectangularBlackRegion: false
        ))
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].0, 0.667, accuracy: 0.01)

        let drm = FrameAnalysis(
            dominantHue: 0.5, dominantSaturation: 0.3, dominantBrightness: 0.2,
            blackPixelPercentage: 0.75, hasRectangularBlackRegion: true
        )
        sampler.handleFrame(drm)
        XCTAssertEqual(writes.count, 1, "protected frame must not enqueue a near-black color write")
        XCTAssertNil(sampler.protectedContentBanner)

        for _ in 0..<ProtectedContentPolicy.confirmationFrameCount {
            sampler.handleFrame(drm)
        }
        XCTAssertEqual(writes.count, 1)
        XCTAssertNotNil(sampler.protectedContentBanner)
        XCTAssertTrue(sampler.protectedContentDetected)

        sampler.handleFrame(FrameAnalysis(
            dominantHue: 0.55, dominantSaturation: 0.35, dominantBrightness: 0.42,
            blackPixelPercentage: 0.48, hasRectangularBlackRegion: false
        ))
        XCTAssertEqual(writes.count, 2)
        XCTAssertNil(sampler.protectedContentBanner)
        XCTAssertFalse(sampler.protectedContentDetected)
    }
}
#endif
