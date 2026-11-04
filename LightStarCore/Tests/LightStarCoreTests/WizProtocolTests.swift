import XCTest
@testable import LightStarCore

final class WizProtocolTests: XCTestCase {
    private func params(_ data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]
        XCTAssertEqual(object?["method"] as? String, "setPilot")
        return try XCTUnwrap(object?["params"] as? [String: Any])
    }

    func testSegmentsEncodeOffAsDarkStepAndKeepWidths() throws {
        let layout = WizSegmentLayout(widths: [1, 2, 0, 1], slot: 258)
        let red = WizRGB(r: 255, g: 0, b: 0)
        let steps = try XCTUnwrap(layout.steps([red, .off, red], dimming: 60))
        XCTAssertEqual(steps, [
            [0, 255, 0, 0, 0, 0, 0, 60, 0, 0, 0, 0, 1],
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2],
            // zero-width step dropped; missing colour is dark
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        ])
    }

    func testSegmentPayloadUsesCustomSlotAndMac() throws {
        let data = WizCommand.segments([WizRGB(r: 0, g: 0, b: 255)], layout: WizSegmentLayout(), dimming: 100, mac: "a8bb50aabbcc")
        let p = try params(data)
        XCTAssertEqual(p["sceneId"] as? Int, 258)
        XCTAssertEqual(p["mac"] as? String, "a8bb50aabbcc")
        XCTAssertEqual(p["state"] as? Bool, true)
        let elm = try XCTUnwrap(p["elm"] as? [String: Any])
        XCTAssertEqual(elm["modifier"] as? Int, 100)
        XCTAssertEqual(elm["support"] as? Int, 17)
        XCTAssertEqual((elm["steps"] as? [[Int]])?.count, 7)
    }

    func testLayoutRejectsMoreThanTwelveStepsAndBadText() {
        XCTAssertNil(WizSegmentLayout(widths: Array(repeating: 1, count: 13)).steps([], dimming: 100))
        XCTAssertNil(WizSegmentLayout.parse("1,x,1"))
        XCTAssertNil(WizSegmentLayout.parse("0,0"))
        XCTAssertEqual(WizSegmentLayout.parse(" 1, 2 ,1"), [1, 2, 1])
    }

    func testFlushHoldsColourWhileOffThenSendsOnce() throws {
        let layout = WizSegmentLayout()
        var desired = WizPilot()
        desired.apply(.power(false))
        desired.apply(.color(hue: 0, saturation: 1))
        desired.apply(.brightness(0.02))
        let off = WizFlush.messages(desired: desired, sent: WizPilot(), layout: layout, mac: nil)
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(try params(off[0].0)["state"] as? Bool, false)

        desired.apply(.power(true))
        let on = WizFlush.messages(desired: desired, sent: off[0].1, layout: layout, mac: nil)
        XCTAssertEqual(on.count, 2)
        let colour = try params(on[1].0)
        XCTAssertEqual(colour["r"] as? Int, 255)
        XCTAssertEqual(colour["dimming"] as? Int, 10, "WiZ dimming floor is 10")

        XCTAssertTrue(WizFlush.messages(desired: desired, sent: on[1].1, layout: layout, mac: nil).isEmpty)
    }

    func testBrightnessChangeResendsSegments() throws {
        let layout = WizSegmentLayout()
        var desired = WizPilot(power: true, mode: .segments([WizRGB(r: 0, g: 255, b: 0)]), dimming: 100)
        let first = WizFlush.messages(desired: desired, sent: WizPilot(power: true), layout: layout, mac: nil)
        XCTAssertEqual(first.count, 1)
        desired.apply(.brightness(0.5))
        let second = WizFlush.messages(desired: desired, sent: first[0].1, layout: layout, mac: nil)
        let steps = try XCTUnwrap((params(second.first?.0)["elm"] as? [String: Any])?["steps"] as? [[Int]])
        XCTAssertEqual(steps[0][7], 50)
    }

    func testEvenWidthsCoverTheWholeLamp() {
        XCTAssertEqual(WizSegmentLayout.even(segments: 18, steps: 7), [2, 3, 2, 3, 2, 3, 3])
        XCTAssertEqual(WizSegmentLayout.even(segments: 7, steps: 7), Array(repeating: 1, count: 7))
        XCTAssertEqual(WizSegmentLayout.even(segments: 4, steps: 7), [1, 1, 1, 1], "never a zero-width step")
        XCTAssertEqual(WizSegmentLayout.even(segments: 40, steps: 7).reduce(0, +), 40)
    }

    func testSegmentCountComesFromModelConfig() {
        // Reply from the Gradient Floor Lamp (trimmed): 36 LEDs, 18 addressable segments.
        let lamp = Data(#"{"method":"getModelConfig","env":"pro","result":{"headTotal":36,"swHead":18,"hasGradient":1,"lightType":6}}"#.utf8)
        XCTAssertEqual(WizDiscovery.segmentCount(lamp), 18)
        let bulb = Data(#"{"method":"getModelConfig","result":{"swHead":1,"hasGradient":0}}"#.utf8)
        XCTAssertNil(WizDiscovery.segmentCount(bulb))
    }

    func testStoredLayoutUsesDetectedCountUnlessWidthsSaved() {
        let defaults = UserDefaults.standard
        let keys = [WizSegmentLayout.countDefaultsKey, WizSegmentLayout.defaultsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        defaults.removeObject(forKey: WizSegmentLayout.defaultsKey)
        defaults.set(18, forKey: WizSegmentLayout.countDefaultsKey)
        XCTAssertEqual(WizSegmentLayout.stored.widths, [2, 3, 2, 3, 2, 3, 3])
        defaults.set([1, 1], forKey: WizSegmentLayout.defaultsKey)
        XCTAssertEqual(WizSegmentLayout.stored.widths, [1, 1])
    }

    func testDarkColoursGoFullScaleWithBrightnessInDimming() {
        let layout = WizSegmentLayout(widths: [1, 1, 1], slot: 258)
        let steps = layout.steps([WizRGB(r: 30, g: 30, b: 30), WizRGB(r: 10, g: 0, b: 0), WizRGB(r: 1, g: 1, b: 1)], dimming: 100)!
        XCTAssertEqual(Array(steps[0][1...5]), [0, 0, 0, 0, 255], "grey goes to the cool-white LEDs")
        XCTAssertEqual(steps[0][7], 12, "30/255 of full")
        XCTAssertEqual(steps[1][7], 10, "never below WiZ's 10% floor")
        XCTAssertEqual(steps[1][1], 100, "the rest of the darkness goes into the colour")
        XCTAssertEqual(steps[2][7], 0, "near-black is off")
    }

    func testWhiteUsesTheWhiteLEDsAndPastelsMixBoth() {
        let white = WizChannels(WizRGB(r: 255, g: 255, b: 255), dimming: 100)
        XCTAssertEqual([white.r, white.g, white.b, white.warm, white.cold, white.dimming], [0, 0, 0, 0, 255, 100])
        let pink = WizChannels(WizRGB(r: 255, g: 180, b: 180), dimming: 100)
        XCTAssertEqual([pink.r, pink.g, pink.b, pink.cold], [75, 0, 0, 180])
        let netflix = WizChannels(WizRGB(r: 229, g: 9, b: 20), dimming: 100)
        XCTAssertEqual(netflix.cold, 0, "a strong colour gets no white wash")
        XCTAssertEqual(netflix.r, 255)
        let red = WizChannels(WizRGB(r: 255, g: 0, b: 0), dimming: 50)
        XCTAssertEqual([red.r, red.g, red.b, red.cold, red.dimming], [255, 0, 0, 0, 50], "pure colours untouched")
        let p = try! JSONSerialization.jsonObject(with: WizCommand.color(WizRGB(r: 255, g: 255, b: 255), dimming: 80)) as! [String: Any]
        let params = p["params"] as! [String: Int]
        XCTAssertEqual(params, ["r": 0, "g": 0, "b": 0, "c": 255, "w": 0, "dimming": 80])
    }

    func testWhiteToneSplitsWhiteBetweenWarmAndCoolLEDs() {
        let warm = WizChannels(WizRGB(r: 200, g: 200, b: 200), dimming: 100, whiteTone: 0)
        XCTAssertEqual([warm.warm, warm.cold], [255, 0])
        let mid = WizChannels(WizRGB(r: 200, g: 200, b: 200), dimming: 100, whiteTone: 0.5)
        XCTAssertEqual(mid.warm, mid.cold)
        let red = WizChannels(WizRGB(r: 255, g: 0, b: 0), dimming: 100, whiteTone: 0)
        XCTAssertEqual([red.warm, red.cold], [0, 0], "pure colours never use white")
        let steps = WizSegmentLayout(widths: [1]).steps([WizRGB(r: 255, g: 255, b: 255)], dimming: 100, whiteTone: 0)!
        XCTAssertEqual(steps[0][4], 255, "warm white is step index 4")
    }

    func testPlainBulbsGetOneColourFromTheZones() {
        let red = WizRGB(r: 255, g: 0, b: 0), blue = WizRGB(r: 0, g: 0, b: 255)
        XCTAssertEqual(WizMode.segments([red, .off, blue]).flattened, .color(WizRGB(r: 128, g: 0, b: 128)), "lit zones only")
        let desired = WizPilot(power: true, mode: .segments([red, red]), dimming: 100)
        let data = WizFlush.messages(desired: desired, sent: WizPilot(power: true), layout: WizSegmentLayout(), mac: nil,
                                     gradientCapable: false).first!.0
        let params = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["params"] as! [String: Any]
        XCTAssertNil(params["elm"], "no elm frame: it would blank a bulb")
        XCTAssertEqual(params["r"] as? Int, 255)
    }

    func testModelConfigTellsBulbsFromGradientLights() {
        let bar = Data(#"{"method":"getModelConfig","result":{"swHead":18,"hasGradient":1}}"#.utf8)
        XCTAssertEqual(WizDiscovery.modelConfig(bar)?.gradient, true)
        XCTAssertEqual(WizDiscovery.modelConfig(bar)?.segments, 18)
        let bulb = Data(#"{"method":"getModelConfig","result":{"swHead":1,"hasGradient":0}}"#.utf8)
        XCTAssertEqual(WizDiscovery.modelConfig(bulb)?.gradient, false)
        XCTAssertNil(WizDiscovery.modelConfig(bulb)?.segments)
        XCTAssertNil(WizDiscovery.modelConfig(Data(#"{"method":"getPilot","result":{}}"#.utf8)))
    }

    func testOnlyTheKnownLightbarIsDrivenUntilTheUserPicks() {
        XCTAssertEqual(WizDiscovery.enabledLights(found: ["b", "a"], stored: nil, saved: "b"), ["b"])
        XCTAssertEqual(WizDiscovery.enabledLights(found: ["b", "a"], stored: nil, saved: nil), ["a"])
        XCTAssertEqual(WizDiscovery.enabledLights(found: ["b", "a"], stored: ["a", "b"], saved: "b"), ["a", "b"])
        XCTAssertEqual(WizDiscovery.enabledLights(found: ["a"], stored: [], saved: "a"), [], "the user turned them all off")
    }

    func testLinkResendsUnansweredCommandsAndNoticesALostLightbar() {
        let t = Date(timeIntervalSince1970: 1000)
        func at(_ s: Double) -> Date { t.addingTimeInterval(s) }
        // Answered: nothing to do.
        XCTAssertEqual(WizLink.action(now: at(1), lastCommand: at(0), lastReply: at(0.05), lastPing: .distantPast), .none)
        // Command never answered: send it again.
        XCTAssertEqual(WizLink.action(now: at(0.6), lastCommand: at(0), lastReply: at(-1), lastPing: .distantPast), .resend)
        // Quiet for a while: ping, but not twice in a row.
        XCTAssertEqual(WizLink.action(now: at(4), lastCommand: at(0), lastReply: at(0.05), lastPing: .distantPast), .ping)
        XCTAssertEqual(WizLink.action(now: at(4), lastCommand: at(0), lastReply: at(0.05), lastPing: at(3.5)), .none)
        // No reply at all for 8 s: gone.
        XCTAssertEqual(WizLink.action(now: at(9), lastCommand: at(0), lastReply: at(0.05), lastPing: at(7)), .lost)
    }

    func testLightbarIsItsOwnTarget() {
        XCTAssertTrue(LightOutputTarget.lightbar.sendsToLightbar)
        XCTAssertFalse(LightOutputTarget.lightbar.sendsToStrip)
        XCTAssertFalse(LightOutputTarget.lightbar.sendsToMiLamp)
        XCTAssertTrue(LightOutputTarget.lightbar.sendsToLamp, "mirror path runs for the lightbar")
        XCTAssertFalse(LightOutputTarget.lamp.sendsToLightbar, "Mi lamp alone leaves the lightbar out")
        XCTAssertTrue(LightOutputTarget.both.sendsToStrip && LightOutputTarget.both.sendsToMiLamp && LightOutputTarget.both.sendsToLightbar)
        XCTAssertEqual(RemoteLightControls.target(from: "lightbar"), .lightbar)
        XCTAssertTrue(RemoteLightControls.canPower(target: .lightbar, stripConnected: false))
    }

    func testDiscoveryParsesSystemConfigAndPrefersSavedLamp() {
        let reply = Data(#"{"method":"getSystemConfig","env":"pro","result":{"mac":"a8bb50000002","moduleName":"ESP25_MHORGB_01","fwVersion":"1.38.0"}}"#.utf8)
        let lamp = WizDiscovery.parse(reply, host: "192.168.1.40")
        XCTAssertEqual(lamp, WizDevice(host: "192.168.1.40", mac: "a8bb50000002", module: "ESP25_MHORGB_01"))
        XCTAssertNil(WizDiscovery.parse(Data(#"{"method":"setPilot","result":{"success":true}}"#.utf8), host: "x"))

        let other = WizDevice(host: "192.168.1.41", mac: "a8bb50000001", module: "")
        XCTAssertEqual(WizDiscovery.choose([lamp!, other], savedMAC: "a8bb50000002")?.host, "192.168.1.40")
        XCTAssertEqual(WizDiscovery.choose([lamp!, other], savedMAC: nil)?.host, "192.168.1.41")
    }
}
