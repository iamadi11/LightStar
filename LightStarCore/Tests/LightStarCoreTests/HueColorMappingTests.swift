import XCTest
@testable import LightStarCore

final class HueColorMappingTests: XCTestCase {
    func testBrightnessRoundTrip() {
        XCTAssertEqual(HueColorMapping.hueBri(fromBrightness: 1.0), 254)
        XCTAssertEqual(HueColorMapping.hueBri(fromBrightness: 0.0), 1)
        XCTAssertEqual(HueColorMapping.brightnessFromHueBri(254), 1.0, accuracy: 0.001)
        XCTAssertEqual(HueColorMapping.brightnessFromHueBri(127), 127.0 / 254.0, accuracy: 0.001)
    }

    func testHueRoundTrip() {
        XCTAssertEqual(HueColorMapping.hueHue(fromFraction: 0), 0)
        XCTAssertEqual(HueColorMapping.hueHue(fromFraction: 1), 65535)
        XCTAssertEqual(HueColorMapping.hueFraction(fromHueHue: 32768), 32768.0 / 65535.0, accuracy: 0.0001)
    }

    func testSaturationRoundTrip() {
        XCTAssertEqual(HueColorMapping.hueSat(fromSaturation: 1), 254)
        XCTAssertEqual(HueColorMapping.saturationFromHueSat(0), 0, accuracy: 0.001)
    }

    func testMiredKelvin() {
        let k = HueColorMapping.kelvin(fromMireds: 200)
        XCTAssertEqual(k, 5000, accuracy: 1)
        XCTAssertEqual(HueColorMapping.mireds(fromKelvin: 5000), 200)
    }
}
