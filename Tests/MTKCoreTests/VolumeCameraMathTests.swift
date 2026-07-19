import XCTest
import simd
@testable import MTKCore

final class VolumeCameraMathTests: XCTestCase {
    func test_matrices_supportPerspectiveAndOrthographicCameras() throws {
        let perspective = VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0.5, 0.5, 2.5),
            target: SIMD3<Float>(0.5, 0.5, 0.5),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 45,
            projectionType: .perspective
        )
        var orthographic = perspective
        orthographic.projectionType = .orthographic

        let perspectiveMatrices = try VolumeCameraMath.matrices(
            camera: perspective,
            viewportWidth: 800,
            viewportHeight: 600
        )
        let orthographicMatrices = try VolumeCameraMath.matrices(
            camera: orthographic,
            viewportWidth: 800,
            viewportHeight: 600
        )

        XCTAssertTrue(perspectiveMatrices.inverseViewProjection.isFinite)
        XCTAssertTrue(orthographicMatrices.inverseViewProjection.isFinite)
        XCTAssertNotEqual(perspectiveMatrices.projection, orthographicMatrices.projection)
    }

    func test_matrices_rejectDegenerateCamera() {
        let camera = VolumeRenderRequest.Camera(
            position: .zero,
            target: .zero,
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 45,
            projectionType: .perspective
        )

        XCTAssertThrowsError(
            try VolumeCameraMath.matrices(camera: camera, viewportWidth: 100, viewportHeight: 100)
        )
    }
}

private extension simd_float4x4 {
    var isFinite: Bool {
        columns.0.x.isFinite && columns.0.y.isFinite && columns.0.z.isFinite && columns.0.w.isFinite &&
            columns.1.x.isFinite && columns.1.y.isFinite && columns.1.z.isFinite && columns.1.w.isFinite &&
            columns.2.x.isFinite && columns.2.y.isFinite && columns.2.z.isFinite && columns.2.w.isFinite &&
            columns.3.x.isFinite && columns.3.y.isFinite && columns.3.z.isFinite && columns.3.w.isFinite
    }
}
