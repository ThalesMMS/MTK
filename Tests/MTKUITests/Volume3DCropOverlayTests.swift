#if canImport(SwiftUI)
@testable import MTKUI
import XCTest

final class Volume3DCropOverlayTests: XCTestCase {
    func testOverlayStateClampsAndOrdersBounds() {
        let state = Volume3DCropOverlayState(yMin: 1.4, yMax: -0.2)

        XCTAssertEqual(state.yMin, 0)
        XCTAssertEqual(state.yMax, 1)
    }

    func testOverlayLayoutMapsFullCropToInsetBand() {
        let layout = Volume3DCropOverlayLayout(topInsetFraction: 0.2,
                                               bottomInsetFraction: 0.8)

        XCTAssertEqual(layout.yPosition(forBound: 1, height: 100), 20, accuracy: 0.000_1)
        XCTAssertEqual(layout.yPosition(forBound: 0, height: 100), 80, accuracy: 0.000_1)
        XCTAssertEqual(layout.boundValue(forY: 20, height: 100), 1, accuracy: 0.000_1)
        XCTAssertEqual(layout.boundValue(forY: 80, height: 100), 0, accuracy: 0.000_1)
        XCTAssertEqual(layout.boundValue(forY: -20, height: 100), 1, accuracy: 0.000_1)
        XCTAssertEqual(layout.boundValue(forY: 120, height: 100), 0, accuracy: 0.000_1)
    }
}
#endif
