import Foundation
import simd
import XCTest

@testable import MTKCore

final class VolumeClippingTests: XCTestCase {
    func testCropBoxValidatesNormalizedBounds() throws {
        XCTAssertNoThrow(
            try VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.2, 0.3),
                              textureMax: SIMD3<Float>(0.8, 0.9, 1.0))
        )

        XCTAssertThrowsError(
            try VolumeCropBox(textureMin: SIMD3<Float>(-0.1, 0, 0),
                              textureMax: SIMD3<Float>(1, 1, 1))
        ) { error in
            XCTAssertEqual(error as? VolumeClippingError, .cropBoundsOutOfRange)
        }

        XCTAssertThrowsError(
            try VolumeCropBox(textureMin: SIMD3<Float>(0.7, 0, 0),
                              textureMax: SIMD3<Float>(0.3, 1, 1))
        ) { error in
            XCTAssertEqual(error as? VolumeClippingError, .invertedCropBounds(axis: "x"))
        }
    }

    func testInclusiveVoxelBoundsMapToTextureBounds() throws {
        let crop = try VolumeCropBox(
            inclusiveVoxelMin: SIMD3<Int32>(1, 2, 3),
            inclusiveVoxelMax: SIMD3<Int32>(3, 5, 7),
            dimensions: VolumeDimensions(width: 4, height: 8, depth: 10)
        )

        assertVector(crop.textureMin, SIMD3<Float>(0.25, 0.25, 0.3))
        assertVector(crop.textureMax, SIMD3<Float>(1.0, 0.75, 0.8))
    }

    func testInclusiveVoxelBoundsRejectDimensionsOutsideInt32Range() throws {
        let dimensions = VolumeDimensions(width: Int(Int32.max) + 1, height: 1, depth: 1)

        XCTAssertThrowsError(
            try VolumeCropBox(
                inclusiveVoxelMin: SIMD3<Int32>(0, 0, 0),
                inclusiveVoxelMax: SIMD3<Int32>(0, 0, 0),
                dimensions: dimensions
            )
        ) { error in
            XCTAssertEqual(error as? VolumeClippingError, .invalidVoxelIndexBounds)
        }
    }

    func testClipPlaneValidationAndMaxPlaneCount() throws {
        XCTAssertThrowsError(
            try VolumeClipPlane(worldNormal: .zero, distance: 0)
        ) { error in
            XCTAssertEqual(error as? VolumeClippingError, .degenerateClipPlaneNormal)
        }

        let plane = try VolumeClipPlane(worldNormal: SIMD3<Float>(0, 0, 2), distance: -4)
        assertVector(plane.normalWorld, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(plane.distanceWorld, -2, accuracy: 1e-6)

        XCTAssertNoThrow(try VolumeClippingState(clipPlanes: [plane, plane, plane]))
        XCTAssertThrowsError(
            try VolumeClippingState(clipPlanes: [plane, plane, plane, plane])
        ) { error in
            XCTAssertEqual(error as? VolumeClippingError,
                           .tooManyClipPlanes(maximum: VolumeClippingState.maxClipPlanes, actual: 4))
        }
    }

    func testCodableRoundTripPreservesManualPayload() throws {
        let crop = try VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.2, 0.3),
                                     textureMax: SIMD3<Float>(0.7, 0.8, 0.9))
        let plane = try VolumeClipPlane(worldNormal: SIMD3<Float>(1, 2, 0),
                                        pointOnPlane: SIMD3<Float>(10, 20, 30))
        let state = try VolumeClippingState(cropBox: crop, clipPlanes: [plane])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VolumeClippingState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func testTextureCenteredPlaneRoundTripsThroughNonIdentityAffine() throws {
        let dataset = makeDataset(
            spacing: VolumeSpacing(x: 0.8, y: 1.2, z: 2.5),
            origin: SIMD3<Float>(12, -8, 30),
            direction: simd_float3x3(columns: (
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(1, 0, 0)
            ))
        )

        let plane = try VolumeClipPlane(textureCenteredNormal: SIMD3<Float>(0, 0, 1),
                                        offset: 0.25,
                                        dataset: dataset)
        let shaderPlane = try plane.textureCenteredPlane(for: dataset)

        XCTAssertEqual(shaderPlane.x, 0, accuracy: 1e-5)
        XCTAssertEqual(shaderPlane.y, 0, accuracy: 1e-5)
        XCTAssertEqual(shaderPlane.z, 1, accuracy: 1e-5)
        XCTAssertEqual(shaderPlane.w, -0.25, accuracy: 1e-5)
    }

    func testLegacySnapshotsAdaptToPublicModels() throws {
        let dataset = makeDataset()
        let crop = try ClipBoundsSnapshot(xMin: 0.2,
                                          xMax: 0.8,
                                          yMin: 0.1,
                                          yMax: 0.9,
                                          zMin: 0.3,
                                          zMax: 1.0).volumeCropBox()
        let plane = try XCTUnwrap(ClipPlaneSnapshot(preset: 1, offset: 0.1)
            .volumeClipPlane(for: dataset))
        let shaderPlane = try plane.textureCenteredPlane(for: dataset)

        assertVector(crop.textureMin, SIMD3<Float>(0.2, 0.1, 0.3))
        assertVector(crop.textureMax, SIMD3<Float>(0.8, 0.9, 1.0))
        XCTAssertEqual(shaderPlane.z, 1, accuracy: 1e-5)
        XCTAssertEqual(shaderPlane.w, -0.1, accuracy: 1e-5)
    }

    private func makeDataset(spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                             origin: SIMD3<Float> = .zero,
                             direction: simd_float3x3 = matrix_identity_float3x3) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 5, depth: 6)
        let values = [Int16](repeating: 0, count: dimensions.voxelCount)
        let imageData = ImageData3D(dimensions: dimensions,
                                    spacing: spacing,
                                    origin: origin,
                                    direction: direction,
                                    pixelFormat: .int16Signed,
                                    intensityRange: -1...1)
        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             imageData: imageData)
    }

    private func assertVector(_ actual: SIMD3<Float>,
                              _ expected: SIMD3<Float>,
                              accuracy: Float = 1e-6,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
