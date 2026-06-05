//
//  MPRGeometryDisplayMapper.swift
//  MTKCore
//
//  Cohesive MPR plane, display, layout, and overlay coordinate mapping.
//

import CoreGraphics
import Foundation
import simd

public struct MPRGeometryPositionUpdate: Sendable, Equatable {
    public var axis: MPRPlaneAxis
    public var position: Float

    public init(axis: MPRPlaneAxis, position: Float) {
        self.axis = axis
        self.position = position
    }
}

public struct MPRGeometryDisplayContext: Sendable {
    public var dataset: VolumeDataset
    public var axis: MPRPlaneAxis
    public var slicePosition: Float
    public var plane: MPRPlaneGeometry
    public var displayTransform: MPRDisplayTransform
    public var viewportTransform: MPRViewportTransform
    public var outputAspect: MPROutputAspect
    public var presentationLayout: MPRPresentationLayout
    public var viewportSize: CGSize

    public func viewportPoint(forVoxel voxel: SIMD3<Float>) throws -> ViewportPoint {
        let worldPoint = VolumePicking.worldPoint(forVoxelIndex: voxel, in: dataset)
        return try viewportPoint(forWorldPoint: worldPoint)
    }

    public func viewportPoint(forWorldPoint worldPoint: SIMD3<Float>) throws -> ViewportPoint {
        try VolumePicking.screenPoint(
            forWorldPoint: worldPoint,
            dataset: dataset,
            plane: plane,
            displayTransform: displayTransform,
            viewportTransform: viewportTransform,
            outputAspect: outputAspect,
            viewportSize: viewportSize
        )
    }

    public func crosshairOffset(forVoxel voxel: SIMD3<Float>) throws -> CGPoint {
        try crosshairOffset(forWorldPoint: VolumePicking.worldPoint(forVoxelIndex: voxel, in: dataset))
    }

    public func crosshairOffset(forWorldPoint worldPoint: SIMD3<Float>) throws -> CGPoint {
        let point = try viewportPoint(forWorldPoint: worldPoint)
        return CGPoint(x: point.screenPoint.x - viewportSize.width * 0.5,
                       y: point.screenPoint.y - viewportSize.height * 0.5)
    }

    public func pick(screenPoint: CGPoint,
                     layers: [VolumeLayer] = []) throws -> VolumePickResult {
        try VolumePicking.pickMPR(
            screenPoint: screenPoint,
            viewportSize: viewportSize,
            dataset: dataset,
            plane: plane,
            displayTransform: displayTransform,
            viewportTransform: viewportTransform,
            outputAspect: outputAspect,
            axis: axis,
            layers: layers
        )
    }

    public func normalizedPositionUpdates(fromScreenPoint screenPoint: CGPoint,
                                          layers: [VolumeLayer] = []) throws -> [MPRGeometryPositionUpdate] {
        let pick = try pick(screenPoint: screenPoint, layers: layers)
        return MPRGeometryDisplayMapper.normalizedPositionUpdates(
            fromVoxel: pick.voxel.continuousIndex,
            dimensions: dataset.dimensions,
            viewingAxis: axis
        )
    }
}

public enum MPRGeometryDisplayMapper {
    public static func makeContext(dataset: VolumeDataset,
                                   axis: MPRPlaneAxis,
                                   slicePosition: Float,
                                   planeRotation: simd_quatf? = nil,
                                   viewportTransform: MPRViewportTransform = .identity,
                                   outputAspect: MPROutputAspect? = nil,
                                   viewportSize: CGSize) throws -> MPRGeometryDisplayContext {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            throw VolumePickError.invalidViewportSize
        }

        let resolvedSlicePosition = clampNormalized(slicePosition)
        let plane = makePlane(for: dataset,
                              axis: axis,
                              slicePosition: resolvedSlicePosition,
                              rotation: planeRotation)
        let displayTransform = MPRDisplayTransformFactory.makeTransform(for: plane,
                                                                       axis: axis)
        let resolvedAspect = outputAspect ?? .aspectFit(physicalAspectRatio: plane.physicalAspectRatio)
        return MPRGeometryDisplayContext(
            dataset: dataset,
            axis: axis,
            slicePosition: resolvedSlicePosition,
            plane: plane,
            displayTransform: displayTransform,
            viewportTransform: viewportTransform,
            outputAspect: resolvedAspect,
            presentationLayout: resolvedAspect.layout(destinationSize: viewportSize),
            viewportSize: viewportSize
        )
    }

    public static func makePlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 slicePosition: Float,
                                 rotation: simd_quatf? = nil) -> MPRPlaneGeometry {
        guard let rotation, !isIdentityRotation(rotation) else {
            return MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                    axis: axis,
                                                    slicePosition: slicePosition)
        }

        let dims = datasetDimensions(for: dataset.dimensions)
        let count = sliceCount(for: axis, dimensions: dataset.dimensions)
        let maximumIndex = max(count - 1, 0)
        let index = Int((clampNormalized(slicePosition) * Float(maximumIndex)).rounded())
        return makeRotatedPlane(for: dataset,
                                axis: axis,
                                index: index,
                                dims: dims,
                                rotation: rotation)
    }

    public static func makePlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 sliceIndex: Int,
                                 rotation: simd_quatf) -> MPRPlaneGeometry {
        let dims = datasetDimensions(for: dataset.dimensions)
        let count = sliceCount(for: axis, dimensions: dataset.dimensions)
        let index = max(0, min(sliceIndex, max(count - 1, 0)))
        return makeRotatedPlane(for: dataset,
                                axis: axis,
                                index: index,
                                dims: dims,
                                rotation: rotation)
    }

    public static func normalizedPositionUpdates(fromVoxel voxel: SIMD3<Float>,
                                                 dimensions: VolumeDimensions,
                                                 viewingAxis axis: MPRPlaneAxis) -> [MPRGeometryPositionUpdate] {
        let sagittal = normalizedPosition(forContinuousVoxelComponent: voxel.x,
                                          count: dimensions.width)
        let coronal = normalizedPosition(forContinuousVoxelComponent: voxel.y,
                                         count: dimensions.height)
        let axial = normalizedPosition(forContinuousVoxelComponent: voxel.z,
                                       count: dimensions.depth)
        switch axis {
        case .z:
            return [
                MPRGeometryPositionUpdate(axis: .x, position: sagittal),
                MPRGeometryPositionUpdate(axis: .y, position: coronal)
            ]
        case .y:
            return [
                MPRGeometryPositionUpdate(axis: .x, position: sagittal),
                MPRGeometryPositionUpdate(axis: .z, position: axial)
            ]
        case .x:
            return [
                MPRGeometryPositionUpdate(axis: .y, position: coronal),
                MPRGeometryPositionUpdate(axis: .z, position: axial)
            ]
        }
    }
}

private extension MPRGeometryDisplayMapper {
    static func makeRotatedPlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 index: Int,
                                 dims: SIMD3<Float>,
                                 rotation: simd_quatf) -> MPRPlaneGeometry {
        let plane = rotatedPlaneComputation(axis: axis,
                                            index: index,
                                            dims: dims,
                                            rotation: rotation)
        let geometry = DICOMGeometry(imageData: dataset.imageData)
        let originWorld = geometry.voxelToWorld.transformPoint(plane.originVoxel)
        let axisUWorld = geometry.voxelToWorld.transformPoint(plane.originVoxel + plane.axisUVoxel) - originWorld
        let axisVWorld = geometry.voxelToWorld.transformPoint(plane.originVoxel + plane.axisVVoxel) - originWorld
        let textureBasis = geometry.planeWorldToTex(originW: originWorld,
                                                    axisUW: axisUWorld,
                                                    axisVW: axisVWorld)
        let normal = normalized(cross: axisUWorld,
                                axisVWorld,
                                fallback: fallbackNormal(for: axis))

        return MPRPlaneGeometry(
            originVoxel: plane.originVoxel,
            axisUVoxel: plane.axisUVoxel,
            axisVVoxel: plane.axisVVoxel,
            originWorld: originWorld,
            axisUWorld: axisUWorld,
            axisVWorld: axisVWorld,
            originTexture: textureBasis.originT,
            axisUTexture: textureBasis.axisUT,
            axisVTexture: textureBasis.axisVT,
            normalWorld: normal
        )
    }
    struct RotatedPlaneComputation {
        var originVoxel: SIMD3<Float>
        var axisUVoxel: SIMD3<Float>
        var axisVVoxel: SIMD3<Float>
    }

    static func rotatedPlaneComputation(axis: MPRPlaneAxis,
                                        index: Int,
                                        dims: SIMD3<Float>,
                                        rotation: simd_quatf) -> RotatedPlaneComputation {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let normalizedRotation: simd_quatf
        if rotation.real == 0, rotation.imag == .zero {
            normalizedRotation = identity
        } else {
            normalizedRotation = simd_normalize(rotation)
        }
        let rotationMatrix = simd_float3x3(normalizedRotation)
        let basis = defaultAxes(for: axis)
        let span = simd_max(dims - SIMD3<Float>(repeating: 1), SIMD3<Float>(repeating: 0))
        let scaledU = basis.u * span
        let scaledV = basis.v * span
        var axisUVoxel = rotationMatrix * scaledU
        var axisVVoxel = rotationMatrix * scaledV

        let center = planeCenterVoxel(for: axis, index: index, dims: dims)
        let halfU = axisUVoxel * 0.5
        let halfV = axisVVoxel * 0.5
        let combinedHalf = simd_abs(halfU) + simd_abs(halfV)

        var scale: Float = 1
        for component in 0..<3 {
            let extent = combinedHalf[component]
            guard extent > 0 else { continue }

            let lowerBound: Float = -0.5
            let upperBound = dims[component] - 0.5
            let spaceBelow = center[component] - lowerBound
            let spaceAbove = upperBound - center[component]
            let componentScale = min(spaceBelow / extent, spaceAbove / extent)
            scale = min(scale, componentScale)
        }

        if !scale.isFinite {
            scale = 1
        } else {
            scale = max(min(scale, 1), 0)
        }

        if scale < 1 {
            axisUVoxel *= scale
            axisVVoxel *= scale
        }

        let origin = center - 0.5 * axisUVoxel - 0.5 * axisVVoxel
        return RotatedPlaneComputation(originVoxel: origin,
                                       axisUVoxel: axisUVoxel,
                                       axisVVoxel: axisVVoxel)
    }

    static func datasetDimensions(for dimensions: VolumeDimensions) -> SIMD3<Float> {
        SIMD3<Float>(
            max(1, Float(dimensions.width)),
            max(1, Float(dimensions.height)),
            max(1, Float(dimensions.depth))
        )
    }

    static func defaultAxes(for axis: MPRPlaneAxis) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch axis {
        case .x:
            return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
        case .y:
            return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1))
        case .z:
            return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        }
    }

    static func planeCenterVoxel(for axis: MPRPlaneAxis,
                                 index: Int,
                                 dims: SIMD3<Float>) -> SIMD3<Float> {
        let span = simd_max(dims - SIMD3<Float>(repeating: 1), SIMD3<Float>(repeating: 0))
        let halfSpan = span * 0.5
        switch axis {
        case .x:
            return SIMD3<Float>(Float(index), halfSpan.y, halfSpan.z)
        case .y:
            return SIMD3<Float>(halfSpan.x, Float(index), halfSpan.z)
        case .z:
            return SIMD3<Float>(halfSpan.x, halfSpan.y, Float(index))
        }
    }

    static func sliceCount(for axis: MPRPlaneAxis,
                           dimensions: VolumeDimensions) -> Int {
        switch axis {
        case .x:
            return dimensions.width
        case .y:
            return dimensions.height
        case .z:
            return dimensions.depth
        }
    }

    static func fallbackNormal(for axis: MPRPlaneAxis) -> SIMD3<Float> {
        switch axis {
        case .x:
            return SIMD3<Float>(1, 0, 0)
        case .y:
            return SIMD3<Float>(0, 1, 0)
        case .z:
            return SIMD3<Float>(0, 0, 1)
        }
    }

    static func normalized(cross lhs: SIMD3<Float>,
                           _ rhs: SIMD3<Float>,
                           fallback: SIMD3<Float>) -> SIMD3<Float> {
        normalized(vector: simd_cross(lhs, rhs), fallback: fallback)
    }

    static func normalized(vector: SIMD3<Float>,
                           fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length > Float.ulpOfOne {
            return vector / length
        }

        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne {
            return fallback / fallbackLength
        }

        return SIMD3<Float>(0, 0, 1)
    }

    static func normalizedPosition(forContinuousVoxelComponent component: Float,
                                   count: Int) -> Float {
        guard count > 1 else { return 0 }
        return clampNormalized(component / Float(count - 1))
    }

    static func clampNormalized(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func isIdentityRotation(_ rotation: simd_quatf) -> Bool {
        if rotation.real == 0, rotation.imag == .zero {
            return true
        }
        let normalized = simd_normalize(rotation)
        return simd_length(normalized.imag) <= 1e-6 && abs(normalized.real - 1) <= 1e-6
    }
}
