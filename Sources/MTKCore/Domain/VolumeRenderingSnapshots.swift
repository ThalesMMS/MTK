//
//  VolumeRenderingSnapshots.swift
//  MTK
//
//  Snapshot structures for volume rendering state
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

public struct ChannelControlSnapshot: Sendable, Equatable {
    public let presetKey: String
    public let gain: Float
    public let controlPoints: [SIMD2<Float>]
    
    public init(presetKey: String, gain: Float, controlPoints: [SIMD2<Float>] = []) {
        self.presetKey = presetKey
        self.gain = gain
        self.controlPoints = controlPoints
    }
}

public struct ClipBoundsSnapshot: Sendable, Equatable {
    public let xMin: Float
    public let xMax: Float
    public let yMin: Float
    public let yMax: Float
    public let zMin: Float
    public let zMax: Float
    
    public init(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.zMin = zMin
        self.zMax = zMax
    }
    
    public static let `default` = ClipBoundsSnapshot(
        xMin: 0, xMax: 1, yMin: 0, yMax: 1, zMin: 0, zMax: 1
    )
}

public struct ClipPlaneSnapshot: Sendable, Equatable {
    public let preset: Int
    public let offset: Float
    
    public init(preset: Int, offset: Float) {
        self.preset = preset
        self.offset = offset
    }
    
    public static let `default` = ClipPlaneSnapshot(preset: 0, offset: 0)
}

public struct VolumeMetadata: Sendable, Equatable {
    public let dimensions: SIMD3<Int32>
    public let spacing: SIMD3<Float>
    public let origin: SIMD3<Float>
    public let orientation: simd_float3x3
    public let intensityRange: ClosedRange<Int32>
    
    public init(dimensions: SIMD3<Int32>, spacing: SIMD3<Float>, origin: SIMD3<Float>, orientation: simd_float3x3, intensityRange: ClosedRange<Int32>) {
        self.dimensions = dimensions
        self.spacing = spacing
        self.origin = origin
        self.orientation = orientation
        self.intensityRange = intensityRange
    }
}
