import XCTest
@testable import LightStarCore

final class BrowserHardwareAccelerationTests: XCTestCase {

    func testDisableOnlyWhileOnAndScreenSyncWithProtectionOrSession() {
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: true,
            alreadyAppliedThisSession: false, protectedContentDetected: false,
            playbackIsNetflixOrPrime: false
        ), "VS Code / YouTube Screen sync must not quit Chrome")
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: true,
            alreadyAppliedThisSession: false, protectedContentDetected: true,
            playbackIsNetflixOrPrime: false
        ), "Disney+ and other black frames must not quit Chrome")
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: true,
            alreadyAppliedThisSession: false, protectedContentDetected: true,
            playbackIsNetflixOrPrime: true
        ))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: true,
            alreadyAppliedThisSession: true, protectedContentDetected: false,
            playbackIsNetflixOrPrime: false
        ), "stay off for the rest of the Screen session so we do not relaunch-loop")
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: false, isSyncingVideo: true,
            alreadyAppliedThisSession: true, protectedContentDetected: true,
            playbackIsNetflixOrPrime: true
        ), "power off restores")
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: false,
            alreadyAppliedThisSession: true, protectedContentDetected: true,
            playbackIsNetflixOrPrime: true
        ), "leaving Screen restores")
    }

    func testChromeRestartOnlyForNetflixAndPrime() {
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.netflix.com/watch/123", title: "Show"
        ))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.primevideo.com/detail/abc", title: nil
        ))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.amazon.in/gp/video/storefront", title: nil
        ))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: nil, title: "Prime Video - Google Chrome"
        ))
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.youtube.com/watch?v=abc", title: "YouTube"
        ))
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.disneyplus.com/play/abc", title: "Disney+"
        ))
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(
            url: "https://www.amazon.com/dp/B00TEST", title: "Amazon.com"
        ))
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.isNetflixOrPrime(url: nil, title: nil))
    }

    func testDisableRelaunchIsOneShot() {
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.shouldPerformDisableRelaunch(
            wantDisabled: true, alreadyAppliedThisSession: false, disableInFlight: false
        ))
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldPerformDisableRelaunch(
            wantDisabled: true, alreadyAppliedThisSession: true, disableInFlight: false
        ), "must not quit Chrome again after the first relaunch")
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldPerformDisableRelaunch(
            wantDisabled: true, alreadyAppliedThisSession: false, disableInFlight: true
        ), "must not cancel and restart a relaunch already in flight")
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.shouldPerformDisableRelaunch(
            wantDisabled: false, alreadyAppliedThisSession: false, disableInFlight: false
        ))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.shouldDisable(
            isOn: true, isSyncingVideo: true,
            alreadyAppliedThisSession: true, protectedContentDetected: false,
            playbackIsNetflixOrPrime: false
        ), "latch keeps wantDisabled true while Chrome is restarting and frames are not black")
    }

    func testPrefersDetectedChromiumThenRunningChrome() {
        XCTAssertEqual(
            BrowserHardwareAccelerationPolicy.preferredBundleID(
                detectedBundleID: "com.google.Chrome",
                runningBundleIDs: ["com.brave.Browser"]
            ),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            BrowserHardwareAccelerationPolicy.preferredBundleID(
                detectedBundleID: "com.apple.Safari",
                runningBundleIDs: ["com.brave.Browser", "com.google.Chrome"]
            ),
            "com.google.Chrome"
        )
        XCTAssertNil(
            BrowserHardwareAccelerationPolicy.preferredBundleID(
                detectedBundleID: "com.apple.Safari",
                runningBundleIDs: ["com.apple.Safari"]
            )
        )
        XCTAssertFalse(BrowserHardwareAccelerationPolicy.canAutoToggle(bundleID: "com.apple.Safari"))
        XCTAssertTrue(BrowserHardwareAccelerationPolicy.canAutoToggle(bundleID: "com.brave.Browser"))
    }

    func testLocalStateNestedAndLegacyKeys() throws {
        let nested: [String: Any] = ["hardware_acceleration_mode": ["enabled": true]]
        XCTAssertTrue(ChromiumLocalState.hardwareAccelerationEnabled(nested))
        let off = ChromiumLocalState.settingHardwareAcceleration(nested, enabled: false)
        XCTAssertFalse(ChromiumLocalState.hardwareAccelerationEnabled(off))
        let nestedMode = off["hardware_acceleration_mode"] as? [String: Any]
        XCTAssertEqual(nestedMode?["enabled"] as? Bool, false)

        let legacy: [String: Any] = ["hardware_acceleration_mode_enabled": false]
        XCTAssertFalse(ChromiumLocalState.hardwareAccelerationEnabled(legacy))
        XCTAssertTrue(ChromiumLocalState.hardwareAccelerationEnabled([:]))

        let data = try ChromiumLocalState.serialize(off)
        let roundTrip = try ChromiumLocalState.parse(data)
        XCTAssertFalse(ChromiumLocalState.hardwareAccelerationEnabled(roundTrip))
    }

    func testLocalStateURLForChrome() {
        let root = URL(fileURLWithPath: "/tmp/as")
        XCTAssertEqual(
            BrowserHardwareAccelerationPolicy.localStateURL(
                applicationSupport: root, bundleID: "com.google.Chrome"
            )?.path,
            "/tmp/as/Google/Chrome/Local State"
        )
        XCTAssertNil(
            BrowserHardwareAccelerationPolicy.localStateURL(
                applicationSupport: root, bundleID: "com.apple.Safari"
            )
        )
    }

    func testPatchPreservesOtherLocalStateKeys() {
        let compact = "{\"foo\":1,\"hardware_acceleration_mode\":{\"enabled\":true},\"bar\":\"keep\"}"
        let patched = ChromiumLocalState.patchingHardwareAcceleration(compact, enabled: false)
        XCTAssertEqual(
            patched,
            "{\"foo\":1,\"hardware_acceleration_mode\":{\"enabled\":false},\"bar\":\"keep\"}"
        )
        let pretty = """
        {
          "profile": { "last_used": "Default" },
          "hardware_acceleration_mode": {
            "enabled": false
          }
        }
        """
        let on = ChromiumLocalState.patchingHardwareAcceleration(pretty, enabled: true)
        XCTAssertTrue(on?.contains("\"last_used\": \"Default\"") == true)
        XCTAssertTrue(on?.contains("\"enabled\": true") == true)
        XCTAssertFalse(on?.contains("\"enabled\": false") == true)
        XCTAssertEqual(
            BrowserHardwareAccelerationPolicy.restoreSessionLaunchArguments,
            ["--restore-last-session", "--disable-session-crashed-bubble"]
        )
    }
}
