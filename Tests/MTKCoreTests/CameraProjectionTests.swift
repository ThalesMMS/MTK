import Foundation
import simd
import XCTest

@testable import MTKCore

final class CameraProjectionTests: XCTestCase {
    func testOrthographicInverseViewProjectionMatchesExpectedMatrix() async throws {
        let adapter = MetalVolumeRenderingAdapter()
        let camera = VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0, 0, 5),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 60,
            parallelProjection: true,
            parallelScale: 2
        )

        let viewport = (width: 800, height: 400)
        let invViewProj = await adapter.debugInverseViewProjectionMatrix(camera: camera,
                                                                         viewportSize: viewport,
                                                                         dataset: nil)
        let actualViewProj = simd_inverse(invViewProj)

        let view = simd_float4x4(lookAt: camera.position,
                                 target: camera.target,
                                 up: camera.up)
        let aspect = Float(viewport.width) / Float(viewport.height)

        let center = SIMD3<Float>(repeating: 0.5)
        let distanceToCenter = simd_length(camera.position - center)
        let farPadding = max(1.0, distanceToCenter * 0.1 + 1.0)
        let nearZ: Float = 0.01
        let farZ = max(distanceToCenter + farPadding, nearZ + 100.0)

        let expectedProjection = simd_float4x4(
            orthographicWithParallelScale: camera.parallelScale,
            aspect: aspect,
            nearZ: nearZ,
            farZ: farZ
        )
        let expectedViewProj = expectedProjection * view

        XCTAssertTrue(matricesAlmostEqual(actualViewProj, expectedViewProj, tolerance: 1e-4))
    }

    func testMprParallelScaleConfigurationUsesBounds() {
        let bounds: [Float] = [0, 100, 0, 200, 0, 50]
        let config = MPRCameraConfiguration.configure(mode: .axial, bounds: bounds)
        XCTAssertEqual(config.parallelScale, 100, accuracy: 1e-5)
        XCTAssertEqual(config.viewUp, SIMD3<Float>(0, 1, 0))

        let sagittal = MPRCameraConfiguration.configure(mode: .sagittal, bounds: bounds)
        XCTAssertEqual(sagittal.parallelScale, 25, accuracy: 1e-5)
        XCTAssertEqual(sagittal.viewUp, SIMD3<Float>(0, 0, 1))
    }

    func testWorldBoundsUsesSpacingAndOrigin() {
        let dataset = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 3, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 2, z: 3),
            pixelFormat: .int16Unsigned,
            orientation: VolumeOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 1, 0),
                origin: SIMD3<Float>(10, 20, 30)
            )
        )

        let bounds = MPRCameraConfiguration.worldBounds(for: dataset)
        XCTAssertEqual(bounds[0], 10, accuracy: 1e-4) // xMin
        XCTAssertEqual(bounds[1], 12, accuracy: 1e-4) // xMax (2 units wide)
        XCTAssertEqual(bounds[2], 20, accuracy: 1e-4) // yMin
        XCTAssertEqual(bounds[3], 22, accuracy: 1e-4) // yMax (height 2 -> extent 2)
        XCTAssertEqual(bounds[4], 30, accuracy: 1e-4) // zMin
        XCTAssertEqual(bounds[5], 33, accuracy: 1e-4) // zMax (depth 2 -> extent 3)
    }

    // MARK: - Helpers

    private func matricesAlmostEqual(_ lhs: simd_float4x4,
                                     _ rhs: simd_float4x4,
                                     tolerance: Float) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 {
                if abs(lhs[column][row] - rhs[column][row]) > tolerance {
                    return false
                }
            }
        }
        return true
    }
}
