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

    func test_unmatchedObliquePlanePreservesRawLabelsWithoutCrashing() {
        let plane = MPRPlaneGeometry(
            originVoxel: .zero,
            axisUVoxel: SIMD3<Float>(0.1, 0, 1),
            axisVVoxel: SIMD3<Float>(0, 0.1, 1),
            originWorld: .zero,
            axisUWorld: SIMD3<Float>(0.1, 0, 1),
            axisVWorld: SIMD3<Float>(0, 0.1, 1),
            originTexture: .zero,
            axisUTexture: SIMD3<Float>(0.1, 0, 1),
            axisVTexture: SIMD3<Float>(0, 0.1, 1),
            normalWorld: SIMD3<Float>(-0.1, -0.1, 0.01)
        )

        let transform = MPRDisplayTransformFactory.makeTransform(for: plane, axis: .y)

        XCTAssertEqual(transform.labels.leading, "I")
        XCTAssertEqual(transform.labels.trailing, "S")
        XCTAssertEqual(transform.labels.top, "I")
        XCTAssertEqual(transform.labels.bottom, "S")
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

    func test_viewportTransformClampsZoomAndPan() {
        let belowMinimum = MPRViewportTransform(zoom: 0.1, pan: SIMD2<Float>(0.25, -0.25))
        XCTAssertEqual(belowMinimum.zoom, MPRViewportTransform.minimumZoom)
        XCTAssertEqual(belowMinimum.pan, .zero)

        let aboveMaximum = MPRViewportTransform(zoom: 12, pan: SIMD2<Float>(10, -10))
        XCTAssertEqual(aboveMaximum.zoom, MPRViewportTransform.maximumZoom)
        XCTAssertEqual(aboveMaximum.pan.x, 3.5, accuracy: 1e-5)
        XCTAssertEqual(aboveMaximum.pan.y, -3.5, accuracy: 1e-5)
    }

    func test_displayAndViewportTransformsRoundTripWithOrientationAndFlips() {
        let display = MPRDisplayTransform(
            orientation: .rotated90CW,
            flipHorizontal: true,
            flipVertical: true,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .superior,
            bottomLabel: .inferior
        )
        let viewport = MPRViewportTransform(zoom: 2.5, pan: SIMD2<Float>(0.2, -0.1))
        let texture = SIMD2<Float>(0.25, 0.4)

        let imageScreen = display.screenCoordinates(forTexture: texture)
        let viewportScreen = viewport.screenCoordinates(forImageScreen: imageScreen)
        let roundTripImageScreen = viewport.imageScreenCoordinates(forViewportScreen: viewportScreen)
        let roundTripTexture = display.textureCoordinates(forScreen: roundTripImageScreen)

        XCTAssertEqual(roundTripTexture.x, texture.x, accuracy: 1e-5)
        XCTAssertEqual(roundTripTexture.y, texture.y, accuracy: 1e-5)
    }

}
