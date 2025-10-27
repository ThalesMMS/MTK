//
//  VolumeDataset.swift
//  VolumeRenderingKit
//
//  Core volumetric data structures shared across volume rendering stacks.
//  Mirrors the legacy DomainPorts module so clients can exchange datasets
//  without depending on the application targets.
//

import Foundation
import simd

public struct VolumeOrientation: Sendable, Equatable {
    public var row: SIMD3<Float>
    public var column: SIMD3<Float>
    public var origin: SIMD3<Float>

    public init(row: SIMD3<Float>, column: SIMD3<Float>, origin: SIMD3<Float>) {
        self.row = row
        self.column = column
        self.origin = origin
    }
}

public extension VolumeOrientation {
    static let canonical = VolumeOrientation(
        row: SIMD3<Float>(1, 0, 0),
        column: SIMD3<Float>(0, 1, 0),
        origin: .zero
    )
}

public struct VolumeDimensions: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public var voxelCount: Int {
        width * height * depth
    }
}

public struct VolumeSpacing: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum VolumePixelFormat: Sendable, Equatable {
    case int16Signed
    case int16Unsigned

    public var bytesPerVoxel: Int {
        switch self {
        case .int16Signed, .int16Unsigned:
            return MemoryLayout<UInt16>.size
        }
    }

    public var defaultIntensityRange: ClosedRange<Int32> {
        switch self {
        case .int16Signed:
            let minValue = Int32(Int16.min)
            let maxValue = Int32(Int16.max)
            return minValue...maxValue
        case .int16Unsigned:
            let minValue = Int32(UInt16.min)
            let maxValue = Int32(UInt16.max)
            return minValue...maxValue
        }
    }
}

public struct VolumeDataset: Sendable, Equatable {
    public var data: Data
    public var dimensions: VolumeDimensions
    public var spacing: VolumeSpacing
    public var pixelFormat: VolumePixelFormat
    public var orientation: VolumeOrientation
    public var intensityRange: ClosedRange<Int32>
    public var recommendedWindow: ClosedRange<Int32>?

    public init(data: Data,
                dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                pixelFormat: VolumePixelFormat,
                intensityRange: ClosedRange<Int32>? = nil,
                orientation: VolumeOrientation? = nil,
                recommendedWindow: ClosedRange<Int32>? = nil) {
        self.data = data
        self.dimensions = dimensions
        self.spacing = spacing
        self.pixelFormat = pixelFormat
        self.intensityRange = intensityRange ?? pixelFormat.defaultIntensityRange
        self.orientation = orientation ?? .canonical
        self.recommendedWindow = recommendedWindow
    }

    public var voxelCount: Int {
        dimensions.voxelCount
    }

    public var scale: VolumeSpacing {
        VolumeSpacing(
            x: spacing.x * Double(dimensions.width),
            y: spacing.y * Double(dimensions.height),
            z: spacing.z * Double(dimensions.depth)
        )
    }
}
