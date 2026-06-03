//
//  RegisteredVolumeLayerResampler.swift
//  MTKCore
//
//  CPU resampling for externally registered scalar volume layers.
//

import Foundation
import simd

public enum RegisteredVolumeLayerResampler {
    public static let defaultFillValue: Int32 = 0

    public static func resampledLayer(_ layer: VolumeLayer,
                                      into baseDataset: VolumeDataset,
                                      interpolation: VolumeResampleInterpolation = .trilinear,
                                      fillValue: Int32 = defaultFillValue) throws -> VolumeLayer {
        guard let scalarVolume = layer.scalarVolume else { return layer }
        let transform = LayerTransform(baseWorldToLayerWorld: layer.baseWorldToLayerWorld)
        guard transform.supportsCPUResampling else {
            throw RegisteredVolumeLayerResamplingError.unsupportedTransform(layerID: layer.id,
                                                                           classification: transform.classification)
        }
        guard !transform.isApproximatelyIdentity else { return layer }

        let dataset = scalarVolume.dataset
        try VolumePipelineScalarData.validate(baseDataset)
        try VolumePipelineScalarData.validate(dataset)
        try VolumePipelineScalarData.validateSpacing(baseDataset.spacing)
        try VolumePipelineScalarData.validateSpacing(dataset.spacing)
        try VolumePipelineScalarData.validateReplacementValue(fillValue, pixelFormat: dataset.pixelFormat)

        let source = try VolumePipelineScalarData.decodedScalars(from: dataset)
        var output = [Int32]()
        output.reserveCapacity(baseDataset.dimensions.voxelCount)

        let baseIndexToWorld = baseDataset.imageData.indexToWorld
        let layerWorldToIndex = dataset.imageData.worldToIndex
        let baseWorldToLayerWorld = layer.baseWorldToLayerWorld

        for z in 0..<baseDataset.dimensions.depth {
            for y in 0..<baseDataset.dimensions.height {
                for x in 0..<baseDataset.dimensions.width {
                    let baseIndex = SIMD3<Float>(Float(x), Float(y), Float(z))
                    let baseWorld = baseIndexToWorld.transformPoint(baseIndex)
                    let layerWorld = baseWorldToLayerWorld.transformPoint(baseWorld)
                    let layerIndex = layerWorldToIndex.transformPoint(layerWorld)
                    let sample = sample(source,
                                        dimensions: dataset.dimensions,
                                        at: layerIndex,
                                        interpolation: interpolation,
                                        fillValue: fillValue)
                    output.append(sample)
                }
            }
        }

        var imageData = baseDataset.imageData
        imageData.pixelFormat = dataset.pixelFormat
        imageData.componentsPerVoxel = dataset.imageData.componentsPerVoxel
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)
        imageData.recommendedWindow = dataset.recommendedWindow

        let resampledDataset = VolumeDataset(
            data: try VolumePipelineScalarData.encodedData(from: output,
                                                           pixelFormat: dataset.pixelFormat),
            imageData: imageData
        )
        let resampledScalar = ScalarVolumeLayer(dataset: resampledDataset,
                                                transferFunction: scalarVolume.transferFunction,
                                                quantitativeMapping: scalarVolume.quantitativeMapping)
        return VolumeLayer(id: layer.id,
                           scalarVolume: resampledScalar,
                           opacity: layer.opacity,
                           blendMode: layer.blendMode,
                           baseWorldToLayerWorld: matrix_identity_float4x4,
                           isVisible: layer.isVisible)
    }

    public static func resampledVisibleScalarLayers(from layers: [VolumeLayer],
                                                    into baseDataset: VolumeDataset,
                                                    interpolation: VolumeResampleInterpolation = .trilinear,
                                                    fillValue: Int32 = defaultFillValue) throws -> [VolumeLayer] {
        try layers.compactMap { layer in
            guard layer.isVisible,
                  layer.clampedOpacity > 0,
                  layer.scalarVolume != nil else {
                return nil
            }
            return try resampledLayer(layer,
                                      into: baseDataset,
                                      interpolation: interpolation,
                                      fillValue: fillValue)
        }
    }
}

private extension RegisteredVolumeLayerResampler {
    static func sample(_ source: [Int32],
                       dimensions: VolumeDimensions,
                       at index: SIMD3<Float>,
                       interpolation: VolumeResampleInterpolation,
                       fillValue: Int32) -> Int32 {
        guard index.x.isFinite, index.y.isFinite, index.z.isFinite,
              isInside(index, dimensions: dimensions) else {
            return fillValue
        }

        switch interpolation {
        case .nearest:
            return nearestSample(source, dimensions: dimensions, at: index, fillValue: fillValue)
        case .trilinear:
            return trilinearSample(source, dimensions: dimensions, at: index, fillValue: fillValue)
        }
    }

    static func nearestSample(_ source: [Int32],
                              dimensions: VolumeDimensions,
                              at index: SIMD3<Float>,
                              fillValue: Int32) -> Int32 {
        let x = Int(index.x.rounded(.toNearestOrAwayFromZero))
        let y = Int(index.y.rounded(.toNearestOrAwayFromZero))
        let z = Int(index.z.rounded(.toNearestOrAwayFromZero))
        guard contains(x: x, y: y, z: z, dimensions: dimensions) else {
            return fillValue
        }
        return source[VolumePipelineScalarData.linearIndex(x: x, y: y, z: z, dimensions: dimensions)]
    }

    static func trilinearSample(_ source: [Int32],
                                dimensions: VolumeDimensions,
                                at index: SIMD3<Float>,
                                fillValue: Int32) -> Int32 {
        let x0 = Int(floor(index.x))
        let y0 = Int(floor(index.y))
        let z0 = Int(floor(index.z))
        let x1 = x0 + 1
        let y1 = y0 + 1
        let z1 = z0 + 1

        let tx = index.x - Float(x0)
        let ty = index.y - Float(y0)
        let tz = index.z - Float(z0)

        let c000 = scalar(source, dimensions: dimensions, x: x0, y: y0, z: z0, fillValue: fillValue)
        let c100 = scalar(source, dimensions: dimensions, x: x1, y: y0, z: z0, fillValue: fillValue)
        let c010 = scalar(source, dimensions: dimensions, x: x0, y: y1, z: z0, fillValue: fillValue)
        let c110 = scalar(source, dimensions: dimensions, x: x1, y: y1, z: z0, fillValue: fillValue)
        let c001 = scalar(source, dimensions: dimensions, x: x0, y: y0, z: z1, fillValue: fillValue)
        let c101 = scalar(source, dimensions: dimensions, x: x1, y: y0, z: z1, fillValue: fillValue)
        let c011 = scalar(source, dimensions: dimensions, x: x0, y: y1, z: z1, fillValue: fillValue)
        let c111 = scalar(source, dimensions: dimensions, x: x1, y: y1, z: z1, fillValue: fillValue)

        let c00 = lerp(c000, c100, tx)
        let c01 = lerp(c001, c101, tx)
        let c10 = lerp(c010, c110, tx)
        let c11 = lerp(c011, c111, tx)
        let c0 = lerp(c00, c10, ty)
        let c1 = lerp(c01, c11, ty)
        return Int32(lerp(c0, c1, tz).rounded(.toNearestOrAwayFromZero))
    }

    static func scalar(_ source: [Int32],
                       dimensions: VolumeDimensions,
                       x: Int,
                       y: Int,
                       z: Int,
                       fillValue: Int32) -> Float {
        guard contains(x: x, y: y, z: z, dimensions: dimensions) else {
            return Float(fillValue)
        }
        return Float(source[VolumePipelineScalarData.linearIndex(x: x, y: y, z: z, dimensions: dimensions)])
    }

    static func isInside(_ index: SIMD3<Float>,
                         dimensions: VolumeDimensions) -> Bool {
        index.x >= 0 && index.y >= 0 && index.z >= 0 &&
            index.x <= Float(dimensions.width - 1) &&
            index.y <= Float(dimensions.height - 1) &&
            index.z <= Float(dimensions.depth - 1)
    }

    static func contains(x: Int,
                         y: Int,
                         z: Int,
                         dimensions: VolumeDimensions) -> Bool {
        x >= 0 && y >= 0 && z >= 0 &&
            x < dimensions.width && y < dimensions.height && z < dimensions.depth
    }

    static func lerp(_ lhs: Float, _ rhs: Float, _ t: Float) -> Float {
        lhs + (rhs - lhs) * t
    }
}
