//
//  VolumeCameraMath.swift
//  MTKCore
//
//  Shared camera and projection matrices for rendering and picking.
//

import Foundation
import simd

package enum VolumeCameraMath {
    package enum Error: Swift.Error {
        case degenerateCamera
    }

    package struct Matrices {
        package let view: simd_float4x4
        package let projection: simd_float4x4

        package var inverseViewProjection: simd_float4x4 {
            simd_inverse(projection * view)
        }
    }

    /// Returns a bounding-sphere camera distance that fits inside the tighter
    /// horizontal or vertical field of view, including a small display margin.
    package static func fittedDistance(
        radius: Float,
        fieldOfViewDegrees: Float,
        viewportSize: CGSize,
        margin: Float = 1.08
    ) -> Float {
        let safeRadius = radius.isFinite && radius > 0 ? radius : 1e-3
        let aspect: Float
        if viewportSize.width.isFinite, viewportSize.height.isFinite,
           viewportSize.width > 0, viewportSize.height > 0 {
            aspect = max(Float(viewportSize.width / viewportSize.height), 1e-3)
        } else {
            aspect = 1
        }
        let fieldOfView = fieldOfViewDegrees.isFinite
            ? min(max(fieldOfViewDegrees, 5), 90)
            : 30
        let verticalHalfFOV = fieldOfView * .pi / 360
        let horizontalHalfFOV = atan(tan(verticalHalfFOV) * aspect)
        let limitingHalfFOV = min(verticalHalfFOV, horizontalHalfFOV)
        let safeMargin = margin.isFinite ? max(margin, 1) : 1.08
        let fittedDistance = safeRadius / sin(limitingHalfFOV) * safeMargin
        return max(max(fittedDistance, safeRadius * 1.25), 1.5)
    }

    package static func matrices(
        camera: VolumeRenderRequest.Camera,
        viewportWidth: Float,
        viewportHeight: Float
    ) throws -> Matrices {
        let view = try makeLookAt(
            eye: camera.position,
            target: camera.target,
            up: camera.up
        )
        let aspect = max(viewportWidth / viewportHeight, 1e-3)
        let distanceToCenter = simd_length(camera.position - camera.target)
        let farPadding = distanceToCenter * 0.1 + 1
        let nearZ: Float = 0.01
        let farZ = max(distanceToCenter + farPadding, nearZ + 100)

        let projection: simd_float4x4
        if camera.projectionType == .orthographic {
            let fovY = max(camera.fieldOfView * .pi / 180, 0.01)
            let viewHeight = max(2 * distanceToCenter * tan(fovY * 0.5), 0.01)
            projection = makeOrthographic(
                width: viewHeight * aspect,
                height: viewHeight,
                nearZ: nearZ,
                farZ: farZ
            )
        } else {
            projection = makePerspective(
                fovY: max(camera.fieldOfView * .pi / 180, 0.01),
                aspect: aspect,
                nearZ: nearZ,
                farZ: farZ
            )
        }
        return Matrices(view: view, projection: projection)
    }

    private static func makeLookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) throws -> simd_float4x4 {
        let zAxis = try normalized(eye - target)
        let xAxis = try normalized(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        guard isFinite(yAxis) else {
            throw Error.degenerateCamera
        }
        let translation = SIMD3<Float>(
            -simd_dot(xAxis, eye),
            -simd_dot(yAxis, eye),
            -simd_dot(zAxis, eye)
        )
        return simd_float4x4(columns: (
            SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
            SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
            SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    private static func makePerspective(
        fovY: Float,
        aspect: Float,
        nearZ: Float,
        farZ: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / max(aspect, 1e-3)
        let z = farZ / (nearZ - farZ)
        let wz = (farZ * nearZ) / (nearZ - farZ)
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, wz, 0)
        ))
    }

    private static func makeOrthographic(
        width: Float,
        height: Float,
        nearZ: Float,
        farZ: Float
    ) -> simd_float4x4 {
        let range = nearZ - farZ
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1 / range, 0),
            SIMD4<Float>(0, 0, nearZ / range, 1)
        ))
    }

    private static func normalized(_ value: SIMD3<Float>) throws -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > Float.ulpOfOne, length.isFinite else {
            throw Error.degenerateCamera
        }
        return value / length
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
