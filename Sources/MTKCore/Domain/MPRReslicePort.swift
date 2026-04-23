//
//  MPRReslicePort.swift
//  MetalVolumetrics
//
//  Declares the domain contract for requesting multi-planar reconstruction
//  slabs as texture-native GPU frames for interactive presentation.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

public enum MPRPlaneAxis: Int, CaseIterable, Sendable {
    case x = 0
    case y = 1
    case z = 2

    public var description: String {
        switch self {
        case .x:
            return "Sagittal"
        case .y:
            return "Coronal"
        case .z:
            return "Axial"
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

public struct MPRFrameSignature: Hashable, Sendable, Equatable {
    public var planeGeometry: MPRPlaneGeometry
    public var slabThickness: Int
    public var slabSteps: Int
    public var blend: MPRBlendMode

    public init(planeGeometry: MPRPlaneGeometry,
                slabThickness: Int,
                slabSteps: Int,
                blend: MPRBlendMode) {
        self.planeGeometry = planeGeometry
        self.slabThickness = slabThickness
        self.slabSteps = slabSteps
        self.blend = blend
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(planeGeometry.originVoxel.x)
        hasher.combine(planeGeometry.originVoxel.y)
        hasher.combine(planeGeometry.originVoxel.z)
        hasher.combine(planeGeometry.axisUVoxel.x)
        hasher.combine(planeGeometry.axisUVoxel.y)
        hasher.combine(planeGeometry.axisUVoxel.z)
        hasher.combine(planeGeometry.axisVVoxel.x)
        hasher.combine(planeGeometry.axisVVoxel.y)
        hasher.combine(planeGeometry.axisVVoxel.z)
        hasher.combine(planeGeometry.originWorld.x)
        hasher.combine(planeGeometry.originWorld.y)
        hasher.combine(planeGeometry.originWorld.z)
        hasher.combine(planeGeometry.axisUWorld.x)
        hasher.combine(planeGeometry.axisUWorld.y)
        hasher.combine(planeGeometry.axisUWorld.z)
        hasher.combine(planeGeometry.axisVWorld.x)
        hasher.combine(planeGeometry.axisVWorld.y)
        hasher.combine(planeGeometry.axisVWorld.z)
        hasher.combine(planeGeometry.originTexture.x)
        hasher.combine(planeGeometry.originTexture.y)
        hasher.combine(planeGeometry.originTexture.z)
        hasher.combine(planeGeometry.axisUTexture.x)
        hasher.combine(planeGeometry.axisUTexture.y)
        hasher.combine(planeGeometry.axisUTexture.z)
        hasher.combine(planeGeometry.axisVTexture.x)
        hasher.combine(planeGeometry.axisVTexture.y)
        hasher.combine(planeGeometry.axisVTexture.z)
        hasher.combine(planeGeometry.normalWorld.x)
        hasher.combine(planeGeometry.normalWorld.y)
        hasher.combine(planeGeometry.normalWorld.z)
        hasher.combine(slabThickness)
        hasher.combine(slabSteps)
        hasher.combine(blend.rawValue)
    }
}

public extension MPRPlaneGeometry {
    static func canonical(axis: MPRPlaneAxis) -> MPRPlaneGeometry {
        switch axis {
        case .z:
            return MPRPlaneGeometry(originVoxel: .zero,
                                    axisUVoxel: SIMD3<Float>(1, 0, 0),
                                    axisVVoxel: SIMD3<Float>(0, 1, 0),
                                    originWorld: .zero,
                                    axisUWorld: SIMD3<Float>(1, 0, 0),
                                    axisVWorld: SIMD3<Float>(0, 1, 0),
                                    originTexture: .zero,
                                    axisUTexture: SIMD3<Float>(1, 0, 0),
                                    axisVTexture: SIMD3<Float>(0, 1, 0),
                                    normalWorld: SIMD3<Float>(0, 0, 1))
        case .y:
            return MPRPlaneGeometry(originVoxel: .zero,
                                    axisUVoxel: SIMD3<Float>(-1, 0, 0),
                                    axisVVoxel: SIMD3<Float>(0, 0, 1),
                                    originWorld: .zero,
                                    axisUWorld: SIMD3<Float>(-1, 0, 0),
                                    axisVWorld: SIMD3<Float>(0, 0, 1),
                                    originTexture: .zero,
                                    axisUTexture: SIMD3<Float>(-1, 0, 0),
                                    axisVTexture: SIMD3<Float>(0, 0, 1),
                                    normalWorld: SIMD3<Float>(0, 1, 0))
        case .x:
            return MPRPlaneGeometry(originVoxel: .zero,
                                    axisUVoxel: SIMD3<Float>(0, 1, 0),
                                    axisVVoxel: SIMD3<Float>(0, 0, 1),
                                    originWorld: .zero,
                                    axisUWorld: SIMD3<Float>(0, 1, 0),
                                    axisVWorld: SIMD3<Float>(0, 0, 1),
                                    originTexture: .zero,
                                    axisUTexture: SIMD3<Float>(0, 1, 0),
                                    axisVTexture: SIMD3<Float>(0, 0, 1),
                                    normalWorld: SIMD3<Float>(1, 0, 0))
        }
    }

    func sizedForOutput(_ size: CGSize) -> MPRPlaneGeometry {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let targetULength = width > 1 ? Float(width - 1) : 0
        let targetVLength = height > 1 ? Float(height - 1) : 0
        let uLength = simd_length(axisUVoxel)
        let vLength = simd_length(axisVVoxel)
        let uScale = uLength > Float.ulpOfOne ? targetULength / uLength : 0
        let vScale = vLength > Float.ulpOfOne ? targetVLength / vLength : 0

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisUVoxel * uScale,
            axisVVoxel: axisVVoxel * vScale,
            originWorld: originWorld,
            axisUWorld: axisUWorld,
            axisVWorld: axisVWorld,
            originTexture: originTexture,
            axisUTexture: axisUTexture,
            axisVTexture: axisVTexture,
            normalWorld: normalWorld
        )
    }
}

public enum MPRResliceCommand: Sendable, Equatable {
    case setBlend(MPRBlendMode)
    case setSlab(thickness: Int, steps: Int)
}

@preconcurrency
public protocol MPRReslicePort {
    /// Produces a texture-native raw intensity MPR frame.
    ///
    /// This is the preferred path for interactive rendering. The provided
    /// `volumeTexture` should be the shared 3D volume texture for synchronized
    /// axial, coronal, and sagittal viewports. The returned texture stores raw
    /// 16-bit intensity values (`r16Sint` or `r16Uint`) for a later presentation
    /// pass to apply window/level, LUT, and orientation.
    func makeSlabTexture(dataset: VolumeDataset,
                         volumeTexture: any MTLTexture,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRTextureFrame

    func send(_ command: MPRResliceCommand) async throws
}
