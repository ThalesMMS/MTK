@testable import MTKUI
import MTKCore
import XCTest

final class Clinical2DViewportOverlayTests: XCTestCase {
    func testOverlayStateBuildsPrivacySafeTechnicalLines() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            imageSize: MPRImageAnnotationSize(width: 512, height: 512),
            windowLevel: WindowLevelShift(window: 120, level: 40),
            sliceIndex: 99,
            sliceCount: 211,
            zoom: 0.83,
            pan: SIMD2<Double>(0.1, -0.2),
            angleDegrees: 0,
            slabThicknessMillimeters: 2,
            locationMillimeters: 453,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )
        let lines = state.topLeadingLines + state.topTrailingLines + state.bottomLeadingLines

        XCTAssertEqual(state.orientationLabels.leading, "R")
        XCTAssertEqual(state.orientationLabels.trailing, "L")
        XCTAssertEqual(state.orientationLabels.top, "A")
        XCTAssertEqual(state.orientationLabels.bottom, "P")
        XCTAssertEqual(state.pan, SIMD2<Double>(0.1, -0.2))
        XCTAssertTrue(lines.contains("Image size: 512x512"))
        XCTAssertTrue(lines.contains("WW: 120 WL: 40"))
        XCTAssertTrue(lines.contains("Image: 100/211"))
        XCTAssertFalse(lines.contains { ClinicalDisplayTextSanitizer.containsBlockedViewerText($0) })
    }

    func testHUDStateFormatsSubjectAndSeriesSafely() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            subjectName: "Sample^Subject",
            seriesTitle: "  CT   Abdomen Venous  ",
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )

        XCTAssertTrue(state.topLeadingLines.contains("Sample Subject"))
        XCTAssertTrue(state.topTrailingLines.contains("CT Abdomen Venous"))
        XCTAssertFalse((state.topLeadingLines + state.topTrailingLines).contains { ClinicalDisplayTextSanitizer.containsBlockedViewerText($0) })
    }

    func testHUDStateOmitsUnavailableAndUnsafeOptionalText() {
        let state = Clinical2DViewportOverlayState(
            axis: .axial,
            subjectName: nil,
            seriesTitle: "Patient ID 123456",
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )

        XCTAssertFalse(state.topLeadingLines.contains("Unknown"))
        XCTAssertFalse(state.topTrailingLines.contains("Patient ID 123456"))
    }

    func testOverlayStateUsesPlaneSpecificOrientationLabels() {
        let coronal = makeState(axis: .coronal)
        let sagittal = makeState(axis: .sagittal)

        XCTAssertEqual(coronal.orientationLabels.leading, "R")
        XCTAssertEqual(coronal.orientationLabels.trailing, "L")
        XCTAssertEqual(coronal.orientationLabels.top, "S")
        XCTAssertEqual(coronal.orientationLabels.bottom, "I")
        XCTAssertEqual(sagittal.orientationLabels.leading, "A")
        XCTAssertEqual(sagittal.orientationLabels.trailing, "P")
        XCTAssertEqual(sagittal.orientationLabels.top, "S")
        XCTAssertEqual(sagittal.orientationLabels.bottom, "I")
    }

    func testCrosshairAngleFollowsImageTransformWithoutChangingHUDAngle() {
        let mirrored = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 30,
            isFlippedHorizontally: true,
            activeTool: .rotation,
            roiKind: .distance,
            showsCrosshair: true
        )
        let doubleMirrored = Clinical2DViewportOverlayState(
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 1,
            zoom: 1,
            angleDegrees: 30,
            isFlippedHorizontally: true,
            isFlippedVertically: true,
            activeTool: .rotation,
            roiKind: .distance,
            showsCrosshair: true
        )

        XCTAssertEqual(mirrored.angleDegrees, 30)
        XCTAssertEqual(mirrored.crosshairAngleDegrees, -30)
        XCTAssertEqual(doubleMirrored.crosshairAngleDegrees, 30)
    }

    private func makeState(axis: MTKCore.Axis) -> Clinical2DViewportOverlayState {
        Clinical2DViewportOverlayState(
            axis: axis,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            sliceIndex: 0,
            sliceCount: 0,
            zoom: 1,
            angleDegrees: 0,
            activeTool: .scroll,
            roiKind: .distance,
            showsCrosshair: false
        )
    }
}
