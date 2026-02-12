//  CameraPoseProjectionTests.swift
//  MTK
//  Tests orthographic and perspective projection matrix generation.
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
import simd
@testable import MTKSceneKit
@testable import MTKCore

final class CameraPoseProjectionTests: XCTestCase {

    // MARK: - Orthographic Projection Matrix Tests

    func testOrthographicProjectionMatrixBasicProperties() {
        let pose = CameraPose.default
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Verify matrix is non-zero
        XCTAssertNotEqual(matrix, simd_float4x4(0))

        // Verify orthographic scaling in first two diagonal elements
        // For orthographic: m[0][0] = 2/width, m[1][1] = 2/height
        XCTAssertEqual(matrix[0][0], 2.0 / 2.0, accuracy: 0.001)
        XCTAssertEqual(matrix[1][1], 2.0 / 2.0, accuracy: 0.001)

        // Verify homogeneous coordinate (should be 1 for orthographic)
        XCTAssertEqual(matrix[3][3], 1.0, accuracy: 0.001)
    }

    func testOrthographicProjectionMatrixScaling() {
        let pose = CameraPose.default

        // Test with different view dimensions
        let matrix1 = pose.toOrthographicProjectionMatrix(
            viewWidth: 4.0,
            viewHeight: 2.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Verify scaling factors
        XCTAssertEqual(matrix1[0][0], 2.0 / 4.0, accuracy: 0.001)
        XCTAssertEqual(matrix1[1][1], 2.0 / 2.0, accuracy: 0.001)

        // Test with narrow viewport
        let matrix2 = pose.toOrthographicProjectionMatrix(
            viewWidth: 1.0,
            viewHeight: 3.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        XCTAssertEqual(matrix2[0][0], 2.0 / 1.0, accuracy: 0.001)
        XCTAssertEqual(matrix2[1][1], 2.0 / 3.0, accuracy: 0.001)
    }

    func testOrthographicProjectionMatrixDepthMapping() {
        let pose = CameraPose.default
        let near: Float = 0.1
        let far: Float = 100.0
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: near,
            farPlane: far
        )

        let range = far - near

        // Verify depth scaling: m[2][2] = -2/range
        XCTAssertEqual(matrix[2][2], -2.0 / range, accuracy: 0.001)

        // Verify depth translation: m[2][3] = -(far + near)/range
        XCTAssertEqual(matrix[3][2], -(far + near) / range, accuracy: 0.001)
    }

    func testOrthographicProjectionMatrixDifferentClippingPlanes() {
        let pose = CameraPose.default

        // Test with tight clipping planes
        let matrix1 = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: 0.5,
            farPlane: 10.0
        )

        let range1: Float = 10.0 - 0.5
        XCTAssertEqual(matrix1[2][2], -2.0 / range1, accuracy: 0.001)

        // Test with wide clipping planes
        let matrix2 = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: 0.01,
            farPlane: 1000.0
        )

        let range2: Float = 1000.0 - 0.01
        XCTAssertEqual(matrix2[2][2], -2.0 / range2, accuracy: 0.001)
    }

    // MARK: - Perspective vs Orthographic Comparison

    func testPerspectiveVsOrthographicMatricesDiffer() {
        let pose = CameraPose.default
        let aspectRatio: Float = 1.0

        let perspectiveMatrix = pose.toProjectionMatrix(
            aspectRatio: aspectRatio,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        let orthographicMatrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Matrices should be different
        XCTAssertNotEqual(perspectiveMatrix, orthographicMatrix)

        // Perspective has non-zero m[2][3] (projective term)
        XCTAssertEqual(perspectiveMatrix[2][3], -1.0, accuracy: 0.001)

        // Orthographic has zero m[2][3]
        XCTAssertEqual(orthographicMatrix[2][3], 0.0, accuracy: 0.001)

        // Perspective has m[3][3] = 0 (homogeneous division)
        XCTAssertEqual(perspectiveMatrix[3][3], 0.0, accuracy: 0.001)

        // Orthographic has m[3][3] = 1 (no homogeneous division)
        XCTAssertEqual(orthographicMatrix[3][3], 1.0, accuracy: 0.001)
    }

    // MARK: - Projection Type Property Tests

    func testProjectionTypeDefaultsToPerspective() {
        let pose = CameraPose.default
        XCTAssertEqual(pose.projectionType, .perspective)
    }

    func testProjectionTypeOrthographic() {
        let pose = CameraPose(
            position: SIMD3<Float>(0, 0, 2),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 60,
            projectionType: .orthographic
        )

        XCTAssertEqual(pose.projectionType, .orthographic)
    }

    func testProjectionTypeCodable() throws {
        let originalPose = CameraPose(
            position: SIMD3<Float>(1, 2, 3),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 45,
            projectionType: .orthographic
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalPose)

        // Decode
        let decoder = JSONDecoder()
        let decodedPose = try decoder.decode(CameraPose.self, from: data)

        // Verify projection type is preserved
        XCTAssertEqual(decodedPose.projectionType, .orthographic)
        XCTAssertEqual(decodedPose.position, originalPose.position)
        XCTAssertEqual(decodedPose.fieldOfView, originalPose.fieldOfView)
    }

    // MARK: - Edge Case Tests

    func testOrthographicProjectionWithSmallViewDimensions() {
        let pose = CameraPose.default

        // Very small viewport
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 0.01,
            viewHeight: 0.01,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Should produce large scaling factors
        XCTAssertEqual(matrix[0][0], 2.0 / 0.01, accuracy: 0.1)
        XCTAssertEqual(matrix[1][1], 2.0 / 0.01, accuracy: 0.1)
    }

    func testOrthographicProjectionWithLargeViewDimensions() {
        let pose = CameraPose.default

        // Very large viewport
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 1000.0,
            viewHeight: 1000.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Should produce small scaling factors
        XCTAssertEqual(matrix[0][0], 2.0 / 1000.0, accuracy: 0.0001)
        XCTAssertEqual(matrix[1][1], 2.0 / 1000.0, accuracy: 0.0001)
    }

    func testOrthographicProjectionWithAsymmetricDimensions() {
        let pose = CameraPose.default

        // Wide aspect ratio
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 16.0,
            viewHeight: 9.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        XCTAssertEqual(matrix[0][0], 2.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(matrix[1][1], 2.0 / 9.0, accuracy: 0.001)

        // Verify aspect ratio independence (width and height scaled independently)
        XCTAssertNotEqual(matrix[0][0], matrix[1][1])
    }

    // MARK: - Matrix Transform Verification

    func testOrthographicProjectionPreservesParallelLines() {
        let pose = CameraPose.default
        let matrix = pose.toOrthographicProjectionMatrix(
            viewWidth: 2.0,
            viewHeight: 2.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Two parallel points at different depths
        let point1 = simd_float4(0, 0, -5, 1)
        let point2 = simd_float4(0, 0, -10, 1)

        let projected1 = matrix * point1
        let projected2 = matrix * point2

        // In orthographic projection, w should remain 1 (no perspective divide)
        XCTAssertEqual(projected1.w, 1.0, accuracy: 0.001)
        XCTAssertEqual(projected2.w, 1.0, accuracy: 0.001)

        // X and Y should be the same (parallel lines stay parallel)
        XCTAssertEqual(projected1.x, projected2.x, accuracy: 0.001)
        XCTAssertEqual(projected1.y, projected2.y, accuracy: 0.001)

        // Only Z should differ
        XCTAssertNotEqual(projected1.z, projected2.z)
    }

    func testPerspectiveProjectionDoesNotPreserveParallelLines() {
        let pose = CameraPose.default
        let matrix = pose.toProjectionMatrix(
            aspectRatio: 1.0,
            nearPlane: 0.1,
            farPlane: 100.0
        )

        // Two parallel points at different depths
        let point1 = simd_float4(1, 1, -5, 1)
        let point2 = simd_float4(1, 1, -10, 1)

        let projected1 = matrix * point1
        let projected2 = matrix * point2

        // In perspective projection, w varies with depth
        XCTAssertNotEqual(projected1.w, 1.0)
        XCTAssertNotEqual(projected2.w, 1.0)
        XCTAssertNotEqual(projected1.w, projected2.w)

        // After perspective divide, X and Y would differ (parallel lines converge)
        let ndc1 = simd_float2(projected1.x / projected1.w, projected1.y / projected1.w)
        let ndc2 = simd_float2(projected2.x / projected2.w, projected2.y / projected2.w)

        XCTAssertNotEqual(ndc1.x, ndc2.x, accuracy: 0.001)
        XCTAssertNotEqual(ndc1.y, ndc2.y, accuracy: 0.001)
    }

    // MARK: - Preset View Tests

    func testPresetViewsDefaultToPerspective() {
        XCTAssertEqual(CameraPose.default.projectionType, .perspective)
        XCTAssertEqual(CameraPose.frontView().projectionType, .perspective)
        XCTAssertEqual(CameraPose.sideView().projectionType, .perspective)
        XCTAssertEqual(CameraPose.topView().projectionType, .perspective)
    }
}
