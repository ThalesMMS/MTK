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

    func test_orthographicProjection_preservesDollyAsZoom() throws {
        let far = VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0, 0, 4),
            target: .zero,
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 30,
            projectionType: .orthographic
        )
        var near = far
        near.position.z = 2

        let farProjection = try VolumeCameraMath.matrices(
            camera: far,
            viewportWidth: 800,
            viewportHeight: 600
        ).projection
        let nearProjection = try VolumeCameraMath.matrices(
            camera: near,
            viewportWidth: 800,
            viewportHeight: 600
        ).projection

        XCTAssertGreaterThan(nearProjection.columns.0.x, farProjection.columns.0.x)
        XCTAssertGreaterThan(nearProjection.columns.1.y, farProjection.columns.1.y)
    }

    func test_fittedDistance_keepsEveryBoundingBoxCornerInsidePortraitViewport() throws {
        let viewport = CGSize(width: 100, height: 400)
        let halfExtent: Float = 0.5
        let radius = simd_length(SIMD3<Float>(repeating: halfExtent))
        let distance = VolumeCameraMath.fittedDistance(
            radius: radius,
            fieldOfViewDegrees: 30,
            viewportSize: viewport
        )
        let corners = [Float(-1), 1].flatMap { x in
            [Float(-1), 1].flatMap { y in
                [Float(-1), 1].map { z in
                    SIMD3<Float>(x, y, z) * halfExtent
                }
            }
        }

        for projectionType in [ProjectionType.perspective, .orthographic] {
            let camera = VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, distance),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 30,
                projectionType: projectionType
            )
            let matrices = try VolumeCameraMath.matrices(
                camera: camera,
                viewportWidth: Float(viewport.width),
                viewportHeight: Float(viewport.height)
            )

            for corner in corners {
                let clip = matrices.projection * matrices.view * SIMD4<Float>(corner, 1)
                let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
                XCTAssertLessThan(abs(ndc.x), 1)
                XCTAssertLessThan(abs(ndc.y), 1)
            }
        }
    }

    func test_fittedDistance_keepsBoundingBoxInsideExtremelyNarrowViewport() throws {
        let viewport = CGSize(width: 1, height: 400)
        let halfExtent: Float = 0.5
        let radius = simd_length(SIMD3<Float>(repeating: 0.5))
        let distance = VolumeCameraMath.fittedDistance(
            radius: radius,
            fieldOfViewDegrees: 30,
            viewportSize: viewport
        )
        let camera = VolumeRenderRequest.Camera(
            position: SIMD3<Float>(0, 0, distance),
            target: .zero,
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 30,
            projectionType: .perspective
        )
        let matrices = try VolumeCameraMath.matrices(
            camera: camera,
            viewportWidth: Float(viewport.width),
            viewportHeight: Float(viewport.height)
        )

        let corners = [Float(-1), 1].flatMap { x in
            [Float(-1), 1].flatMap { y in
                [Float(-1), 1].map { z in
                    SIMD3<Float>(x, y, z) * halfExtent
                }
            }
        }

        for corner in corners {
            let clip = matrices.projection * matrices.view * SIMD4<Float>(corner, 1)
            XCTAssertLessThan(abs(clip.x / clip.w), 1)
        }
    }

    func test_fittedDistance_nonFiniteMargins_useFiniteFallback() {
        for margin in [Float.infinity, -.infinity, .nan] {
            let distance = VolumeCameraMath.fittedDistance(
                radius: 1,
                fieldOfViewDegrees: 30,
                viewportSize: CGSize(width: 800, height: 600),
                margin: margin
            )

            XCTAssertTrue(distance.isFinite)
        }
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
