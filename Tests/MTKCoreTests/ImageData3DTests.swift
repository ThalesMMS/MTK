import XCTest
import simd
@testable import MTKCore

final class ImageData3DTests: XCTestCase {
    func test_identityDirectionRoundTripsIndexWorldAndTexture() {
        let imageData = ImageData3D(
            dimensions: VolumeDimensions(width: 8, height: 10, depth: 12),
            spacing: VolumeSpacing(x: 0.5, y: 1.25, z: 2.5),
            origin: SIMD3<Float>(10, 20, 30),
            direction: matrix_identity_float3x3,
            pixelFormat: .int16Signed
        )
        let index = SIMD3<Float>(2.5, 4, 6.25)
        let world = imageData.indexToWorld.transformPoint(index)
        let roundTripIndex = imageData.worldToIndex.transformPoint(world)
        let worldToTexture = imageData.worldToTexture.transformPoint(world)
        let directTexture = imageData.voxelToTexture.transformPoint(index)

        assertVector(world, SIMD3<Float>(11.25, 25, 45.625))
        assertVector(roundTripIndex, index, accuracy: 1e-4)
        assertVector(worldToTexture, directTexture, accuracy: 1e-5)
        assertVector(directTexture, SIMD3<Float>(3.0 / 8.0, 4.5 / 10.0, 6.75 / 12.0))
    }

    func test_nonIdentityDirectionUsesFullAffineWithNonZeroOrigin() {
        let direction = simd_float3x3(columns: (
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 0, 0)
        ))
        let imageData = ImageData3D(
            dimensions: VolumeDimensions(width: 6, height: 5, depth: 4),
            spacing: VolumeSpacing(x: 2, y: 3, z: 4),
            origin: SIMD3<Float>(10, 20, 30),
            direction: direction,
            pixelFormat: .int16Signed
        )
        let index = SIMD3<Float>(1.25, 2, 0.5)
        let world = imageData.indexToWorld.transformPoint(index)
        let roundTripIndex = imageData.worldToIndex.transformPoint(world)

        XCTAssertEqual(imageData.rowDirection, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(imageData.columnDirection, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(imageData.sliceDirection, SIMD3<Float>(1, 0, 0))
        assertVector(world, SIMD3<Float>(12, 22.5, 36))
        assertVector(roundTripIndex, index, accuracy: 1e-4)
    }

    func test_scalarMetadataExposesSignednessBytesAndComponents() {
        let signed = ImageData3D(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            origin: .zero,
            direction: matrix_identity_float3x3,
            pixelFormat: .int16Signed,
            componentsPerVoxel: 1
        )
        let unsigned = ImageData3D(
            dimensions: signed.dimensions,
            spacing: signed.spacing,
            origin: .zero,
            direction: matrix_identity_float3x3,
            pixelFormat: .int16Unsigned,
            componentsPerVoxel: 1
        )

        XCTAssertTrue(signed.pixelFormat.isSigned)
        XCTAssertFalse(unsigned.pixelFormat.isSigned)
        XCTAssertEqual(signed.bytesPerVoxel, 2)
        XCTAssertEqual(unsigned.bytesPerVoxel, 2)
        XCTAssertEqual(signed.componentsPerVoxel, 1)
        XCTAssertEqual(unsigned.componentsPerVoxel, 1)
        XCTAssertEqual(signed.pixelFormat.scalarTypeDescription, "Int16")
        XCTAssertEqual(unsigned.pixelFormat.scalarTypeDescription, "UInt16")
    }

    func test_volumeDatasetCompatibilityAccessorsMutateCanonicalImageData() {
        var dataset = VolumeDataset(
            data: Data(count: 16),
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: .zero)
        )

        dataset.spacing = VolumeSpacing(x: 0.7, y: 0.8, z: 2.5)
        dataset.orientation = VolumeOrientation(row: SIMD3<Float>(0, 1, 0),
                                                column: SIMD3<Float>(0, 0, 1),
                                                origin: SIMD3<Float>(5, 6, 7))

        XCTAssertEqual(dataset.imageData.spacing, VolumeSpacing(x: 0.7, y: 0.8, z: 2.5))
        XCTAssertEqual(dataset.imageData.origin, SIMD3<Float>(5, 6, 7))
        XCTAssertEqual(dataset.imageData.rowDirection, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(dataset.imageData.columnDirection, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(dataset.imageData.sliceDirection, SIMD3<Float>(1, 0, 0))
    }
}

private func assertVector(_ actual: SIMD3<Float>,
                          _ expected: SIMD3<Float>,
                          accuracy: Float = 1e-5,
                          file: StaticString = #filePath,
                          line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
}
