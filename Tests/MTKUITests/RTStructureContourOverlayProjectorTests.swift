import CoreGraphics
import MTKCore
@testable import MTKUI
import XCTest
import simd

final class RTStructureContourOverlayProjectorTests: XCTestCase {
    func testProjectsPlanarAxialContourOnlyWithinConfiguredTolerance() {
        let dataset = makeDataset()
        let overlay = makeOverlay()

        let onSlice = RTStructureContourOverlayProjector.annotations(
            for: [overlay],
            dataset: dataset,
            axis: .axial,
            sliceIndex: 2,
            configuration: RTStructureContourOverlayConfiguration(sliceToleranceMillimeters: 0.1)
        )

        XCTAssertEqual(onSlice.count, 1)
        XCTAssertEqual(onSlice[0].kind, .closedPath)
        XCTAssertEqual(onSlice[0].text, "PTV")
        XCTAssertEqual(onSlice[0].sliceIndex, 2)
        XCTAssertEqual(onSlice[0].seriesIdentifier, "rt-1")
        assertPoint(onSlice[0].normalizedImagePoints[0], equals: CGPoint(x: 0.25, y: 0.25))
        assertPoint(onSlice[0].normalizedImagePoints[2], equals: CGPoint(x: 0.75, y: 0.75))

        let outsideTolerance = RTStructureContourOverlayProjector.annotations(
            for: [overlay],
            dataset: dataset,
            axis: .axial,
            sliceIndex: 3,
            configuration: RTStructureContourOverlayConfiguration(sliceToleranceMillimeters: 0.4)
        )
        XCTAssertTrue(outsideTolerance.isEmpty)

        let insideTolerance = RTStructureContourOverlayProjector.annotations(
            for: [overlay],
            dataset: dataset,
            axis: .axial,
            sliceIndex: 3,
            configuration: RTStructureContourOverlayConfiguration(sliceToleranceMillimeters: 1.1)
        )
        XCTAssertEqual(insideTolerance.count, 1)
    }

    func testIntersectsAxialContourWithCoronalPlane() {
        let dataset = makeDataset()
        let overlay = makeOverlay()

        let annotations = RTStructureContourOverlayProjector.annotations(
            for: [overlay],
            dataset: dataset,
            axis: .coronal,
            sliceIndex: 2,
            configuration: RTStructureContourOverlayConfiguration(sliceToleranceMillimeters: 0.1)
        )

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].kind, .curvedLine)
        XCTAssertEqual(annotations[0].text, "PTV")
        XCTAssertEqual(annotations[0].normalizedImagePoints.count, 2)
        assertPoint(annotations[0].normalizedImagePoints[0], equals: CGPoint(x: 0.25, y: 0.5))
        assertPoint(annotations[0].normalizedImagePoints[1], equals: CGPoint(x: 0.75, y: 0.5))
    }

    func testBlockedLabelFallsBackToROINumber() {
        let dataset = makeDataset()
        let overlay = RTStructureContourOverlay(
            id: "rt-phi",
            contours: [
                RTStructureContour(
                    roiNumber: 9,
                    label: "Patient Name Example",
                    geometricType: "CLOSED_PLANAR",
                    patientPoints: [
                        SIMD3<Double>(1, 1, 2),
                        SIMD3<Double>(3, 1, 2),
                        SIMD3<Double>(3, 3, 2),
                        SIMD3<Double>(1, 3, 2)
                    ]
                )
            ]
        )

        let annotations = RTStructureContourOverlayProjector.annotations(
            for: [overlay],
            dataset: dataset,
            axis: .axial,
            sliceIndex: 2
        )

        XCTAssertEqual(annotations.first?.text, "ROI 9")
    }

    private func makeOverlay() -> RTStructureContourOverlay {
        RTStructureContourOverlay(
            id: "rt-1",
            contours: [
                RTStructureContour(
                    roiNumber: 7,
                    label: "PTV",
                    geometricType: "CLOSED_PLANAR",
                    displayColor: SIMD4<Float>(0.2, 0.4, 0.6, 1),
                    patientPoints: [
                        SIMD3<Double>(1, 1, 2),
                        SIMD3<Double>(3, 1, 2),
                        SIMD3<Double>(3, 3, 2),
                        SIMD3<Double>(1, 3, 2)
                    ]
                )
            ]
        )
    }

    private func makeDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 5, height: 5, depth: 5)
        return VolumeDataset(
            data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: 0...1
        )
    }

    private func assertPoint(_ actual: CGPoint,
                             equals expected: CGPoint,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001, file: file, line: line)
    }
}
