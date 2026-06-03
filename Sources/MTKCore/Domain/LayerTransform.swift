//
//  LayerTransform.swift
//  MTKCore
//
//  Classification for externally supplied scalar layer registration transforms.
//

import simd

public struct LayerTransform: Sendable, Equatable {
    public enum Classification: String, Sendable, Equatable {
        case identity
        case translation
        case axisAlignedScale
        case translatedAxisAlignedScale
        case unsupportedAffine
        case nonAffine
    }

    public static let tolerance: Float = 1e-5

    public var baseWorldToLayerWorld: simd_float4x4

    public init(baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4) {
        self.baseWorldToLayerWorld = baseWorldToLayerWorld
    }

    public var classification: Classification {
        Self.classification(for: baseWorldToLayerWorld)
    }

    public var supportsCPUResampling: Bool {
        switch classification {
        case .identity, .translation, .axisAlignedScale, .translatedAxisAlignedScale:
            return true
        case .unsupportedAffine, .nonAffine:
            return false
        }
    }

    public var isApproximatelyIdentity: Bool {
        classification == .identity
    }

    public static func classification(for matrix: simd_float4x4) -> Classification {
        guard matrix.isFinite else { return .nonAffine }
        guard matrix.isAffine(tolerance: tolerance) else { return .nonAffine }
        guard !matrix.isApproximatelyEqual(to: matrix_identity_float4x4, tolerance: tolerance) else {
            return .identity
        }
        guard matrix.hasOnlyAxisAlignedScaleAndTranslation(tolerance: tolerance),
              matrix.hasPositiveFiniteScale(tolerance: tolerance) else {
            return .unsupportedAffine
        }

        let hasTranslation = simd_length(matrix.translation) > tolerance
        let hasScale = matrix.hasNonIdentityScale(tolerance: tolerance)
        switch (hasTranslation, hasScale) {
        case (true, true):
            return .translatedAxisAlignedScale
        case (true, false):
            return .translation
        case (false, true):
            return .axisAlignedScale
        case (false, false):
            return .identity
        }
    }
}

public extension simd_float4x4 {
    var mtkLayerTransformClassification: LayerTransform.Classification {
        LayerTransform.classification(for: self)
    }

    var mtkSupportsLayerCPUResampling: Bool {
        LayerTransform(baseWorldToLayerWorld: self).supportsCPUResampling
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    var isFinite: Bool {
        columns.0.isFinite &&
            columns.1.isFinite &&
            columns.2.isFinite &&
            columns.3.isFinite
    }

    func isAffine(tolerance: Float) -> Bool {
        abs(columns.0.w) <= tolerance &&
            abs(columns.1.w) <= tolerance &&
            abs(columns.2.w) <= tolerance &&
            abs(columns.3.w - 1) <= tolerance
    }

    func hasOnlyAxisAlignedScaleAndTranslation(tolerance: Float) -> Bool {
        abs(columns.0.y) <= tolerance &&
            abs(columns.0.z) <= tolerance &&
            abs(columns.1.x) <= tolerance &&
            abs(columns.1.z) <= tolerance &&
            abs(columns.2.x) <= tolerance &&
            abs(columns.2.y) <= tolerance
    }

    func hasPositiveFiniteScale(tolerance: Float) -> Bool {
        columns.0.x.isFinite && columns.0.x > tolerance &&
            columns.1.y.isFinite && columns.1.y > tolerance &&
            columns.2.z.isFinite && columns.2.z > tolerance
    }

    func hasNonIdentityScale(tolerance: Float) -> Bool {
        abs(columns.0.x - 1) > tolerance ||
            abs(columns.1.y - 1) > tolerance ||
            abs(columns.2.z - 1) > tolerance
    }

    func isApproximatelyEqual(to other: simd_float4x4,
                              tolerance: Float) -> Bool {
        columns.0.isApproximatelyEqual(to: other.columns.0, tolerance: tolerance) &&
            columns.1.isApproximatelyEqual(to: other.columns.1, tolerance: tolerance) &&
            columns.2.isApproximatelyEqual(to: other.columns.2, tolerance: tolerance) &&
            columns.3.isApproximatelyEqual(to: other.columns.3, tolerance: tolerance)
    }
}

private extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }

    func isApproximatelyEqual(to other: SIMD4<Float>,
                              tolerance: Float) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(z - other.z) <= tolerance &&
            abs(w - other.w) <= tolerance
    }
}
