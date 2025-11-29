//
//  DICOMGeometryTests.swift
//  MTKCoreTests
//
//  Unit tests for DICOMGeometry world↔texture transformations.
//  Validates SCTC (Stabilized Coordinates to Texture Coordinates) matrix support.
//

import XCTest
import simd
@testable import MTKCore

final class DICOMGeometryTests: XCTestCase {

    // MARK: - Test world→texture→world round trip with canonical orientation

    func testWorldToTextureRoundTripCanonical() {
        // Create a simple canonical geometry (aligned with axes)
        let geometry = DICOMGeometry(
            cols: 256,
            rows: 256,
            slices: 128,
            spacingX: 1.0,
            spacingY: 1.0,
            spacingZ: 2.0,
            iopRow: simd_float3(1, 0, 0),
            iopCol: simd_float3(0, 1, 0),
            ipp0: simd_float3(0, 0, 0)
        )

        // Test points in world space (mm, LPS)
        let worldPoints: [simd_float3] = [
            simd_float3(0, 0, 0),           // Origin
            simd_float3(128, 128, 128),     // Middle of volume
            simd_float3(255, 255, 254),     // Near corner
            simd_float3(10.5, 20.3, 40.8),  // Arbitrary point
        ]

        for worldPoint in worldPoints {
            // Forward: world → texture
            let texPoint = (geometry.worldToTextureMatrix * simd_float4(worldPoint, 1.0))
            let texCoord = simd_float3(texPoint.x / texPoint.w,
                                       texPoint.y / texPoint.w,
                                       texPoint.z / texPoint.w)

            // Backward: texture → world
            let worldPointBack = (geometry.textureToWorldMatrix * simd_float4(texCoord, 1.0))
            let worldCoord = simd_float3(worldPointBack.x / worldPointBack.w,
                                         worldPointBack.y / worldPointBack.w,
                                         worldPointBack.z / worldPointBack.w)

            // Verify round trip (should match original within floating-point tolerance)
            let tolerance: Float = 1e-4
            XCTAssertEqual(worldPoint.x, worldCoord.x, accuracy: tolerance,
                          "X coordinate round trip failed for point \(worldPoint)")
            XCTAssertEqual(worldPoint.y, worldCoord.y, accuracy: tolerance,
                          "Y coordinate round trip failed for point \(worldPoint)")
            XCTAssertEqual(worldPoint.z, worldCoord.z, accuracy: tolerance,
                          "Z coordinate round trip failed for point \(worldPoint)")
        }
    }

    // MARK: - Test world→texture→world round trip with oblique orientation

    func testWorldToTextureRoundTripOblique() {
        // Create geometry with oblique orientation (rotated)
        let geometry = DICOMGeometry(
            cols: 512,
            rows: 512,
            slices: 256,
            spacingX: 0.5,
            spacingY: 0.5,
            spacingZ: 1.0,
            iopRow: simd_normalize(simd_float3(1, 1, 0)),      // 45° rotation
            iopCol: simd_normalize(simd_float3(-1, 1, 0)),     // Perpendicular
            ipp0: simd_float3(-100, -100, -50)
        )

        // Test points in world space
        let worldPoints: [simd_float3] = [
            simd_float3(-100, -100, -50),   // Origin
            simd_float3(0, 0, 0),           // Center region
            simd_float3(50, 50, 100),       // Positive quadrant
            simd_float3(-50.5, 75.3, -25.8), // Arbitrary
        ]

        for worldPoint in worldPoints {
            // Forward: world → texture
            let texPoint = (geometry.worldToTextureMatrix * simd_float4(worldPoint, 1.0))
            let texCoord = simd_float3(texPoint.x / texPoint.w,
                                       texPoint.y / texPoint.w,
                                       texPoint.z / texPoint.w)

            // Backward: texture → world
            let worldPointBack = (geometry.textureToWorldMatrix * simd_float4(texCoord, 1.0))
            let worldCoord = simd_float3(worldPointBack.x / worldPointBack.w,
                                         worldPointBack.y / worldPointBack.w,
                                         worldPointBack.z / worldPointBack.w)

            // Verify round trip
            let tolerance: Float = 1e-3
            XCTAssertEqual(worldPoint.x, worldCoord.x, accuracy: tolerance,
                          "X coordinate round trip failed for oblique geometry at \(worldPoint)")
            XCTAssertEqual(worldPoint.y, worldCoord.y, accuracy: tolerance,
                          "Y coordinate round trip failed for oblique geometry at \(worldPoint)")
            XCTAssertEqual(worldPoint.z, worldCoord.z, accuracy: tolerance,
                          "Z coordinate round trip failed for oblique geometry at \(worldPoint)")
        }
    }

    // MARK: - Test texture coordinate bounds [0,1]^3

    func testTextureBoundsForVolumeBoundingBox() {
        // Create geometry
        let geometry = DICOMGeometry(
            cols: 128,
            rows: 256,
            slices: 64,
            spacingX: 2.0,
            spacingY: 1.0,
            spacingZ: 3.0,
            iopRow: simd_float3(1, 0, 0),
            iopCol: simd_float3(0, 1, 0),
            ipp0: simd_float3(10, 20, 30)
        )

        // Volume bounding box corners in voxel space: (0,0,0) to (cols-1, rows-1, slices-1)
        // Transform to world space
        let corners: [(voxel: simd_float3, expectedTex: simd_float3)] = [
            (simd_float3(0, 0, 0), simd_float3(0.5/128, 0.5/256, 0.5/64)),  // Min corner
            (simd_float3(127, 255, 63), simd_float3(127.5/128, 255.5/256, 63.5/64)),  // Max corner
        ]

        for corner in corners {
            // Convert voxel to world
            let voxel4 = simd_float4(corner.voxel, 1.0)
            let world4 = geometry.voxelToWorld * voxel4
            let worldCoord = world4.xyz / world4.w

            // Convert world to texture
            let tex4 = geometry.worldToTextureMatrix * simd_float4(worldCoord, 1.0)
            let texCoord = tex4.xyz / tex4.w

            // Verify texture coordinates are in [0,1] range
            XCTAssertGreaterThanOrEqual(texCoord.x, 0.0, "Texture X coordinate out of bounds")
            XCTAssertLessThanOrEqual(texCoord.x, 1.0, "Texture X coordinate out of bounds")
            XCTAssertGreaterThanOrEqual(texCoord.y, 0.0, "Texture Y coordinate out of bounds")
            XCTAssertLessThanOrEqual(texCoord.y, 1.0, "Texture Y coordinate out of bounds")
            XCTAssertGreaterThanOrEqual(texCoord.z, 0.0, "Texture Z coordinate out of bounds")
            XCTAssertLessThanOrEqual(texCoord.z, 1.0, "Texture Z coordinate out of bounds")

            // Verify expected values
            let tolerance: Float = 1e-5
            XCTAssertEqual(texCoord.x, corner.expectedTex.x, accuracy: tolerance,
                          "Texture X coordinate mismatch for voxel \(corner.voxel)")
            XCTAssertEqual(texCoord.y, corner.expectedTex.y, accuracy: tolerance,
                          "Texture Y coordinate mismatch for voxel \(corner.voxel)")
            XCTAssertEqual(texCoord.z, corner.expectedTex.z, accuracy: tolerance,
                          "Texture Z coordinate mismatch for voxel \(corner.voxel)")
        }
    }

    // MARK: - Test SCTCMatrix alias

    func testSCTCMatrixAlias() {
        let geometry = DICOMGeometry(
            cols: 64,
            rows: 64,
            slices: 64,
            spacingX: 1.0,
            spacingY: 1.0,
            spacingZ: 1.0,
            iopRow: simd_float3(1, 0, 0),
            iopCol: simd_float3(0, 1, 0),
            ipp0: simd_float3(0, 0, 0)
        )

        // Verify SCTCMatrix is the same as worldToTextureMatrix
        let sctc = geometry.SCTCMatrix
        let worldToTex = geometry.worldToTextureMatrix

        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(sctc[col][row], worldToTex[col][row],
                              "SCTCMatrix should equal worldToTextureMatrix")
            }
        }
    }

    // MARK: - Test matrix inverse property

    func testTextureToWorldIsInverseOfWorldToTexture() {
        let geometry = DICOMGeometry(
            cols: 256,
            rows: 256,
            slices: 128,
            spacingX: 0.75,
            spacingY: 0.75,
            spacingZ: 1.5,
            iopRow: simd_normalize(simd_float3(0.9, 0.1, 0)),
            iopCol: simd_normalize(simd_float3(-0.1, 0.9, 0)),
            ipp0: simd_float3(-50, -60, -70)
        )

        // Multiply matrices: worldToTexture * textureToWorld should be identity
        let product = geometry.worldToTextureMatrix * geometry.textureToWorldMatrix
        let identity = matrix_identity_float4x4

        let tolerance: Float = 1e-4
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(product[col][row], identity[col][row], accuracy: tolerance,
                              "Product of worldToTexture * textureToWorld should be identity at [\(row),\(col)]")
            }
        }
    }

    // MARK: - Test VolumeDataset integration

    func testVolumeDatasetDICOMGeometryConversion() {
        // Create a VolumeDataset
        let dataset = VolumeDataset(
            data: Data(count: 128 * 128 * 64 * 2),
            dimensions: VolumeDimensions(width: 128, height: 128, depth: 64),
            spacing: VolumeSpacing(x: 1.5, y: 1.5, z: 3.0),
            pixelFormat: .int16Signed,
            orientation: VolumeOrientation(
                row: simd_float3(1, 0, 0),
                column: simd_float3(0, 1, 0),
                origin: simd_float3(-100, -100, -50)
            )
        )

        // Get DICOMGeometry from dataset
        let geometry = dataset.dicomGeometry

        // Verify dimensions
        XCTAssertEqual(geometry.cols, 128, "Columns should match dataset width")
        XCTAssertEqual(geometry.rows, 128, "Rows should match dataset height")
        XCTAssertEqual(geometry.slices, 64, "Slices should match dataset depth")

        // Verify spacing
        XCTAssertEqual(geometry.spacingX, 1.5, accuracy: 1e-5, "Spacing X should match")
        XCTAssertEqual(geometry.spacingY, 1.5, accuracy: 1e-5, "Spacing Y should match")
        XCTAssertEqual(geometry.spacingZ, 3.0, accuracy: 1e-5, "Spacing Z should match")

        // Verify orientation
        XCTAssertEqual(geometry.iopRow, dataset.orientation.row, "Row orientation should match")
        XCTAssertEqual(geometry.iopCol, dataset.orientation.column, "Column orientation should match")
        XCTAssertEqual(geometry.ipp0, dataset.orientation.origin, "Origin should match")

        // Test that world→texture transform works
        let worldPoint = simd_float3(-100, -100, -50)  // Origin
        let tex4 = geometry.worldToTextureMatrix * simd_float4(worldPoint, 1.0)
        let texCoord = tex4.xyz / tex4.w

        // Origin in world should map to near (0,0,0) in texture space (with voxel center offset)
        XCTAssertGreaterThanOrEqual(texCoord.x, 0.0, "Origin should map to positive texture coords")
        XCTAssertLessThan(texCoord.x, 0.1, "Origin should map near texture origin")
    }
}

// MARK: - Helper Extensions

fileprivate extension simd_float4 {
    var xyz: simd_float3 {
        simd_float3(x, y, z)
    }
}
