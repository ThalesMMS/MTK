//
//  MPRDisplayOrientation.swift
//  MTKCore
//
//  Quarter-turn display rotations for MPR presentation.
//

import Foundation
import simd

public enum MPRDisplayOrientation: Int, CaseIterable, Sendable, Equatable {
    case standard = 0
    case rotated90CW = 1
    case rotated180 = 2
    case rotated90CCW = 3

    public var transformComponents: (flipH: Bool, flipV: Bool, transposeUV: Bool) {
        switch self {
        case .standard:
            return (false, false, false)
        case .rotated90CW:
            return (true, false, true)
        case .rotated180:
            return (true, true, false)
        case .rotated90CCW:
            return (false, true, true)
        }
    }

    public func apply(to textureUV: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .standard:
            return textureUV
        case .rotated90CW:
            return SIMD2<Float>(1 - textureUV.y, textureUV.x)
        case .rotated180:
            return SIMD2<Float>(1 - textureUV.x, 1 - textureUV.y)
        case .rotated90CCW:
            return SIMD2<Float>(textureUV.y, 1 - textureUV.x)
        }
    }

    public func inverseApply(to screenXY: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .standard:
            return screenXY
        case .rotated90CW:
            return SIMD2<Float>(screenXY.y, 1 - screenXY.x)
        case .rotated180:
            return SIMD2<Float>(1 - screenXY.x, 1 - screenXY.y)
        case .rotated90CCW:
            return SIMD2<Float>(1 - screenXY.y, screenXY.x)
        }
    }
}
