//
//  VolumetricMath.swift
//  MTKCore
//
//  Mathematical utilities for volumetric rendering and transformations.
//  Originally from MTK-Demo — Migrated to MTKCore for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import simd
import MetalKit

/// Mathematical utilities for volumetric rendering
public struct VolumetricMath {
    /// X-axis unit vector
    public static var X_AXIS: SIMD3<Float> {
        SIMD3<Float>(1, 0, 0)
    }

    /// Y-axis unit vector
    public static var Y_AXIS: SIMD3<Float> {
        SIMD3<Float>(0, 1, 0)
    }

    /// Z-axis unit vector
    public static var Z_AXIS: SIMD3<Float> {
        SIMD3<Float>(0, 0, 1)
    }

    /// Clamp a comparable value between min and max
    public static func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        Swift.max(min, Swift.min(value, max))
    }

    /// Smooth Hermite interpolation
    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = clamp((x - edge0) / (edge1 - edge0), min: 0.0, max: 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    /// Linear interpolation
    public static func mix<T: FloatingPoint>(_ x: T, _ y: T, _ a: T) -> T {
        x * (1 - a) + y * a
    }
}

// MARK: - Float Extensions
public extension Float {
    /// Convert degrees to radians
    var toRadians: Float {
        (self / 180.0) * Float.pi
    }

    /// Convert radians to degrees
    var toDegrees: Float {
        self * (180.0 / Float.pi)
    }

    /// Generate random float in [0, 1]
    static var randomZeroToOne: Float {
        Float.random(in: 0...1)
    }
}

// MARK: - Matrix Extensions
public extension matrix_float4x4 {
    /// Translate matrix by direction vector
    mutating func translate(direction: SIMD3<Float>) {
        self = self.translateMatrix(direction: direction)
    }

    /// Create translated matrix
    func translateMatrix(direction: SIMD3<Float>) -> matrix_float4x4 {
        var result = matrix_identity_float4x4

        let x: Float = direction.x
        let y: Float = direction.y
        let z: Float = direction.z

        result.columns = (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        )

        return matrix_multiply(self, result)
    }

    /// Scale matrix by axis factors
    mutating func scale(axis: SIMD3<Float>) {
        var result = matrix_identity_float4x4

        let x: Float = axis.x
        let y: Float = axis.y
        let z: Float = axis.z

        result.columns = (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        self = matrix_multiply(self, result)
    }

    /// Rotate matrix by angle around axis
    mutating func rotate(angle: Float, axis: SIMD3<Float>) {
        self = self.rotatingMatrix(angle: angle, axis: axis)
    }

    /// Create rotated matrix
    func rotatingMatrix(angle: Float, axis: float3) -> matrix_float4x4 {
        var result = matrix_identity_float4x4

        let x: Float = axis.x
        let y: Float = axis.y
        let z: Float = axis.z

        let c: Float = cos(angle)
        let s: Float = sin(angle)

        let mc: Float = (1 - c)

        let r1c1: Float = x * x * mc + c
        let r2c1: Float = x * y * mc + z * s
        let r3c1: Float = x * z * mc - y * s
        let r4c1: Float = 0.0

        let r1c2: Float = y * x * mc - z * s
        let r2c2: Float = y * y * mc + c
        let r3c2: Float = y * z * mc + x * s
        let r4c2: Float = 0.0

        let r1c3: Float = z * x * mc + y * s
        let r2c3: Float = z * y * mc - x * s
        let r3c3: Float = z * z * mc + c
        let r4c3: Float = 0.0

        let r1c4: Float = 0.0
        let r2c4: Float = 0.0
        let r3c4: Float = 0.0
        let r4c4: Float = 1.0

        result.columns = (
            SIMD4<Float>(r1c1, r2c1, r3c1, r4c1),
            SIMD4<Float>(r1c2, r2c2, r3c2, r4c2),
            SIMD4<Float>(r1c3, r2c3, r3c3, r4c3),
            SIMD4<Float>(r1c4, r2c4, r3c4, r4c4)
        )

        return matrix_multiply(self, result)
    }

    /// Create perspective projection matrix
    /// - Parameters:
    ///   - degreesFov: Field of view in degrees
    ///   - aspectRatio: Aspect ratio (width / height)
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: Perspective projection matrix
    static func perspective(degreesFov: Float,
                            aspectRatio: Float,
                            near: Float,
                            far: Float) -> matrix_float4x4 {
        let fov = degreesFov.toRadians

        let t: Float = tan(fov / 2)

        let x: Float = 1 / (aspectRatio * t)
        let y: Float = 1 / t
        let z: Float = -((far + near) / (far - near))
        let w: Float = -((2 * far * near) / (far - near))

        var result = matrix_identity_float4x4
        result.columns = (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, w, 0)
        )
        return result
    }
}
