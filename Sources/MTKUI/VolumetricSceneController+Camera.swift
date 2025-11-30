//
//  VolumetricSceneController+Camera.swift
//  MetalVolumetrics
//
//  Camera utilities and MPR support extracted for maintainability.
#if os(iOS) || os(macOS)
//
import Foundation
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
import MTKCore
import MTKSceneKit

@MainActor public extension VolumetricSceneController {
    func applyPatientOrientationIfNeeded() {
        guard let geometry else {
            volumeNode.simdOrientation = simd_quatf()
            return
        }
        let basis = patientBasis(from: geometry)
        let quaternion = simd_normalize(simd_quatf(basis))
        volumeNode.simdOrientation = quaternion
    }

    @discardableResult
    func ensureCameraNode() -> SCNNode {
        if let existing = sceneView.pointOfView {
            if existing.parent == nil {
                rootNode.addChildNode(existing)
            }
            sceneView.defaultCameraController.pointOfView = existing
            return existing
        }

        let cameraNode = SCNNode()
        cameraNode.name = "Volumetric.Camera"
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)
        cameraNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
        rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        sceneView.defaultCameraController.pointOfView = cameraNode
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: volumeBoundingRadius,
                                   offsetLength: simd_length(cameraOffset))
        return cameraNode
    }

    /// Usa a geometria extraída do dataset para posicionar a câmera sobre o
    /// volume: o normal define o eixo de observação, a coluna define o `up`, e
    /// ambos alimentam o estado interativo e o transform de fallback gravado
    /// para futuras reativações da cena.
    func configureCamera(using geometry: DICOMGeometry) {
        let cameraNode = ensureCameraNode()
        updateVolumeBounds()
        let center = volumeWorldCenter
        let normal = safeNormalize(geometry.iopNorm, fallback: SIMD3<Float>(0, 0, 1))
        let up = safeNormalize(geometry.iopCol, fallback: SIMD3<Float>(0, 1, 0))
        let radius = max(volumeBoundingRadius, 1e-3)
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25)
        let position = center + normal * distance
        let transform = makeLookAtTransform(position: position, target: center, up: up)

        cameraNode.simdTransform = transform
        fallbackCameraTransform = transform
        initialCameraTransform = transform
        fallbackWorldUp = up
        fallbackCameraTarget = center
        patientLongitudinalAxis = safeNormalize(normal, fallback: patientLongitudinalAxis)
        sceneView.defaultCameraController.pointOfView = cameraNode
        updateInteractiveCameraState(target: center, up: up, cameraNode: cameraNode, radius: radius)
        defaultCameraTarget = SCNVector3(x: SCNFloat(center.x),
                                         y: SCNFloat(center.y),
                                         z: SCNFloat(center.z))
        prepareCameraControllerForExternalGestures(worldUp: up)
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: radius,
                                   offsetLength: simd_length(cameraOffset))
    }

    func restoreFallbackCamera() {
        let cameraNode = ensureCameraNode()
        updateVolumeBounds()
        if let transform = fallbackCameraTransform {
            cameraNode.simdTransform = transform
        }
        sceneView.defaultCameraController.pointOfView = cameraNode
        let radius = max(volumeBoundingRadius, 1e-3)
        updateInteractiveCameraState(target: fallbackCameraTarget,
                                      up: fallbackWorldUp,
                                      cameraNode: cameraNode,
                                      radius: radius)
        defaultCameraTarget = SCNVector3(x: SCNFloat(fallbackCameraTarget.x),
                                         y: SCNFloat(fallbackCameraTarget.y),
                                         z: SCNFloat(fallbackCameraTarget.z))
        prepareCameraControllerForExternalGestures()
    }

    func synchronizeMprNodeTransform() {
        mprNode.simdTransform = volumeNode.simdTransform
    }

    func updateInteractiveCameraState(target: SIMD3<Float>,
                                      up: SIMD3<Float>,
                                      cameraNode: SCNNode,
                                      radius: Float) {
        cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        let clampedTarget = clampCameraTarget(target)
        cameraTarget = clampedTarget
        cameraUpVector = safeNormalize(up, fallback: fallbackWorldUp)
        cameraOffset = cameraNode.simdWorldPosition - clampedTarget
        cameraOffset = clampCameraOffset(cameraOffset)
        defaultCameraTarget = SCNVector3(x: SCNFloat(cameraTarget.x),
                                         y: SCNFloat(cameraTarget.y),
                                         z: SCNFloat(cameraTarget.z))
        fallbackWorldUp = cameraUpVector
        updateCameraControllerTargets()
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: radius,
                                   offsetLength: simd_length(cameraOffset))
        recordCameraState(position: cameraTarget + cameraOffset,
                           target: cameraTarget,
                           up: cameraUpVector)
    }

    func applyInteractiveCameraTransform(_ cameraNode: SCNNode) {
        cameraTarget = clampCameraTarget(cameraTarget)
        cameraOffset = clampCameraOffset(cameraOffset)
        let position = cameraTarget + cameraOffset
        let forward = safeNormalize(cameraTarget - position, fallback: SIMD3<Float>(0, 0, -1))
        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)
        if abs(simd_dot(forward, up)) > 0.999 {
            up = safePerpendicular(to: forward)
        }
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        up = safeNormalize(simd_cross(right, forward), fallback: up)
        cameraUpVector = up
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        transform.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        transform.columns.2 = SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0)
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        cameraNode.simdTransform = transform
        defaultCameraTarget = SCNVector3(x: SCNFloat(cameraTarget.x),
                                         y: SCNFloat(cameraTarget.y),
                                         z: SCNFloat(cameraTarget.z))
        updateCameraControllerTargets()
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: volumeBoundingRadius,
                                   offsetLength: simd_length(cameraOffset))
#if canImport(MetalPerformanceShaders)
        if renderingBackend == .metalPerformanceShaders {
            updateRayCastingCache(cameraNode: cameraNode)
        }
#endif
        recordCameraState(position: position, target: cameraTarget, up: up)
    }

    func clampCameraOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length > Float.ulpOfOne else {
            let fallbackDistance = max(cameraDistanceLimits.lowerBound, 0.1)
            return SIMD3<Float>(0, 0, fallbackDistance)
        }
        let clamped = max(cameraDistanceLimits.lowerBound, min(length, cameraDistanceLimits.upperBound))
        let normalized = offset / length
        return normalized * clamped
    }

    func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        let minimum = max(radius * 0.25, 0.1)
        let maximum = max(radius * 12, minimum + 0.5)
        return minimum...maximum
    }

    func updateCameraControllerTargets() {
        let controller = sceneView.defaultCameraController
        guard controller.pointOfView != nil else { return }
        controller.target = SCNVector3(x: SCNFloat(cameraTarget.x),
                                       y: SCNFloat(cameraTarget.y),
                                       z: SCNFloat(cameraTarget.z))
        controller.worldUp = SCNVector3(x: SCNFloat(cameraUpVector.x),
                                        y: SCNFloat(cameraUpVector.y),
                                        z: SCNFloat(cameraUpVector.z))
    }

    func screenSpaceScale(distance: Float, cameraNode: SCNNode) -> (horizontal: Float, vertical: Float) {
        let bounds = sceneView.bounds
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let fallback: Float = 0.002
        guard height > Float.ulpOfOne else { return (fallback, fallback) }

        let fovDegrees = Float(cameraNode.camera?.fieldOfView ?? 60)
        let clampedFov = max(min(fovDegrees, 179), 1)
        let radians = clampedFov * Float.pi / 180
        let tangent = tan(Double(radians) / 2)
        let verticalScale = 2 * distance * Float(tangent) / height
        let aspect = width / height
        let horizontalScale = verticalScale * aspect

        if !verticalScale.isFinite || !horizontalScale.isFinite || verticalScale <= 0 || horizontalScale <= 0 {
            return (fallback, fallback)
        }
        return (horizontalScale, verticalScale)
    }

    func prepareCameraControllerForExternalGestures(worldUp: SIMD3<Float>? = nil) {
        sceneView.allowsCameraControl = false
        let cameraNode = ensureCameraNode()
        let controller = sceneView.defaultCameraController
        controller.inertiaEnabled = false
        if controller.pointOfView !== cameraNode {
            controller.pointOfView = cameraNode
        }
        controller.target = defaultCameraTarget
        let resolvedWorldUp = worldUp ?? cameraUpVector
        controller.worldUp = SCNVector3(x: SCNFloat(resolvedWorldUp.x),
                                        y: SCNFloat(resolvedWorldUp.y),
                                        z: SCNFloat(resolvedWorldUp.z))
        controller.clearRoll()
    }

    func updateVolumeBounds() {
        let node = volumeNode
        let worldTransform = node.simdWorldTransform

        let sphere = node.boundingSphere
        let localCenter = SIMD4<Float>(Float(sphere.center.x),
                                       Float(sphere.center.y),
                                       Float(sphere.center.z),
                                       1)
        var worldCenter = worldTransform * localCenter
        if !worldCenter.x.isFinite || !worldCenter.y.isFinite || !worldCenter.z.isFinite {
            worldCenter = worldTransform * SIMD4<Float>(0, 0, 0, 1)
        }
        volumeWorldCenter = SIMD3<Float>(worldCenter.x, worldCenter.y, worldCenter.z)

        let axisX = SIMD3<Float>(worldTransform.columns.0.x,
                                 worldTransform.columns.0.y,
                                 worldTransform.columns.0.z)
        let axisY = SIMD3<Float>(worldTransform.columns.1.x,
                                 worldTransform.columns.1.y,
                                 worldTransform.columns.1.z)
        let axisZ = SIMD3<Float>(worldTransform.columns.2.x,
                                 worldTransform.columns.2.y,
                                 worldTransform.columns.2.z)
        patientLongitudinalAxis = safeNormalize(axisZ, fallback: patientLongitudinalAxis)

        let lengthX = simd_length(axisX)
        let lengthY = simd_length(axisY)
        let lengthZ = simd_length(axisZ)

        let diagonalSquared = lengthX * lengthX + lengthY * lengthY + lengthZ * lengthZ
        var radius: Float = 0
        if diagonalSquared > Float.ulpOfOne {
            radius = 0.5 * sqrt(diagonalSquared)
        }

        if radius <= Float.ulpOfOne {
            let boundingBox = node.boundingBox
            let localMin = boundingBox.min
            let localMax = boundingBox.max

            if localMin.x <= localMax.x &&
                localMin.y <= localMax.y &&
                localMin.z <= localMax.z {
                let corners: [SIMD4<Float>] = [
                    SIMD4<Float>(Float(localMin.x), Float(localMin.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMin.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMax.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMax.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMin.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMin.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMax.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMax.y), Float(localMax.z), 1)
                ]

                for corner in corners {
                    let worldCorner = worldTransform * corner
                    let offset = SIMD3<Float>(worldCorner.x, worldCorner.y, worldCorner.z) - volumeWorldCenter
                    radius = max(radius, simd_length(offset))
                }
            }
        }

        if radius <= Float.ulpOfOne {
            let maxScale = max(lengthX, max(lengthY, lengthZ))
            if maxScale > Float.ulpOfOne {
                radius = Float(sphere.radius) * maxScale
            }
        }

        if radius <= Float.ulpOfOne {
            let scale = volumeMaterial.scale
            let diagonal = simd_length(scale)
            if diagonal > Float.ulpOfOne {
                radius = 0.5 * diagonal
            }
        }

        volumeBoundingRadius = max(radius, 1e-3)
    }

    func clampCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        let offset = target - volumeWorldCenter
        let limit = max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1.0)
        let distance = simd_length(offset)
        guard distance > limit else { return target }
        if distance <= Float.ulpOfOne {
            return volumeWorldCenter
        }
        return volumeWorldCenter + (offset / distance) * limit
    }

    func updateCameraClippingPlanes(_ camera: SCNCamera?, radius: Float, offsetLength: Float) {
        guard let camera else { return }

        let safeRadius = max(radius, 1e-3)
        let safeDistance = max(offsetLength, 1e-3)
        let margin = max(safeRadius * 0.05, 0.01)
        let near: Float
        if safeDistance <= safeRadius {
            near = max(0.01, safeDistance * 0.1)
        } else {
            near = max(0.01, safeDistance - safeRadius - margin)
        }

        let far = max(near + margin, safeDistance + safeRadius + margin)

        camera.zNear = Double(near)
        camera.zFar = Double(far)
    }

    func patientBasis(from geometry: DICOMGeometry) -> simd_float3x3 {
        let row = safeNormalize(geometry.iopRow, fallback: SIMD3<Float>(1, 0, 0))
        var column = safeNormalize(geometry.iopCol, fallback: SIMD3<Float>(0, 1, 0))
        let cross = simd_cross(row, column)
        if simd_length_squared(cross) <= Float.ulpOfOne {
            column = safePerpendicular(to: row)
        }
        var normal = simd_cross(row, column)
        if simd_length_squared(normal) <= Float.ulpOfOne {
            normal = SIMD3<Float>(0, 0, 1)
        }
        normal = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        column = safeNormalize(simd_cross(normal, row), fallback: SIMD3<Float>(0, 1, 0))
        return simd_float3x3(columns: (row, column, normal))
    }

    func makeLookAtTransform(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = safeNormalize(target - position, fallback: SIMD3<Float>(0, 0, -1))
        var right = simd_cross(up, forward)
        right = safeNormalize(right, fallback: safePerpendicular(to: forward))
        let correctedUp = safeNormalize(simd_cross(forward, right), fallback: SIMD3<Float>(0, 1, 0))
        let rotation = simd_float3x3(columns: (right, correctedUp, -forward))
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(rotation.columns.0.x, rotation.columns.0.y, rotation.columns.0.z, 0)
        transform.columns.1 = SIMD4<Float>(rotation.columns.1.x, rotation.columns.1.y, rotation.columns.1.z, 0)
        transform.columns.2 = SIMD4<Float>(rotation.columns.2.x, rotation.columns.2.y, rotation.columns.2.z, 0)
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }

    func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let perpendicular = simd_cross(vector, axis)
        return safeNormalize(perpendicular, fallback: SIMD3<Float>(0, 0, 1))
    }

#if canImport(MetalPerformanceShaders)
    func prepareMpsResourcesForDataset(_ dataset: VolumeDataset) {
        guard let renderer = mpsRenderer else { return }
        do {
            mpsFilteredTexture = try renderer.applyGaussianFilter(dataset: dataset,
                                                                   sigma: mpsGaussianSigma)
            if renderingBackend == .metalPerformanceShaders,
               let filtered = mpsFilteredTexture {
                volumeMaterial.setDataset(device: device,
                                           dataset: dataset,
                                           volumeTexture: filtered)
                mprMaterial.setDataset(device: device,
                                       dataset: dataset,
                                       volumeTexture: filtered)
            }
        } catch {
            logger.error("Failed to prepare MPS Gaussian filter", error: error)
            mpsFilteredTexture = nil
        }
        if renderingBackend == .metalPerformanceShaders {
            let cameraNode = ensureCameraNode()
            updateRayCastingCache(cameraNode: cameraNode)
        }
    }

    func updateRayCastingCache(cameraNode: SCNNode) {
        guard renderingBackend == .metalPerformanceShaders else { return }
        guard datasetApplied, let dataset else {
            lastRayCastingSamples = []
            lastRayCastingWorldEntries = []
            return
        }
        guard let renderer = mpsRenderer else { return }

        let raysResult = makeCameraRays(cameraNode: cameraNode, dataset: dataset)
        guard !raysResult.rays.isEmpty else {
            lastRayCastingSamples = []
            lastRayCastingWorldEntries = []
            return
        }

        do {
            let samples = try renderer.performBoundingBoxRayCast(dataset: dataset,
                                                                 rays: raysResult.rays)
            lastRayCastingSamples = samples
            var worldEntries: [Float] = []
            worldEntries.reserveCapacity(samples.count)
            for (index, sample) in samples.enumerated() {
                let scale = index < raysResult.scales.count ? raysResult.scales[index] : 1
                let normalizedScale = max(scale, Float.ulpOfOne)
                worldEntries.append(sample.entryDistance / normalizedScale)
            }
            lastRayCastingWorldEntries = worldEntries
#if canImport(MetalKit)
            mpsDisplay?.updateRayCasting(samples: samples)
#endif
        } catch {
            logger.error("Failed to perform bounding box ray cast", error: error)
            lastRayCastingSamples = []
            lastRayCastingWorldEntries = []
        }
    }

    func makeCameraRays(cameraNode: SCNNode,
                         dataset: VolumeDataset) -> (rays: [MPSVolumeRenderer.Ray],
                                                      scales: [Float]) {
        let position = cameraNode.simdWorldPosition
        let target = cameraTarget
        let forward = safeNormalize(target - position, fallback: SIMD3<Float>(0, 0, -1))
        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)
        if abs(simd_dot(forward, up)) > 0.999 {
            up = safePerpendicular(to: forward)
        }
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        up = safeNormalize(simd_cross(right, forward), fallback: up)

        let bounds = sceneView.bounds
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let aspect = width / height
        let fovDegrees = Float(cameraNode.camera?.fieldOfView ?? 60)
        let radians = max(1, min(fovDegrees, 179)) * Float.pi / 180
        let halfHeight = Float(tan(Double(radians) / 2))
        let halfWidth = halfHeight * aspect

        let directions: [SIMD3<Float>] = [
            forward,
            safeNormalize(forward - right * halfWidth + up * halfHeight, fallback: forward),
            safeNormalize(forward + right * halfWidth + up * halfHeight, fallback: forward),
            safeNormalize(forward - right * halfWidth - up * halfHeight, fallback: forward),
            safeNormalize(forward + right * halfWidth - up * halfHeight, fallback: forward)
        ]

        let geometry = self.geometry ?? makeGeometry(from: dataset)
        guard let originDataset = convertWorldPointToDatasetSpace(position, geometry: geometry) else {
            return ([], [])
        }

        var rays: [MPSVolumeRenderer.Ray] = []
        var scales: [Float] = []
        rays.reserveCapacity(directions.count)
        scales.reserveCapacity(directions.count)
        for direction in directions {
            guard let datasetDirection = convertWorldDirectionToDatasetSpace(direction, geometry: geometry) else { continue }
            let magnitude = simd_length(datasetDirection)
            guard magnitude > Float.ulpOfOne else { continue }
            let ray = MPSVolumeRenderer.Ray(origin: originDataset, direction: datasetDirection)
            rays.append(ray)
            scales.append(magnitude)
        }
        return (rays, scales)
    }

    func convertWorldPointToDatasetSpace(_ point: SIMD3<Float>,
                                         geometry: DICOMGeometry) -> SIMD3<Float>? {
        let world = SIMD4<Float>(point.x, point.y, point.z, 1)
        let voxel = geometry.worldToVoxel * world
        guard voxel.w != 0 else { return nil }
        let normalized = voxel / voxel.w
        let spacing = SIMD3<Float>(geometry.spacingX, geometry.spacingY, geometry.spacingZ)
        return SIMD3<Float>(normalized.x * spacing.x,
                            normalized.y * spacing.y,
                            normalized.z * spacing.z)
    }

    func convertWorldDirectionToDatasetSpace(_ direction: SIMD3<Float>,
                                             geometry: DICOMGeometry) -> SIMD3<Float>? {
        let vector = geometry.worldToVoxel * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
        let spacing = SIMD3<Float>(geometry.spacingX, geometry.spacingY, geometry.spacingZ)
        let datasetDirection = SIMD3<Float>(vector.x * spacing.x,
                                            vector.y * spacing.y,
                                            vector.z * spacing.z)
        if !datasetDirection.x.isFinite || !datasetDirection.y.isFinite || !datasetDirection.z.isFinite {
            return nil
        }
        return datasetDirection
    }
#endif

    func normalizedPosition(for axis: Axis, index: Int) -> Float {
        let dim = mprMaterial.dimension
        let maxIndex: Float
        switch axis {
        case .x:
            maxIndex = max(1.0, Float(dim.x - 1))
        case .y:
            maxIndex = max(1.0, Float(dim.y - 1))
        case .z:
            maxIndex = max(1.0, Float(dim.z - 1))
        }
        let clamped = Float(index)
        return clampFloat(clamped / maxIndex, lower: 0.0, upper: 1.0)
    }

    func indexPosition(for axis: Axis, normalized: Float) -> Int {
        let clamped = clampFloat(normalized, lower: 0.0, upper: 1.0)
        let dim = mprMaterial.dimension
        switch axis {
        case .x:
            return Int(round(clamped * Float(max(0, dim.x - 1))))
        case .y:
            return Int(round(clamped * Float(max(0, dim.y - 1))))
        case .z:
            return Int(round(clamped * Float(max(0, dim.z - 1))))
        }
    }

    func clampedIndex(for axis: Axis, index: Int) -> Int {
        let dim = mprMaterial.dimension
        switch axis {
        case .x:
            return max(0, min(Int(dim.x) - 1, index))
        case .y:
            return max(0, min(Int(dim.y) - 1, index))
        case .z:
            return max(0, min(Int(dim.z) - 1, index))
        }
    }

    func applyMprOrientation() {
        guard datasetApplied, let axis = currentMprAxis else { return }
        let rotation = rotationQuaternion(for: mprEuler)
        let dims = datasetDimensions()
        let plane = MprPlaneComputation.make(
            axis: axis,
            index: mprPlaneIndex,
            dims: dims,
            rotation: rotation
        )

        let normal: SIMD3<Float>
        let up: SIMD3<Float>

        mprMaterial.setVerticalFlip(axis == .z)

        if let geometry {
            let world = plane.world(using: geometry)
            let (originTex, axisUT, axisVT) = geometry.planeWorldToTex(
                originW: world.origin,
                axisUW: world.axisU,
                axisVW: world.axisV
            )

            mprMaterial.setOblique(origin: originTex, axisU: axisUT, axisV: axisVT)
            mprNode.setTransformFromBasisTex(originTex: originTex, axisUTex: axisUT, axisVTex: axisVT)

            normal = safeNormalize(simd_cross(world.axisU, world.axisV), fallback: fallbackWorldUp)
            up = safeNormalize(world.axisV, fallback: fallbackWorldUp)
        } else {
            mprNode.simdOrientation = rotation
            let fallback = plane.tex(dims: dims)
            mprMaterial.setOblique(origin: fallback.origin, axisU: fallback.axisU, axisV: fallback.axisV)

            normal = safeNormalize(simd_cross(fallback.axisU, fallback.axisV), fallback: SIMD3<Float>(0, 0, 1))
            up = safeNormalize(fallback.axisV, fallback: SIMD3<Float>(0, 1, 0))
        }

        alignCameraToMpr(normal: normal, up: up)
    }

    func alignCameraToMpr(normal: SIMD3<Float>, up: SIMD3<Float>) {
        let cameraNode = ensureCameraNode()

        let safeNormal = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        let safeUp = safeNormalize(up, fallback: fallbackWorldUp)
        updateVolumeBounds()
        let center = volumeWorldCenter
        let radius = max(volumeBoundingRadius, 1e-3)
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25)
        let position = center + safeNormal * distance
        let transform = makeLookAtTransform(position: position, target: center, up: safeUp)

        cameraNode.simdTransform = transform
        fallbackCameraTransform = transform
        initialCameraTransform = transform
        fallbackWorldUp = safeUp
        sceneView.defaultCameraController.pointOfView = cameraNode
        defaultCameraTarget = SCNVector3(center)
        sceneView.defaultCameraController.target = defaultCameraTarget
        sceneView.defaultCameraController.worldUp = SCNVector3(safeUp)
        sceneView.defaultCameraController.clearRoll()
    }

    func rotationQuaternion(for euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }

    func datasetDimensions() -> SIMD3<Float> {
        let dims = mprMaterial.dimension
        return MprPlaneComputation.datasetDimensions(width: Int(dims.x), height: Int(dims.y), depth: Int(dims.z))
    }

    func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        let orientation = dataset.orientation
        return DICOMGeometry(
            cols: Int32(dataset.dimensions.width),
            rows: Int32(dataset.dimensions.height),
            slices: Int32(dataset.dimensions.depth),
            spacingX: Float(dataset.spacing.x),
            spacingY: Float(dataset.spacing.y),
            spacingZ: Float(dataset.spacing.z),
            iopRow: orientation.row,
            iopCol: orientation.column,
            ipp0: orientation.origin
        )
    }
#if canImport(UIKit)
    func attachAdaptiveHandlersIfNeeded() {
        guard let recognizers = sceneView.gestureRecognizers else { return }
        for recognizer in recognizers {
            let identifier = ObjectIdentifier(recognizer)
            if adaptiveRecognizers.contains(identifier) { continue }
            recognizer.addTarget(self, action: #selector(handleAdaptiveGesture(_:)))
            adaptiveRecognizers.insert(identifier)
        }
    }

    @objc func handleAdaptiveGesture(_ recognizer: UIGestureRecognizer) {
        guard adaptiveSamplingEnabled else { return }
        switch recognizer.state {
        case .began:
            applyAdaptiveSampling()
        case .ended, .cancelled, .failed:
            restoreSamplingStep()
        default:
            break
        }
    }
#endif

    func applyAdaptiveSampling() {
        guard adaptiveSamplingEnabled, !isAdaptiveSamplingActive else { return }
        isAdaptiveSamplingActive = true
        let reducedStep = max(64, baseSamplingStep * adaptiveInteractionFactor)
        volumeMaterial.setStep(reducedStep)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateAdaptiveSamplingStep(reducedStep)
#endif
    }

    func restoreSamplingStep() {
        guard isAdaptiveSamplingActive else {
            volumeMaterial.setStep(baseSamplingStep)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
            mpsDisplay?.updateAdaptiveSamplingStep(baseSamplingStep)
#endif
            return
        }
        isAdaptiveSamplingActive = false
        volumeMaterial.setStep(baseSamplingStep)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateAdaptiveSamplingStep(baseSamplingStep)
#endif
    }

    func configureMPR(axis: Axis, index: Int, blend: MPRPlaneMaterial.BlendMode, slab: SlabConfiguration?) {
        currentMprAxis = axis
        mprMaterial.setBlend(blend)
        if let slab {
            mprMaterial.setSlab(thicknessInVoxels: slab.thickness, axis: axis.rawValue, steps: slab.steps)
        } else {
            mprMaterial.setSlab(thicknessInVoxels: 1, axis: axis.rawValue, steps: 1)
        }

        mprPlaneIndex = clampedIndex(for: axis, index: index)
        mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
        mprEuler = .zero
        applyMprOrientation()
    }
}
#endif
