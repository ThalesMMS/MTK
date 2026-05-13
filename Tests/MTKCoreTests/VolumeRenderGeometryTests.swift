import Foundation
import XCTest
import simd

@testable import MTKCore

final class VolumeRenderGeometryTests: XCTestCase {
    func testCanonicalVolumeProducesIdentityModelMatrix() {
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
                                  spacing: VolumeSpacing(x: 1, y: 1, z: 1))

        let geometry = VolumeRenderGeometry.make(for: dataset)

        assertVector(geometry.physicalExtents, SIMD3<Float>(7, 7, 7))
        assertVector(geometry.normalizedExtents, SIMD3<Float>(1, 1, 1))
        assertMatrix(geometry.modelMatrix, matrix_identity_float4x4)
        assertMatrix(geometry.inverseModelMatrix, matrix_identity_float4x4)
        XCTAssertEqual(geometry.boundingRadius, sqrt(3) * 0.5, accuracy: 1e-5)
    }

    func testAnisotropicVolumeNormalizesPhysicalExtents() {
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
                                  spacing: VolumeSpacing(x: 1, y: 1, z: 2))

        let geometry = VolumeRenderGeometry.make(for: dataset)

        assertVector(geometry.physicalExtents, SIMD3<Float>(4, 4, 8))
        assertVector(geometry.normalizedExtents, SIMD3<Float>(0.5, 0.5, 1))
        assertVector(SIMD3<Float>(geometry.modelMatrix.columns.0.x,
                                  geometry.modelMatrix.columns.1.y,
                                  geometry.modelMatrix.columns.2.z),
                     SIMD3<Float>(0.5, 0.5, 1))

        let center = geometry.worldPosition(forTextureCoordinate: SIMD3<Float>(repeating: 0.5))
        let upperZ = geometry.worldPosition(forTextureCoordinate: SIMD3<Float>(0.5, 0.5, 1))
        assertVector(center, .zero)
        assertVector(upperZ, SIMD3<Float>(0, 0, 0.5))
    }

    func testObliqueVolumeUsesDirectionBasisAndRoundTrips() {
        let direction = simd_float3x3(columns: (
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 0, 0)
        ))
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 3, height: 4, depth: 5),
                                  spacing: VolumeSpacing(x: 2, y: 3, z: 4),
                                  direction: direction)

        let geometry = VolumeRenderGeometry.make(for: dataset)

        assertVector(geometry.physicalExtents, SIMD3<Float>(4, 9, 16))
        assertVector(geometry.normalizedExtents, SIMD3<Float>(0.25, 0.5625, 1))
        assertVector(geometry.rowDirection, SIMD3<Float>(0, 1, 0))
        assertVector(geometry.columnDirection, SIMD3<Float>(0, 0, 1))
        assertVector(geometry.sliceDirection, SIMD3<Float>(1, 0, 0))

        let texture = SIMD3<Float>(0.25, 0.75, 0.5)
        let world = geometry.worldPosition(forTextureCoordinate: texture)
        let roundTrip = geometry.textureCoordinate(forWorldPosition: world)
        assertVector(roundTrip, texture)
    }

    private func makeDataset(dimensions: VolumeDimensions,
                             spacing: VolumeSpacing,
                             direction: simd_float3x3 = matrix_identity_float3x3) -> VolumeDataset {
        let values = [Int16](repeating: 0, count: dimensions.voxelCount)
        let imageData = ImageData3D(dimensions: dimensions,
                                    spacing: spacing,
                                    origin: .zero,
                                    direction: direction,
                                    pixelFormat: .int16Signed,
                                    intensityRange: -1...1)
        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             imageData: imageData)
    }

    private func assertMatrix(_ actual: simd_float4x4,
                              _ expected: simd_float4x4,
                              accuracy: Float = 1e-5,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(actual[column][row],
                               expected[column][row],
                               accuracy: accuracy,
                               file: file,
                               line: line)
            }
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
}
