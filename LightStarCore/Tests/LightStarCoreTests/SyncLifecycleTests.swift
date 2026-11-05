import XCTest
@testable import LightStarCore

/// The sync lifecycle around the lightbar, driven without Bluetooth or capture.
@MainActor
final class SyncLifecycleTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [LightOutputTarget.defaultsKey, LightOutputTarget.allLightsDefaultsKey, "lastPowerState"]

    override func setUp() async throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.set(saved[key] ?? nil, forKey: key) }
    }

    private func syncingLightbar() -> LightBLEManager {
        let ble = LightBLEManager(bluetooth: false)
        ble.onLampZones = { _, _ in }
        ble.outputTarget = .lightbar
        ble.isOn = true
        ble.syncMode = .video
        return ble
    }

    func testLightbarGetsFramesOnceScreenSyncIsSetUp() {
        let ble = syncingLightbar()
        ble.setupScreenCallback()
        XCTAssertTrue(ble.lampPipe.isActive)
    }

    /// A display switch restarts capture with the same mode: teardown, then
    /// setup, with nothing observed changing. The pipe stayed off and the
    /// lightbar showed the strip's single colour (2026-11-06).
    func testLightbarGetsFramesAgainAfterADisplayRestart() async {
        let ble = syncingLightbar()
        ble.setupScreenCallback()
        await ble.teardownSync()
        XCTAssertFalse(ble.lampPipe.isActive, "off while capture restarts, so no stale frame lands")
        ble.setupScreenCallback()
        XCTAssertTrue(ble.lampPipe.isActive)
    }

    func testNoLightbarFramesWhenTheLightbarIsntChosen() {
        let ble = syncingLightbar()
        ble.outputTarget = .strip
        ble.setupScreenCallback()
        XCTAssertFalse(ble.lampPipe.isActive)
    }
}
