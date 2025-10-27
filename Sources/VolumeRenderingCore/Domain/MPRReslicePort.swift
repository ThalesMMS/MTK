//
//  MPRReslicePort.swift
//  MetalVolumetrics
//
//  Declares the domain contract for requesting multi-planar reconstruction
//  slabs. Infrastructure renderers resample the volume and return 2D buffers
//  ready for texturing or post processing.
//

import Foundation
import simd

public enum MPRPlaneAxis: Int, CaseIterable, Sendable {
    case x = 0
    case y = 1
    case z = 2

    public var description: String {
        switch self {
        case .x:
            return "Sagittal (X)"
        case .y:
            return "Coronal (Y)"
        case .z:
            return "Axial (Z)"
        }
    }
}

public enum MPRBlendMode: Int, CaseIterable, Sendable {
    case single = 0
    case maximum = 1
    case minimum = 2
    case average = 3

    public var description: String {
        switch self {
        case .single:
            return "Single slice"
        case .maximum:
            return "Maximum Intensity (MIP)"
        case .minimum:
            return "Minimum Intensity (MinIP)"
        case .average:
            return "Average"
        }
    }
}

public struct MPRPlaneGeometry: Sendable, Equatable {
    public var originVoxel: SIMD3<Float>
    public var axisUVoxel: SIMD3<Float>
    public var axisVVoxel: SIMD3<Float>

    public var originWorld: SIMD3<Float>
    public var axisUWorld: SIMD3<Float>
    public var axisVWorld: SIMD3<Float>

    public var originTexture: SIMD3<Float>
    public var axisUTexture: SIMD3<Float>
    public var axisVTexture: SIMD3<Float>

    public var normalWorld: SIMD3<Float>

    public init(originVoxel: SIMD3<Float>,
                axisUVoxel: SIMD3<Float>,
                axisVVoxel: SIMD3<Float>,
                originWorld: SIMD3<Float>,
                axisUWorld: SIMD3<Float>,
                axisVWorld: SIMD3<Float>,
                originTexture: SIMD3<Float>,
                axisUTexture: SIMD3<Float>,
                axisVTexture: SIMD3<Float>,
                normalWorld: SIMD3<Float>) {
        self.originVoxel = originVoxel
        self.axisUVoxel = axisUVoxel
        self.axisVVoxel = axisVVoxel
        self.originWorld = originWorld
        self.axisUWorld = axisUWorld
        self.axisVWorld = axisVWorld
        self.originTexture = originTexture
        self.axisUTexture = axisUTexture
        self.axisVTexture = axisVTexture
        self.normalWorld = normalWorld
    }
}

public struct MPRSlice: Sendable, Equatable {
    public var pixels: Data
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var pixelFormat: VolumePixelFormat
    public var intensityRange: ClosedRange<Int32>
    public var pixelSpacing: SIMD2<Float>?

    public init(pixels: Data,
                width: Int,
                height: Int,
                bytesPerRow: Int,
                pixelFormat: VolumePixelFormat,
                intensityRange: ClosedRange<Int32>,
                pixelSpacing: SIMD2<Float>? = nil) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.intensityRange = intensityRange
        self.pixelSpacing = pixelSpacing
    }
}

public enum MPRResliceCommand: Sendable, Equatable {
    case setBlend(MPRBlendMode)
    case setSlab(thickness: Int, steps: Int)
}

@preconcurrency
public protocol MPRReslicePort {
    func makeSlab(dataset: VolumeDataset,
                  plane: MPRPlaneGeometry,
                  thickness: Int,
                  steps: Int,
                  blend: MPRBlendMode) async throws -> MPRSlice
    func send(_ command: MPRResliceCommand) async throws
}
