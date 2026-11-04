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
