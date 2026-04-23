import XCTest
import simd

@testable import MTKCore

final class MPRDisplayTransformFactoryTests: XCTestCase {
    func test_canonicalPlanesProduceClinicalDisplayContract() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1)
        )

        let axial = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5),
            axis: .z
        )
        let coronal = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .y, slicePosition: 0.5),
            axis: .y
        )
        let sagittal = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .x, slicePosition: 0.5),
            axis: .x
        )

        XCTAssertEqual(axial.orientation, .standard)
        XCTAssertFalse(axial.flipHorizontal)
        XCTAssertFalse(axial.flipVertical)
        XCTAssertEqual(axial.labels.leading, "R")
        XCTAssertEqual(axial.labels.trailing, "L")
        XCTAssertEqual(axial.labels.top, "A")
        XCTAssertEqual(axial.labels.bottom, "P")

        XCTAssertEqual(coronal.orientation, .rotated180)
        XCTAssertFalse(coronal.flipHorizontal)
        XCTAssertFalse(coronal.flipVertical)
        XCTAssertEqual(coronal.labels.leading, "R")
        XCTAssertEqual(coronal.labels.trailing, "L")
        XCTAssertEqual(coronal.labels.top, "S")
        XCTAssertEqual(coronal.labels.bottom, "I")

        XCTAssertEqual(sagittal.orientation, .standard)
        XCTAssertFalse(sagittal.flipHorizontal)
        XCTAssertTrue(sagittal.flipVertical)
        XCTAssertEqual(sagittal.labels.leading, "A")
        XCTAssertEqual(sagittal.labels.trailing, "P")
        XCTAssertEqual(sagittal.labels.top, "S")
        XCTAssertEqual(sagittal.labels.bottom, "I")
    }

    func test_nonIdentityOrientationCanRequireQuarterTurnRotation() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 6, depth: 7),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            orientation: VolumeOrientation(
                row: SIMD3<Float>(0, 1, 0),
                column: SIMD3<Float>(-1, 0, 0),
                origin: .zero
            )
        )

        let transform = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5),
            axis: .z
        )

        XCTAssertNotEqual(transform.orientation, .standard)
        XCTAssertEqual(transform.labels.leading, "R")
        XCTAssertEqual(transform.labels.trailing, "L")
        XCTAssertEqual(transform.labels.top, "A")
        XCTAssertEqual(transform.labels.bottom, "P")
    }

    func test_invertedSliceOrderDoesNotChangeCanonicalEdgeLabels() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: -2)
        )

        let coronal = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .y, slicePosition: 0.5),
            axis: .y
        )

        XCTAssertEqual(coronal.labels.leading, "R")
        XCTAssertEqual(coronal.labels.trailing, "L")
        XCTAssertEqual(coronal.labels.top, "S")
        XCTAssertEqual(coronal.labels.bottom, "I")
    }

    func test_anisotropicSpacingDoesNotChangeSagittalOrientationContract() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 0.7, y: 1.2, z: 3.4)
        )

        let sagittal = MPRDisplayTransformFactory.makeTransform(
            for: MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .x, slicePosition: 0.5),
            axis: .x
        )

        XCTAssertEqual(sagittal.orientation, .standard)
        XCTAssertFalse(sagittal.flipHorizontal)
        XCTAssertTrue(sagittal.flipVertical)
        XCTAssertEqual(sagittal.labels.leading, "A")
        XCTAssertEqual(sagittal.labels.trailing, "P")
        XCTAssertEqual(sagittal.labels.top, "S")
        XCTAssertEqual(sagittal.labels.bottom, "I")
    }

    func test_screenAndTextureCoordinateMappingAreInverseOperations() {
        let transform = MPRDisplayTransform(
            orientation: .rotated90CW,
            flipHorizontal: true,
            flipVertical: false,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .anterior,
            bottomLabel: .posterior
        )
        let texture = SIMD2<Float>(0.2, 0.8)
        let screen = transform.screenCoordinates(forTexture: texture)
        let roundTrip = transform.textureCoordinates(forScreen: screen)

        XCTAssertEqual(roundTrip.x, texture.x, accuracy: 1e-5)
        XCTAssertEqual(roundTrip.y, texture.y, accuracy: 1e-5)
    }

}
