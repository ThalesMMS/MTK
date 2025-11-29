//
//  OpacityCorrection.swift
//  MTKCore
//
//  Implements opacity correction so that visual opacity
//  remains stable when the sampling distance changes. All calculations are
//  performed on the CPU before generating transfer-function textures to keep
//  shader cost unchanged.
//

import simd

public enum OpacityCorrection {
    /// Computes opacity unit distance. It scales the volume
    /// diagonal by the largest dimension to get a per-voxel reference length.
    /// - Parameters:
    ///   - bounds: Axis-aligned bounds in world units `[xmin, xmax, ymin, ymax, zmin, zmax]`.
    ///   - dimensions: Volume dimensions `(width, height, depth)`.
    /// - Returns: The unit distance in world units (mm).
    public static func scalarOpacityUnitDistance(bounds: [Float],
                                                 dimensions: (width: Int, height: Int, depth: Int)) -> Float {
        guard bounds.count >= 6 else { return 1 }
        let dx = bounds[1] - bounds[0]
        let dy = bounds[3] - bounds[2]
        let dz = bounds[5] - bounds[4]
        let diagonal = sqrt(dx * dx + dy * dy + dz * dz)
        let maxDim = Float(max(dimensions.width, max(dimensions.height, dimensions.depth)))
        guard maxDim > .ulpOfOne else { return 1 }
        return diagonal / maxDim
    }

    /// Convenience overload using a dataset.
    public static func scalarOpacityUnitDistance(for dataset: VolumeDataset) -> Float {
        let bounds = MPRCameraConfiguration.worldBounds(for: dataset)
        return scalarOpacityUnitDistance(bounds: bounds,
                                         dimensions: (dataset.dimensions.width,
                                                      dataset.dimensions.height,
                                                      dataset.dimensions.depth))
    }

    /// Computes the opacity factor given the sampling distance and unit distance.
    public static func opacityFactor(sampleDistance: Float,
                                     opacityUnitDistance: Float) -> Float {
        guard opacityUnitDistance > .ulpOfOne else { return 1 }
        return sampleDistance / opacityUnitDistance
    }

    /// Corrects a single opacity value using formula: α' = 1 - (1 - α)^factor.
    public static func correctedOpacity(_ opacity: Float, factor: Float) -> Float {
        let clamped = max(0, min(1, opacity))
        guard factor > .ulpOfOne else { return clamped }
        return 1.0 - pow(1.0 - clamped, factor)
    }

    /// Applies opacity correction to a transfer function in place.
    public static func correctedTransferFunction(_ transfer: VolumeTransferFunction,
                                                 factor: Float) -> VolumeTransferFunction {
        guard factor > .ulpOfOne else { return transfer }
        let correctedOpacityPoints = transfer.opacityPoints.map { point in
            let corrected = correctedOpacity(point.opacity, factor: factor)
            return VolumeTransferFunction.OpacityControlPoint(intensity: point.intensity,
                                                              opacity: corrected)
        }
        return VolumeTransferFunction(opacityPoints: correctedOpacityPoints,
                                      colourPoints: transfer.colourPoints)
    }
}

