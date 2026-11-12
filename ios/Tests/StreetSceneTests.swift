import XCTest
@testable import Muninn

/// The onboarding street is a 1:1 port of build/anim.js. Each hash is FNV-1a over the RGB bytes of the JS frame
/// (Chrome canvas, the same t), so a frame that drifts from the design by one pixel fails here.
final class StreetSceneTests: XCTestCase {
    private func hash(_ px: [UInt32]) -> String {
        var h: UInt32 = 0x811c9dc5
        for p in px {
            for shift in [0, 8, 16] as [UInt32] { h ^= (p >> shift) & 0xFF; h = h &* 0x01000193 }
        }
        return String(h, radix: 16)
    }

    func testFramesMatchTheDesign() {
        let expected: [(Double, String)] = [
            (0, "bb02a77e"), (25.0 / 24, "16be6e0e"), (36.0 / 24, "d7c518dd"), (54.0 / 24, "7b35e16a"), (73.0 / 24, "c5e083b9"),
            (93.0 / 24, "25dcb55f"), (125.0 / 24, "f9567a94"), (6.9, "323d0aca"), (176.0 / 24, "50f5449c"), (187.0 / 24, "677d2309"),
        ]
        for (t, h) in expected { XCTAssertEqual(hash(StreetScene.pixels(at: t)), h, "frame at t = \(t)") }
    }

    func testLoopsEveryEightSeconds() {
        XCTAssertEqual(StreetScene.pixels(at: 1.5), StreetScene.pixels(at: 9.5))
        XCTAssertNotNil(StreetScene.frame(at: StreetScene.stillTime))
        XCTAssertEqual(StreetScene.frame(at: 0)?.width, 98)
        XCTAssertEqual(StreetScene.frame(at: 0)?.height, 118)
    }
}
