import CoreGraphics
import XCTest
import simd
@_spi(Testing) @testable import MTKCore

final class MPRPlaneGeometryFactoryTests: XCTestCase {
    func test_canonicalOrientationProducesExpectedAxisAlignedPlanes() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1)
        )

        let sagittal = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .x, slicePosition: 0.5)
        let coronal = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .y, slicePosition: 0.5)
        let axial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)

        assertVector(sagittal.originWorld, SIMD3<Float>(2, 0, 0))
        assertVector(sagittal.axisUWorld, SIMD3<Float>(0, 6, 0))
        assertVector(sagittal.axisVWorld, SIMD3<Float>(0, 0, 8))
        assertVector(sagittal.normalWorld, SIMD3<Float>(1, 0, 0))

        assertVector(coronal.originWorld, SIMD3<Float>(4, 3, 0))
        assertVector(coronal.axisUWorld, SIMD3<Float>(-4, 0, 0))
        assertVector(coronal.axisVWorld, SIMD3<Float>(0, 0, 8))
        assertVector(coronal.normalWorld, SIMD3<Float>(0, 1, 0))

        assertVector(axial.originWorld, SIMD3<Float>(0, 0, 4))
        assertVector(axial.axisUWorld, SIMD3<Float>(4, 0, 0))
        assertVector(axial.axisVWorld, SIMD3<Float>(0, 6, 0))
        assertVector(axial.normalWorld, SIMD3<Float>(0, 0, 1))
    }

    func test_anisotropicSpacingScalesWorldExtentsCorrectly() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )

        let axial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)
        let sagittal = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .x, slicePosition: 0.5)

        assertVector(axial.originWorld, SIMD3<Float>(0, 0, 12))
        assertVector(axial.axisUWorld, SIMD3<Float>(4, 0, 0))
        assertVector(axial.axisVWorld, SIMD3<Float>(0, 6, 0))
        assertVector(sagittal.axisUWorld, SIMD3<Float>(0, 6, 0))
        assertVector(sagittal.axisVWorld, SIMD3<Float>(0, 0, 24))
        XCTAssertEqual(simd_length(axial.axisUWorld), 4, accuracy: 1e-5)
        XCTAssertEqual(simd_length(axial.axisVWorld), 6, accuracy: 1e-5)
        XCTAssertEqual(simd_length(sagittal.axisVWorld), 24, accuracy: 1e-5)
    }

    func test_nonIdentityOrientationTransformsWorldAxesAndKeepsNormalPerpendicular() {
        let row = simd_normalize(SIMD3<Float>(1, 1, 0))
        let column = SIMD3<Float>(0, 0, 1)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 4, depth: 6),
            spacing: VolumeSpacing(x: 2, y: 1.5, z: 3),
            orientation: VolumeOrientation(row: row,
                                           column: column,
                                           origin: SIMD3<Float>(10, 20, 30))
        )

        let axial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)

        XCTAssertNotEqual(axial.axisUWorld, axial.axisUVoxel)
        XCTAssertNotEqual(axial.axisVWorld, axial.axisVVoxel)
        XCTAssertEqual(simd_dot(axial.axisUWorld, axial.normalWorld), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(axial.axisVWorld, axial.normalWorld), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(axial.normalWorld), 1, accuracy: 1e-5)
    }

    func test_tiltedGantryOrientationProducesCorrectObliqueGeometry() {
        let row = SIMD3<Float>(1, 0, 0)
        let column = simd_normalize(SIMD3<Float>(0, 1, 1))
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 2, z: 2.5),
            orientation: VolumeOrientation(row: row,
                                           column: column,
                                           origin: SIMD3<Float>(5, 10, 15))
        )

        let axial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)
        let expectedNormal = simd_normalize(simd_cross(row, column))

        assertPerpendicular(axial.axisUWorld, axial.normalWorld)
        assertPerpendicular(axial.axisVWorld, axial.normalWorld)
        assertVector(axial.normalWorld, expectedNormal)
        XCTAssertNotEqual(axial.axisVWorld, SIMD3<Float>(0, 8, 0))
    }

    func test_invertedSliceOrderWithNegativeSliceSpacingKeepsPatientNormalAndMovesOriginBackwards() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 3, height: 4, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 2, z: -4),
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: SIMD3<Float>(11, 22, 33))
        )

        let firstAxial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0)
        let lastAxial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 1)

        assertVector(firstAxial.originWorld, SIMD3<Float>(11, 22, 33))
        assertVector(lastAxial.originWorld, SIMD3<Float>(11, 22, 17))
        assertVector(firstAxial.normalWorld, SIMD3<Float>(0, 0, 1))
        assertVector(lastAxial.normalWorld, SIMD3<Float>(0, 0, 1))
        XCTAssertLessThan(lastAxial.originWorld.z, firstAxial.originWorld.z)
    }

    func test_voxelWorldTextureRoundTripMatchesDirectVoxelToTexture() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 6, height: 5, depth: 4),
            spacing: VolumeSpacing(x: 0.8, y: 1.4, z: 2.2),
            orientation: VolumeOrientation(
                row: simd_normalize(SIMD3<Float>(1, 1, 0)),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(12, 24, 36)
            )
        )
        let geometry = MPRPlaneGeometryFactory.makeGeometry(for: dataset)
        let voxel = SIMD3<Float>(1.25, 2.5, 1.75)
        let world = geometry.voxelToWorld.transformPoint(voxel)
        let roundTripTexture = geometry.worldToTex.transformPoint(world)
        let directTexture = geometry.voxelToTex.transformPoint(voxel)

        assertVector(roundTripTexture, directTexture, accuracy: 1e-4)
    }

    func test_dicomGeometryUsesFourthColumnForWorldAndTextureTranslations() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 6, height: 5, depth: 4),
            spacing: VolumeSpacing(x: 0.8, y: 1.4, z: 2.2),
            orientation: VolumeOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 1, 0),
                origin: SIMD3<Float>(12, 24, 36)
            )
        )
        let geometry = MPRPlaneGeometryFactory.makeGeometry(for: dataset)

        assertVector(geometry.voxelToWorld.transformPoint(.zero),
                     SIMD3<Float>(12, 24, 36),
                     accuracy: 1e-5)
        assertVector(geometry.voxelToTex.transformPoint(.zero),
                     SIMD3<Float>(1.0 / 12.0, 1.0 / 10.0, 1.0 / 8.0),
                     accuracy: 1e-5)
    }

    func test_planeOriginTextureStaysWithinUnitCubeForValidSlicePositions() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 9, depth: 10),
            spacing: VolumeSpacing(x: 0.7, y: 1.1, z: 2.3),
            orientation: VolumeOrientation(
                row: simd_normalize(SIMD3<Float>(1, 1, 0)),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(3, 6, 9)
            )
        )

        for axis in MPRPlaneAxis.allCases {
            for slicePosition in stride(from: Float(0), through: Float(1), by: Float(0.25)) {
                let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                              axis: axis,
                                                              slicePosition: slicePosition)
                XCTAssertTrue(isWithinUnitCube(plane.originTexture),
                              "originTexture out of bounds for axis \(axis) at \(slicePosition): \(plane.originTexture)")
            }
        }
    }

    func test_textureAxesMagnitudesMatchExpectedVoxelToTextureScalingForAnisotropicVolume() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )

        let axial = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)
        let sagittal = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .x, slicePosition: 0.5)

        XCTAssertEqual(simd_length(axial.axisUTexture), 4.0 / 5.0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(axial.axisVTexture), 6.0 / 7.0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(sagittal.axisUTexture), 6.0 / 7.0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(sagittal.axisVTexture), 8.0 / 9.0, accuracy: 1e-5)
    }

    func test_planeWorldToTexMatchesManualWorldToTexComputation() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 6, depth: 7),
            spacing: VolumeSpacing(x: 0.9, y: 1.3, z: 2.1),
            orientation: VolumeOrientation(
                row: SIMD3<Float>(0, 1, 0),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(7, 11, 13)
            )
        )
        let geometry = MPRPlaneGeometryFactory.makeGeometry(for: dataset)
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .y, slicePosition: 0.25)
        let planeWorldToTex = geometry.planeWorldToTex(originW: plane.originWorld,
                                                       axisUW: plane.axisUWorld,
                                                       axisVW: plane.axisVWorld)
        let manualOrigin = geometry.worldToTex.transformPoint(plane.originWorld)
        let manualU = geometry.worldToTex.transformPoint(plane.originWorld + plane.axisUWorld) - manualOrigin
        let manualV = geometry.worldToTex.transformPoint(plane.originWorld + plane.axisVWorld) - manualOrigin

        assertVector(planeWorldToTex.originT, manualOrigin, accuracy: 1e-5)
        assertVector(planeWorldToTex.axisUT, manualU, accuracy: 1e-5)
        assertVector(planeWorldToTex.axisVT, manualV, accuracy: 1e-5)
    }

    func test_sizedForOutputChangesPixelDimensionsWithoutChangingPhysicalBasis() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 1, y: 1, z: 3)
        )
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)
        let resized = plane.sizedForOutput(CGSize(width: 9, height: 13))

        assertVector(resized.axisUVoxel, plane.axisUVoxel * 2)
        assertVector(resized.axisVVoxel, plane.axisVVoxel * 2)
        assertVector(resized.axisUWorld, plane.axisUWorld)
        assertVector(resized.axisVWorld, plane.axisVWorld)
        assertVector(resized.axisUTexture, plane.axisUTexture)
        assertVector(resized.axisVTexture, plane.axisVTexture)
    }
}

private extension MPRPlaneGeometryFactoryTests {
    func assertVector(_ actual: SIMD3<Float>,
                      _ expected: SIMD3<Float>,
                      accuracy: Float = 1e-5,
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    func assertPerpendicular(_ lhs: SIMD3<Float>,
                             _ rhs: SIMD3<Float>,
                             accuracy: Float = 1e-5,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(simd_dot(lhs, rhs), 0, accuracy: accuracy, file: file, line: line)
    }

    func isWithinUnitCube(_ vector: SIMD3<Float>) -> Bool {
        vector.x >= 0 && vector.x <= 1 &&
        vector.y >= 0 && vector.y <= 1 &&
        vector.z >= 0 && vector.z <= 1
    }
}
