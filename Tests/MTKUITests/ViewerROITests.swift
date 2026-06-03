import CoreGraphics
import Foundation
import MTKCore
@testable import MTKUI
import XCTest

final class ViewerROITests: XCTestCase {
    func testROIStoreDeletesOnlyMatchingAxisAndSlice() {
        let axialSlice1 = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                         axis: .axial,
                                         sliceIndex: 1)
        let axialSlice2 = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                         axis: .axial,
                                         sliceIndex: 2)
        let coronalSlice1 = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                                           axis: .coronal,
                                           sliceIndex: 1)
        var store = ViewerROIStore(annotations: [axialSlice1, axialSlice2, coronalSlice1])

        let removed = store.deleteAnnotations(axis: .axial, sliceIndex: 1)

        XCTAssertEqual(removed, [axialSlice1])
        XCTAssertEqual(store.annotations, [axialSlice2, coronalSlice1])
    }

    func testROIStoreDeleteAllClearsSessionAnnotations() {
        var store = ViewerROIStore(annotations: [
            makeAnnotation(axis: .axial, sliceIndex: 1),
            makeAnnotation(axis: .sagittal, sliceIndex: 3)
        ])

        store.deleteAll()

        XCTAssertTrue(store.annotations.isEmpty)
    }

    func testROIStoreFiltersAndDeletesBySeriesAxisAndSlice() {
        let current = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                                     axis: .axial,
                                     sliceIndex: 1,
                                     seriesIdentifier: "series-a")
        let otherSlice = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                                        axis: .axial,
                                        sliceIndex: 2,
                                        seriesIdentifier: "series-a")
        let otherSeries = makeAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                                         axis: .axial,
                                         sliceIndex: 1,
                                         seriesIdentifier: "series-b")
        var store = ViewerROIStore(annotations: [current, otherSlice, otherSeries])

        XCTAssertEqual(store.annotations(axis: .axial, sliceIndex: 1, seriesIdentifier: "series-a"), [current])

        let removed = store.deleteAnnotations(axis: .axial, sliceIndex: 1, seriesIdentifier: "series-a")

        XCTAssertEqual(removed, [current])
        XCTAssertEqual(store.annotations, [otherSlice, otherSeries])
    }

    func testROIStoreSupportsHitTestingAndEditing() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        var annotation = makeAnnotation(id: id, axis: .axial, sliceIndex: 1)
        annotation.normalizedImagePoints = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25)]
        var store = ViewerROIStore(annotations: [annotation])

        XCTAssertEqual(store.hitTest(normalizedPoint: CGPoint(x: 0.5, y: 0.26), axis: .axial, sliceIndex: 1)?.id, id)

        store.movePoint(annotationID: id, pointIndex: 1, to: CGPoint(x: 0.9, y: 0.4))
        XCTAssertEqual(store.annotations[0].normalizedImagePoints[1], CGPoint(x: 0.9, y: 0.4))

        store.moveAnnotation(id: id, by: CGVector(dx: 0.2, dy: -0.1))
        XCTAssertEqual(store.annotations[0].normalizedImagePoints[0], CGPoint(x: 0.45, y: 0.15))
        XCTAssertEqual(store.annotations[0].normalizedImagePoints[1].x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.annotations[0].normalizedImagePoints[1].y, 0.3, accuracy: 0.0001)
    }

    func testDistanceMeasurementUsesDatasetSpacingAndDimensions() throws {
        let dimensions = VolumeDimensions(width: 101, height: 51, depth: 11)
        let spacing = VolumeSpacing(x: 0.5, y: 2, z: 3)

        let axialDistance = try XCTUnwrap(ViewerROIMeasurementCalculator.distanceMillimeters(
            axis: .axial,
            normalizedImagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
            dimensions: dimensions,
            spacing: spacing
        ))
        let coronalDistance = try XCTUnwrap(ViewerROIMeasurementCalculator.distanceMillimeters(
            axis: .coronal,
            normalizedImagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)],
            dimensions: dimensions,
            spacing: spacing
        ))
        let sagittalDistance = try XCTUnwrap(ViewerROIMeasurementCalculator.distanceMillimeters(
            axis: .sagittal,
            normalizedImagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
            dimensions: dimensions,
            spacing: spacing
        ))

        XCTAssertEqual(axialDistance, 50, accuracy: 0.001)
        XCTAssertEqual(coronalDistance, 30, accuracy: 0.001)
        XCTAssertEqual(sagittalDistance, 100, accuracy: 0.001)
    }

    func testDistanceMeasurementCanUsePlaneGeometry() throws {
        let plane = MPRPlaneGeometry(
            originVoxel: .zero,
            axisUVoxel: SIMD3<Float>(10, 0, 0),
            axisVVoxel: SIMD3<Float>(0, 20, 0),
            originWorld: .zero,
            axisUWorld: SIMD3<Float>(30, 0, 0),
            axisVWorld: SIMD3<Float>(0, 40, 0),
            originTexture: .zero,
            axisUTexture: SIMD3<Float>(1, 0, 0),
            axisVTexture: SIMD3<Float>(0, 1, 0),
            normalWorld: SIMD3<Float>(0, 0, 1)
        )

        let distance = try XCTUnwrap(ViewerROIMeasurementCalculator.distanceMillimeters(
            normalizedImagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            plane: plane
        ))

        XCTAssertEqual(distance, 50, accuracy: 0.001)
    }

    func testAngleAreaEllipsePolylineAndCTRMeasurements() throws {
        let dimensions = VolumeDimensions(width: 101, height: 101, depth: 21)
        let spacing = VolumeSpacing(x: 0.5, y: 2, z: 3)

        let angle = try XCTUnwrap(ViewerROIMeasurementCalculator.angleDegrees(
            normalizedImagePoints: [
                CGPoint(x: 1, y: 0),
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0, y: 1)
            ]
        ))
        let area = try XCTUnwrap(ViewerROIMeasurementCalculator.areaSquareMillimeters(
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1),
                CGPoint(x: 0, y: 1)
            ],
            dimensions: dimensions,
            spacing: spacing
        ))
        let length = try XCTUnwrap(ViewerROIMeasurementCalculator.polylineLengthMillimeters(
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1)
            ],
            dimensions: dimensions,
            spacing: spacing
        ))
        let ellipse = try XCTUnwrap(ViewerROIMeasurementCalculator.ellipseAreaSquareMillimeters(
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1),
                CGPoint(x: 0, y: 1)
            ],
            dimensions: dimensions,
            spacing: spacing
        ))
        let ratio = try XCTUnwrap(ViewerROIMeasurementCalculator.ctrRatio(
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0, y: 0.5),
                CGPoint(x: 1, y: 0.5),
                CGPoint(x: 0.25, y: 0.5),
                CGPoint(x: 0.75, y: 0.5)
            ],
            dimensions: dimensions,
            spacing: spacing
        ))

        XCTAssertEqual(angle, 90, accuracy: 0.001)
        XCTAssertEqual(area, 10_000, accuracy: 0.001)
        XCTAssertEqual(length, 250, accuracy: 0.001)
        XCTAssertEqual(ellipse, Double.pi * 2_500, accuracy: 0.001)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    }

    func testROIAnnotationsExposeMeasurementModelUnitAndPersistentState() throws {
        let annotation = ViewerROIAnnotation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            kind: .ellipse,
            axis: .coronal,
            sliceIndex: 4,
            seriesIdentifier: "series-a",
            normalizedImagePoints: ViewerROIPointFactory.points(
                kind: .ellipse,
                start: CGPoint(x: 0.1, y: 0.2),
                end: CGPoint(x: 0.7, y: 0.8)
            ),
            text: "  My ROI  ",
            measurement: .areaSquareMillimeters(42)
        )

        XCTAssertEqual(annotation.measurementModel, .ellipse)
        XCTAssertEqual(annotation.measurementUnit, .squareMillimeters)
        XCTAssertEqual(annotation.text, "My ROI")

        let state = annotation.persistentState
        XCTAssertEqual(state.kind, .ellipse)
        XCTAssertEqual(state.axis, "coronal")
        XCTAssertEqual(state.measurementModel, .ellipse)
        XCTAssertEqual(state.measurementUnit, .squareMillimeters)
        XCTAssertEqual(state.measurement?.displayText, "42.0 mm2")
        XCTAssertNoThrow(try JSONEncoder().encode(state))
    }

    func testLabelmapVolumeMeasurementCountsRequestedSegment() throws {
        let layer = try makeLabelmapLayer(labels: [1, 2, 0, 2],
                                          spacing: VolumeSpacing(x: 2, y: 3, z: 4))

        let summary = try ViewerROILabelmapVolumeCalculator.summary(in: layer, label: 2)
        let measurement = try ViewerROIMeasurementCalculator.volumeMeasurement(in: layer, label: 2)

        XCTAssertEqual(summary.layerID, "roi-layer")
        XCTAssertEqual(summary.label, 2)
        XCTAssertEqual(summary.segmentName, "Target")
        XCTAssertEqual(summary.voxelCount, 2)
        XCTAssertEqual(summary.volumeCubicMillimeters, 48, accuracy: 0.001)
        XCTAssertEqual(summary.measurement.displayText, "48.0 mm3")
        XCTAssertEqual(measurement, .volumeCubicMillimeters(48))
    }

    func testLabelmapVolumeMeasurementCountsAllNonZeroLabelsWhenNoSegmentIsSelected() throws {
        let layer = try makeLabelmapLayer(labels: [1, 2, 0, 2],
                                          spacing: VolumeSpacing(x: 2, y: 3, z: 4))

        let summary = try ViewerROILabelmapVolumeCalculator.summary(in: layer)

        XCTAssertNil(summary.label)
        XCTAssertNil(summary.segmentName)
        XCTAssertEqual(summary.voxelCount, 3)
        XCTAssertEqual(summary.volumeCubicMillimeters, 72, accuracy: 0.001)
        XCTAssertEqual(summary.measurement, .volumeCubicMillimeters(72))
    }

    func testLabelmapVolumeMeasurementRejectsEmptySelection() throws {
        let layer = try makeLabelmapLayer(labels: [1, 2, 0, 2],
                                          spacing: VolumeSpacing(x: 2, y: 3, z: 4))

        XCTAssertThrowsError(try ViewerROILabelmapVolumeCalculator.summary(in: layer, label: 3)) { error in
            XCTAssertEqual(error as? ViewerROILabelmapVolumeError, .emptySelection("roi-layer", 3))
        }
    }

    func testVolumeROIKindIsNotSupportedAsDrawnAnnotation() {
        XCTAssertFalse(ViewerROIKind.volume.supportsDrawnAnnotationMeasurement)
        XCTAssertFalse(ViewerROIKind.volume.isImplementedInMPRFirstDelivery)
        XCTAssertNil(ViewerROIMeasurementCalculator.measurement(
            kind: .volume,
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0.1, y: 0.1),
                CGPoint(x: 0.8, y: 0.8)
            ],
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 2, y: 3, z: 4)
        ))
    }

    private func makeLabelmapLayer(labels: [UInt16],
                                   spacing: VolumeSpacing) throws -> VolumeLayer {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 1)
        let dataset = VolumeDataset(
            data: labels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...2
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [
                LabelmapSegment(label: 1, name: "Background", color: SIMD4<Float>(0, 0, 1, 1)),
                LabelmapSegment(label: 2, name: "Target", color: SIMD4<Float>(1, 0, 0, 1))
            ]
        )
        return VolumeLayer(id: "roi-layer", labelmap: labelmap)
    }

    private func makeAnnotation(id: UUID = UUID(),
                                axis: MTKCore.Axis,
                                sliceIndex: Int?,
                                seriesIdentifier: String? = nil) -> ViewerROIAnnotation {
        ViewerROIAnnotation(
            id: id,
            kind: .point,
            axis: axis,
            sliceIndex: sliceIndex,
            seriesIdentifier: seriesIdentifier,
            normalizedImagePoints: [CGPoint(x: 0.5, y: 0.5)]
        )
    }
}
