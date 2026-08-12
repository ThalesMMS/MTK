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

    public var displayAspectRatio: Float {
        displayTransform.displayAspectRatio(forSourceAspectRatio: plane.physicalAspectRatio)
    }

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
                                   precomputedPlane: MPRPlaneGeometry? = nil,
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
        let plane = precomputedPlane ?? makePlane(for: dataset,
                                                  axis: axis,
                                                  slicePosition: resolvedSlicePosition,
                                                  rotation: planeRotation)
        let referencePlane = makePlane(for: dataset,
                                       axis: axis,
                                       slicePosition: resolvedSlicePosition)
        let displayTransform = MPRDisplayTransformFactory.makeTransform(for: plane,
                                                                       axis: axis,
                                                                       referencePlane: referencePlane)
        let displayAspectRatio = displayTransform.displayAspectRatio(
            forSourceAspectRatio: plane.physicalAspectRatio
        )
        let resolvedAspect = outputAspect ?? .aspectFit(physicalAspectRatio: displayAspectRatio)
        return MPRGeometryDisplayContext(
            dataset: dataset,
            axis: axis,
            slicePosition: resolvedSlicePosition,
            plane: plane,
            displayTransform: displayTransform,
            viewportTransform: viewportTransform,
            outputAspect: resolvedAspect,
            presentationLayout: resolvedAspect.layout(
                destinationSize: viewportSize,
                viewportTransform: viewportTransform
            ),
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

        return makeRotatedPlane(for: dataset,
                                axis: axis,
                                slicePosition: clampNormalized(slicePosition),
                                rotation: rotation)
    }

    /// The plane through a crosshair point — the path the clinical grid uses
    /// once a cursor exists, so it is the one a rotation gesture actually
    /// exercises.
    ///
    /// Like every other path here it keeps the resting rectangle's physical
    /// extents (see `rotatedAxes`); only the rectangle's position differs. Do
    /// not size it to the volume's bounds projected on the tilted axes, however
    /// natural that looks — those bounds grow with the tilt and the panel
    /// aspect-fits the rectangle, so the anatomy in the other two panels
    /// rescales as the user rotates.
    public static func makePlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 through worldPoint: SIMD3<Float>,
                                 rotation: simd_quatf? = nil) -> MPRPlaneGeometry {
        makePlane(for: dataset,
                  axis: axis,
                  through: worldPoint,
                  rotation: rotation ?? identityRotation())
    }

    public static func makePlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 sliceIndex: Int,
                                 rotation: simd_quatf) -> MPRPlaneGeometry {
        let count = sliceCount(for: axis, dimensions: dataset.dimensions)
        let index = max(0, min(sliceIndex, max(count - 1, 0)))
        let slicePosition = count > 1 ? Float(index) / Float(count - 1) : 0
        return makeRotatedPlane(for: dataset,
                                axis: axis,
                                slicePosition: slicePosition,
                                rotation: rotation)
    }

    /// Returns the unrotated plane basis used by renderer-generated MPR planes.
    public static func makeDisplayReferencePlane(for dataset: VolumeDataset,
                                                 axis: MPRPlaneAxis,
                                                 slicePosition: Float) -> MPRPlaneGeometry {
        rotationReferencePlane(for: dataset,
                               axis: axis,
                               slicePosition: clampNormalized(slicePosition))
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
    typealias RotatedPlaneAxes = (
        axisUWorld: SIMD3<Float>,
        axisVWorld: SIMD3<Float>,
        normalWorld: SIMD3<Float>
    )

    static func makePlane(for dataset: VolumeDataset,
                          axis: MPRPlaneAxis,
                          through worldPoint: SIMD3<Float>,
                          rotation: simd_quatf) -> MPRPlaneGeometry {
        let reference = rotationReferencePlane(
            for: dataset,
            axis: axis,
            slicePosition: 0.5
        )
        let axes = rotatedAxes(for: dataset, reference: reference, rotation: rotation)
        let volumeCenterWorld = reference.originWorld
            + reference.axisUWorld * 0.5
            + reference.axisVWorld * 0.5
        let planeCenterWorld = volumeCenterWorld
            + axes.normalWorld * simd_dot(worldPoint - volumeCenterWorld, axes.normalWorld)

        return makePlane(
            for: dataset,
            centerWorld: rectangleCenter(containing: worldPoint,
                                         planeCenter: planeCenterWorld,
                                         axes: axes),
            axes: axes
        )
    }

    static func makeRotatedPlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 slicePosition: Float,
                                 rotation: simd_quatf) -> MPRPlaneGeometry {
        let reference = rotationReferencePlane(
            for: dataset,
            axis: axis,
            slicePosition: slicePosition
        )
        let centerWorld = reference.originWorld
            + reference.axisUWorld * 0.5
            + reference.axisVWorld * 0.5

        return makePlane(for: dataset,
                         centerWorld: centerWorld,
                         axes: rotatedAxes(for: dataset,
                                           reference: reference,
                                           rotation: rotation))
    }

    /// Rigidly rotates the reference basis: the rectangle tilts, but keeps the
    /// physical extents it had at rest, so tilting one plane never rescales what
    /// the other panels show.
    static func rotatedAxes(for dataset: VolumeDataset,
                            reference: MPRPlaneGeometry,
                            rotation: simd_quatf) -> RotatedPlaneAxes {
        let patientBasis = patientDirectionBasis(for: dataset)
        let worldRotation = patientBasis
            * simd_float3x3(normalizedRotation(rotation))
            * patientBasis.transpose
        let axisUWorld = worldRotation * reference.axisUWorld
        let axisVWorld = worldRotation * reference.axisVWorld
        let normalWorld = normalized(cross: axisUWorld,
                                     axisVWorld,
                                     fallback: worldRotation * reference.normalWorld)
        return (axisUWorld, axisVWorld, normalWorld)
    }

    static func makePlane(for dataset: VolumeDataset,
                          centerWorld: SIMD3<Float>,
                          axes: RotatedPlaneAxes) -> MPRPlaneGeometry {
        let geometry = DICOMGeometry(imageData: dataset.imageData)
        let originWorld = centerWorld - axes.axisUWorld * 0.5 - axes.axisVWorld * 0.5
        let originVoxel = geometry.worldToVoxel.transformPoint(originWorld)
        let axisUVoxel = geometry.worldToVoxel
            .transformPoint(originWorld + axes.axisUWorld) - originVoxel
        let axisVVoxel = geometry.worldToVoxel
            .transformPoint(originWorld + axes.axisVWorld) - originVoxel
        let textureBasis = geometry.planeWorldToTex(originW: originWorld,
                                                    axisUW: axes.axisUWorld,
                                                    axisVW: axes.axisVWorld)

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisUVoxel,
            axisVVoxel: axisVVoxel,
            originWorld: originWorld,
            axisUWorld: axes.axisUWorld,
            axisVWorld: axes.axisVWorld,
            originTexture: textureBasis.originT,
            axisUTexture: textureBasis.axisUT,
            axisVTexture: textureBasis.axisVT,
            normalWorld: axes.normalWorld
        )
    }

    /// Slides the rectangle within its own plane by the smallest amount that
    /// puts `worldPoint` back onto it, and leaves it alone while the point is
    /// already inside.
    ///
    /// Sizing the rectangle to the volume's bounds projected on the tilted axes
    /// would contain every point without sliding, but those bounds grow with the
    /// tilt — and because the panel aspect-fits the rectangle, the anatomy in the
    /// *other* two panels shrank as the crosshair was rotated. Extents stay
    /// fixed and the window moves instead; the tilted corners that leave the
    /// volume are drawn as background.
    static func rectangleCenter(containing worldPoint: SIMD3<Float>,
                                planeCenter: SIMD3<Float>,
                                axes: RotatedPlaneAxes) -> SIMD3<Float> {
        guard let coordinates = planeCoordinates(of: worldPoint - planeCenter,
                                                 axes: axes) else {
            return planeCenter
        }
        let overflow = coordinates - simd_clamp(coordinates,
                                                SIMD2<Float>(repeating: -0.5),
                                                SIMD2<Float>(repeating: 0.5))
        return planeCenter
            + axes.axisUWorld * overflow.x
            + axes.axisVWorld * overflow.y
    }

    /// Expresses `offset` in the rectangle's own `(axisU, axisV)` coordinates —
    /// the coordinates the presentation shader samples with. Gantry-tilted
    /// acquisitions leave that basis non-orthogonal, so this solves the 2×2 Gram
    /// system instead of projecting onto each axis alone.
    static func planeCoordinates(of offset: SIMD3<Float>,
                                 axes: RotatedPlaneAxes) -> SIMD2<Float>? {
        let uu = simd_length_squared(axes.axisUWorld)
        let vv = simd_length_squared(axes.axisVWorld)
        let uv = simd_dot(axes.axisUWorld, axes.axisVWorld)
        let determinant = uu * vv - uv * uv
        guard determinant > Float.ulpOfOne else { return nil }

        let offsetU = simd_dot(offset, axes.axisUWorld)
        let offsetV = simd_dot(offset, axes.axisVWorld)
        return SIMD2<Float>((offsetU * vv - offsetV * uv) / determinant,
                            (offsetV * uu - offsetU * uv) / determinant)
    }

    /// The basis a rotated plane is built from.
    ///
    /// This used to reverse `axisU` for the coronal plane — origin moved to the
    /// far edge, `axisU` negated, and the normal recomputed to keep the triad
    /// right-handed. That last part is what made it look harmless: the triad
    /// stayed right-handed, but the plane's normal reversed with it, so a
    /// rotated coronal was viewed from the opposite side of the patient.
    ///
    /// The coronal plane the factory produces has `axisU` running in −x, which
    /// is the radiological convention baked into the geometry. Reversing it here
    /// applied only when a rotation was present, so the coronal image mirrored
    /// horizontally the instant the crosshair was first tilted, and rotations
    /// about the longitudinal axis then read backwards — one sign change, both
    /// symptoms (issue #1657).
    ///
    /// Left as a named function rather than inlined: the invariant that the
    /// rotated and unrotated bases are the same one is the point, and
    /// `makeDisplayReferencePlane` publishes it.
    static func rotationReferencePlane(
        for dataset: VolumeDataset,
        axis: MPRPlaneAxis,
        slicePosition: Float
    ) -> MPRPlaneGeometry {
        MPRPlaneGeometryFactory.makePlane(
            for: dataset,
            axis: axis,
            slicePosition: slicePosition
        )
    }

    static func normalizedRotation(_ rotation: simd_quatf) -> simd_quatf {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        if rotation.real == 0, rotation.imag == .zero {
            return identity
        }
        return simd_normalize(rotation)
    }

    static func identityRotation() -> simd_quatf {
        simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    static func patientDirectionBasis(for dataset: VolumeDataset) -> simd_float3x3 {
        let row = normalized(
            vector: dataset.imageData.rowDirection,
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let columnCandidate = dataset.imageData.columnDirection -
            simd_dot(dataset.imageData.columnDirection, row) * row
        let column = normalized(vector: columnCandidate, fallback: SIMD3<Float>(0, 1, 0))
        var slice = normalized(cross: row, column, fallback: SIMD3<Float>(0, 0, 1))
        if simd_dot(slice, dataset.imageData.sliceDirection) < 0 {
            slice = -slice
        }
        return simd_float3x3(columns: (row, column, slice))
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
