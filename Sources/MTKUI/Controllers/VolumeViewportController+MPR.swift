//
//  VolumeViewportController+MPR.swift
//  MTKUI
//
//  MPR helpers for VolumeViewportController.
//

import CoreGraphics
import Foundation
import Metal
import MTKCore
import simd

extension VolumeViewportController {
    /// Generates an MPR texture frame for a specific dataset slice and rendering configuration.
    /// - Parameters:
    ///   - dataset: The volume dataset to render.
    ///   - axis: The anatomical axis for the MPR plane.
    ///   - index: The requested slice index (will be clamped to valid bounds for the axis).
    ///   - blend: The volumetric blend mode to apply when compositing the slab.
    ///   - slab: Optional slab configuration (thickness/steps); if `nil`, a default or adaptive slab configuration is used.
    /// - Returns: An `MPRTextureFrame` containing the rendered slab texture for the requested MPR plane.
    /// - Throws: Errors propagated from acquiring the volume texture or from the slab rendering operation.
    func renderMpr(dataset: VolumeDataset,
                   axis: Axis,
                   index: Int,
                   blend: VolumetricMPRBlendMode,
                   slab: SlabConfiguration?) async throws -> MPRTextureFrame {
        let planeIndex = clampedIndex(for: axis, index: index)
        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        let effectiveSlabConfig = effectiveMPRSlabConfiguration(for: slab)
        let signature = MPRFrameSignature(planeGeometry: plane,
                                          slabThickness: effectiveSlabConfig.thickness,
                                          slabSteps: effectiveSlabConfig.steps,
                                          blend: blend.coreBlend)
        let axisKey = axis.mprPlaneAxis

        if let frame = mprFrameCache.cachedFrame(for: axisKey, matching: signature) {
            return frame
        }

        let volumeTexture = try await mprVolumeTexture(for: dataset)
        let frame = try await mprRenderer.makeSlabTexture(dataset: dataset,
                                                          volumeTexture: volumeTexture,
                                                          plane: plane,
                                                          thickness: effectiveSlabConfig.thickness,
                                                          steps: effectiveSlabConfig.steps,
                                                          blend: blend.coreBlend)
        try Task.checkCancellation()
        mprFrameCache.store(frame,
                            for: axisKey,
                            signature: signature)
        return frame
    }

    /// Compute the drawable viewport size in pixels, rounding each dimension and ensuring a minimum of 1.
    /// - Returns: A tuple `(width: Int, height: Int)` containing the viewport's drawable pixel dimensions, rounded to the nearest integer and clamped to at least 1 for each dimension.
    func clampedViewportSize() -> (width: Int, height: Int) {
        let size = viewportSurface.drawablePixelSize
        return (
            max(1, Int(size.width.rounded())),
            max(1, Int(size.height.rounded()))
        )
    }

    /// Fetches the Metal texture representing the given dataset's volume.
    /// - Parameter dataset: The volume dataset to create or retrieve a texture for.
    /// - Returns: A Metal texture containing the dataset's volume data.
    /// - Throws: Any error produced by the texture cache or during Metal texture creation.
    func mprVolumeTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        try await mprVolumeTextureCache.texture(for: dataset,
                                                device: device,
                                                commandQueue: commandQueue)
    }

    /// Resolve the HU window range to use for MPR rendering.
    /// - Parameter dataset: The dataset whose intensityRange is used as the final fallback.
    /// - Returns: The selected HU window range: `mprHuWindow` if present; otherwise `huWindow.minHU...huWindow.maxHU` if `huWindow` is present; otherwise `dataset.intensityRange`.
    func resolvedMPRWindow(for dataset: VolumeDataset) -> ClosedRange<Int32> {
        mprHuWindow ?? huWindow.map { $0.minHU...$0.maxHU } ?? dataset.intensityRange
    }

    /// Attempt to present a cached MPR frame that matches the current display state.
    /// 
    /// If the current display is not an MPR configuration, no dataset is applied, or no cached frame matches the computed signature, the method returns `false`. If presenting the cached frame fails, `lastRenderError` is set to the thrown error and the method returns `false`.
    /// - Returns: `true` if a cached MPR frame was presented, `false` otherwise.
    func presentCachedMPRFrameIfPossible() -> Bool {
        guard let dataset,
              case let .mpr(axis, index, blend, slab) = currentDisplay ?? .volume(method: currentVolumeMethod),
              let signature = currentMPRFrameSignature(axis: axis,
                                                       index: index,
                                                       blend: blend,
                                                       slab: slab),
              let frame = mprFrameCache.cachedFrame(for: axis.mprPlaneAxis,
                                                    matching: signature) else {
            return false
        }

        do {
            try viewportSurface.present(mprFrame: frame,
                                        window: resolvedMPRWindow(for: dataset))
            return true
        } catch {
            lastRenderError = error
            return false
        }
    }

    /// Compute the slab configuration to use for MPR rendering.
    /// 
    /// Uses the provided `slab` if non-nil; otherwise defaults to a slab with thickness 1 and steps 1.
    /// If `adaptiveSamplingEnabled` is true, the returned configuration uses `max(1, qualityScheduler.currentSlabSteps)` for `steps`; otherwise it preserves the slab's `steps`.
    /// - Parameter slab: An optional slab configuration override.
    /// - Returns: A `SlabConfiguration` whose `thickness` comes from `slab` (or 1 if nil) and whose `steps` are adapted as described above.
    private func effectiveMPRSlabConfiguration(for slab: SlabConfiguration?) -> SlabConfiguration {
        let slabConfig = slab ?? SlabConfiguration(thickness: 1, steps: 1)
        let effectiveSlabSteps = adaptiveSamplingEnabled
            ? max(1, qualityScheduler.currentSlabSteps)
            : slabConfig.steps
        return SlabConfiguration(thickness: slabConfig.thickness,
                                 steps: effectiveSlabSteps)
    }

    /// Produce an MPR frame signature representing the current applied dataset state for a given axis and slice.
    /// - Parameters:
    ///   - axis: The volume axis to generate the signature for.
    ///   - index: The requested slice index (will be clamped to valid bounds for the axis).
    ///   - blend: The volumetric MPR blend mode to include in the signature.
    ///   - slab: Optional slab configuration to use; when `nil` a default/effective slab configuration is applied.
    /// - Returns: An `MPRFrameSignature` containing drawable-sized plane geometry, the effective slab thickness and steps, and the blend mode; `nil` if no dataset is currently applied.
    private func currentMPRFrameSignature(axis: Axis,
                                          index: Int,
                                          blend: VolumetricMPRBlendMode,
                                          slab: SlabConfiguration?) -> MPRFrameSignature? {
        guard datasetApplied else { return nil }
        let planeIndex = clampedIndex(for: axis, index: index)
        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        let effectiveSlab = effectiveMPRSlabConfiguration(for: slab)
        return MPRFrameSignature(planeGeometry: plane,
                                 slabThickness: effectiveSlab.thickness,
                                 slabSteps: effectiveSlab.steps,
                                 blend: blend.coreBlend)
    }

    /// Create an `MPRPlaneGeometry` sized to the current drawable viewport.
    /// - Parameter plane: The source plane geometry to size for output.
    /// - Returns: An `MPRPlaneGeometry` adjusted to match the current drawable pixel dimensions.
    func makeDrawableSizedMprPlane(_ plane: MPRPlaneGeometry) -> MPRPlaneGeometry {
        let viewport = clampedViewportSize()
        return plane.sizedForOutput(CGSize(width: viewport.width,
                                           height: viewport.height))
    }

    /// Invalidates cached MPR frames for a specific plane axis or for all axes.
    /// - Parameters:
    ///   - axis: The plane axis whose cached frames should be removed; if `nil`, all cached MPR frames are invalidated.
    func invalidateMPRCache(axis: MPRPlaneAxis? = nil) {
        if let axis {
            mprFrameCache.invalidate(axis)
        } else {
            mprFrameCache.invalidateAll()
        }
    }

    /// Builds a volume transfer function using the controller's configured transfer function or falls back to a dataset default.
    /// 
    /// If a configured transfer function is available, its sanitized colour and alpha control points are converted into
    /// `VolumeTransferFunction.ColourControlPoint` and `VolumeTransferFunction.OpacityControlPoint`, with each point's
    /// `intensity` increased by the transfer function's `shift`. If the configured transfer function is `nil` or either
    /// the resulting colour or alpha point lists are empty, returns `VolumeTransferFunction.defaultGrayscale(for:)` for the provided dataset.
    /// - Parameter dataset: The dataset used to produce a default grayscale transfer function when no valid configured transfer function is available.
    /// - Returns: A `VolumeTransferFunction` built from the configured transfer function's sanitized points, or the dataset's default grayscale transfer function.
    func makeVolumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        guard let transferFunction else {
            return VolumeTransferFunction.defaultGrayscale(for: dataset)
        }

        let colourPoints = transferFunction
            .sanitizedColourPoints()
            .map { point in
                VolumeTransferFunction.ColourControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    colour: SIMD4<Float>(
                        point.colourValue.r,
                        point.colourValue.g,
                        point.colourValue.b,
                        point.colourValue.a
                    )
                )
            }
        let alphaPoints = transferFunction
            .sanitizedAlphaPoints()
            .map { point in
                VolumeTransferFunction.OpacityControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    opacity: point.alphaValue
                )
            }

        if colourPoints.isEmpty || alphaPoints.isEmpty {
            return VolumeTransferFunction.defaultGrayscale(for: dataset)
        }
        return VolumeTransferFunction(opacityPoints: alphaPoints, colourPoints: colourPoints)
    }

}

extension VolumeViewportController {
    /// Computes the display transform for the specified MPR axis, using cached plane geometry when available.
    /// - Parameter axis: The viewport axis to compute the transform for.
    /// - Returns: An `MPRDisplayTransform` constructed from a cached frame's plane geometry if present; otherwise from a canonical transform when no dataset is applied, or from a drawable-sized MPR plane for the current axis and index.
    func currentDisplayTransform(for axis: Axis) -> MPRDisplayTransform {
        let planeAxis = axis.mprPlaneAxis
        if let frame = mprFrameCache.storedFrame(for: planeAxis) {
            return MPRDisplayTransformFactory.makeTransform(for: frame.planeGeometry,
                                                            axis: planeAxis)
        }
        guard datasetApplied else {
            return MPRDisplayTransformFactory.makeTransform(for: .canonical(axis: planeAxis),
                                                            axis: planeAxis)
        }

        let planeIndex: Int
        if case let .mpr(currentAxis, index, _, _) = currentDisplay,
           currentAxis == axis {
            planeIndex = index
        } else {
            planeIndex = clampedIndex(for: axis, index: mprPlaneIndex)
        }

        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        return MPRDisplayTransformFactory.makeTransform(for: plane,
                                                        axis: planeAxis)
    }
}

extension VolumeViewportController {
    /// Computes the normalized position of a slice index along the given axis.
    /// - Returns: A Float in the range 0 to 1 representing the slice position (index / maxIndex) for the specified axis; returns 0.5 if the dataset is not available.
    func normalizedPosition(for axis: Axis, index: Int) -> Float {
        guard let dataset else { return 0.5 }
        let maxIndex: Float
        switch axis {
        case .x:
            maxIndex = max(1, Float(dataset.dimensions.width - 1))
        case .y:
            maxIndex = max(1, Float(dataset.dimensions.height - 1))
        case .z:
            maxIndex = max(1, Float(dataset.dimensions.depth - 1))
        }
        return VolumetricMath.clampFloat(Float(index) / maxIndex, lower: 0, upper: 1)
    }

    /// Converts a normalized position along the given axis into the corresponding slice index.
    /// - Parameters:
    ///   - axis: The axis to convert the position for.
    ///   - normalized: A position in the range 0…1; values outside this range are clamped to that interval.
    /// - Returns: The slice index for the dataset along `axis`, computed by scaling `normalized` to the axis length and rounding to the nearest integer; returns `0` if no dataset is available.
    func indexPosition(for axis: Axis, normalized: Float) -> Int {
        guard let dataset else { return 0 }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        switch axis {
        case .x:
            return Int(round(clamped * Float(max(0, dataset.dimensions.width - 1))))
        case .y:
            return Int(round(clamped * Float(max(0, dataset.dimensions.height - 1))))
        case .z:
            return Int(round(clamped * Float(max(0, dataset.dimensions.depth - 1))))
        }
    }

    /// Clamp an axial slice index to the valid range for the current dataset.
    /// 
    /// If no dataset is available, returns `0`. Otherwise clamps `index` to the inclusive range
    /// [0, dimension - 1] for the specified `axis`.
    /// - Parameters:
    ///   - axis: The axis whose valid index range to use (.x, .y, or .z).
    ///   - index: The requested slice index to clamp.
    /// - Returns: The clamped slice index within the dataset bounds, or `0` if the dataset is missing.
    func clampedIndex(for axis: Axis, index: Int) -> Int {
        guard let dataset else { return 0 }
        switch axis {
        case .x:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.width - 1))
        case .y:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.height - 1))
        case .z:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.depth - 1))
        }
    }

    /// Provide dataset dimensions in voxel coordinates.
    /// - Returns: A SIMD3<Float> with (width, height, depth) in voxels; `(1, 1, 1)` if no dataset is available.
    func datasetDimensions() -> SIMD3<Float> {
        guard let dataset else { return SIMD3<Float>(1, 1, 1) }
        return MprPlaneComputation.datasetDimensions(width: dataset.dimensions.width,
                                                     height: dataset.dimensions.height,
                                                     depth: dataset.dimensions.depth)
    }

    /// Creates a normalized rotation quaternion from Euler angles.
    /// - Parameter euler: Rotation angles in radians where `x`, `y`, `z` are rotations about the X-, Y-, and Z-axes respectively; applied in X → Y → Z order.
    /// - Returns: A normalized `simd_quatf` representing the composed rotation.
    func rotationQuaternion(for euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }

    /// Constructs an MPR plane geometry for the given axis and slice index using the current dataset dimensions and MPR rotation.
    /// - Parameters:
    ///   - axis: The volume axis along which to create the plane.
    ///   - index: The slice index along `axis` to generate the plane for.
    /// - Returns: An `MPRPlaneGeometry` containing voxel-space origins/axes, world-space origins/axes, texture-space origins/axes, and the plane's world-space normal.
    func makeMprPlane(axis: Axis, index: Int) -> MPRPlaneGeometry {
        let dims = datasetDimensions()
        let plane = MprPlaneComputation.make(axis: axis,
                                             index: index,
                                             dims: dims,
                                             rotation: rotationQuaternion(for: mprEuler))
        if let geometry {
            let world = plane.world(using: geometry)
            let tex = geometry.planeWorldToTex(originW: world.origin,
                                               axisUW: world.axisU,
                                               axisVW: world.axisV)
            let normal = safeNormalize(simd_cross(world.axisU, world.axisV), fallback: SIMD3<Float>(0, 0, 1))
            return MPRPlaneGeometry(originVoxel: plane.originVoxel,
                                    axisUVoxel: plane.axisUVoxel,
                                    axisVVoxel: plane.axisVVoxel,
                                    originWorld: world.origin,
                                    axisUWorld: world.axisU,
                                    axisVWorld: world.axisV,
                                    originTexture: tex.originT,
                                    axisUTexture: tex.axisUT,
                                    axisVTexture: tex.axisVT,
                                    normalWorld: normal)
        } else {
            let tex = plane.tex(dims: dims)
            let normal = safeNormalize(simd_cross(tex.axisU, tex.axisV), fallback: SIMD3<Float>(0, 0, 1))
            return MPRPlaneGeometry(originVoxel: plane.originVoxel,
                                    axisUVoxel: plane.axisUVoxel,
                                    axisVVoxel: plane.axisVVoxel,
                                    originWorld: plane.originVoxel,
                                    axisUWorld: plane.axisUVoxel,
                                    axisVWorld: plane.axisVVoxel,
                                    originTexture: tex.origin,
                                    axisUTexture: tex.axisU,
                                    axisVTexture: tex.axisV,
                                    normalWorld: normal)
        }
    }

    /// Aligns the camera to face and center on the currently selected MPR plane.
    /// 
    /// If a dataset is applied and a current MPR axis exists, updates the controller's camera to look at the dataset volume center from a distance computed from the volume bounding radius; sets the camera target, offset, and up vector and snapshots those values into the corresponding initial camera properties, then publishes the updated camera state. Otherwise does nothing.
    func alignCameraToCurrentMprPlane() {
        guard datasetApplied, let axis = currentMprAxis else { return }
        let plane = makeMprPlane(axis: axis, index: mprPlaneIndex)
        let normal = safeNormalize(plane.normalWorld, fallback: SIMD3<Float>(0, 0, 1))
        let up = safeNormalize(plane.axisVWorld, fallback: fallbackWorldUp)
        let distance = max(volumeBoundingRadius * defaultCameraDistanceFactor, volumeBoundingRadius * 1.25, 1.5)
        cameraTarget = volumeWorldCenter
        cameraOffset = normal * distance
        cameraUpVector = up
        initialCameraTarget = cameraTarget
        initialCameraOffset = cameraOffset
        initialCameraUp = up
        publishCameraState()
    }
}

extension VolumeViewportController.Axis {
    var mprPlaneAxis: MPRPlaneAxis {
        MPRPlaneAxis(rawValue: rawValue) ?? .z
    }
}
