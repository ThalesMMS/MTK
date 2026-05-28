import MTKCore
@testable import MTKUI
import XCTest

final class MPRImageAnnotationsOverlayTests: XCTestCase {
    func testDisplayLinesContainOnlyTechnicalMPRValues() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 2,
            axis: .coronal,
            imageSize: MPRImageAnnotationSize(width: 512, height: 128),
            windowLevel: WindowLevelShift(window: 120, level: 40),
            slabThickness: 15,
            zoom: 1.5,
            angleDegrees: 12
        )

        XCTAssertEqual(state.displayLines, [
            "Panel 2",
            "Image size: 512x128",
            "WW: 120 WL: 40",
            "Orientation: Coronal",
            "Thickness: 15 mm",
            "Zoom: 150%",
            "Angle: 12 deg"
        ])
    }

    func testStateSanitizesInvalidNumbers() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 0,
            axis: .sagittal,
            windowLevel: WindowLevelShift(window: .nan, level: .infinity),
            slabThickness: .nan,
            zoom: .nan,
            angleDegrees: .infinity
        )

        XCTAssertEqual(state.panelNumber, 1)
        XCTAssertEqual(state.displayLines, [
            "Panel 1",
            "WW: 0 WL: 0",
            "Orientation: Sagittal",
            "Thickness: 0 mm",
            "Zoom: 0%",
            "Angle: 0 deg"
        ])
    }
}
