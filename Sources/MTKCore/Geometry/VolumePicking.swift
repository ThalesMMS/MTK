//
//  VolumePicking.swift
//  MTKCore
//
//  Public picking and coordinate conversion contract for medical volume tools.
//

import CoreGraphics
import Foundation
import simd

public struct ViewportPoint: Sendable, Equatable {
    public var screenPoint: CGPoint
    public var viewportSize: CGSize
    public var normalizedPoint: SIMD2<Float>
    public var ndcPoint: SIMD2<Float>

    public init(screenPoint: CGPoint,
                viewportSize: CGSize,
                allowOutside: Bool = false) throws {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              screenPoint.x.isFinite,
              screenPoint.y.isFinite else {
            throw VolumePickError.invalidViewportSize
        }

        var normalized = SIMD2<Float>(
            Float(screenPoint.x / viewportSize.width),
            Float(screenPoint.y / viewportSize.height)
        )

        guard normalized.x.isFinite, normalized.y.isFinite else {
            throw VolumePickError.invalidViewportSize
        }

        if allowOutside {
            normalized.x = Self.clamp01(normalized.x)
            normalized.y = Self.clamp01(normalized.y)
        } else if normalized.x < 0 || normalized.x > 1 || normalized.y < 0 || normalized.y > 1 {
            throw VolumePickError.screenPointOutsideViewport
        }

        self.screenPoint = screenPoint
        self.viewportSize = viewportSize
        self.normalizedPoint = normalized
        self.ndcPoint = SIMD2<Float>(normalized.x * 2 - 1,
                                     (1 - normalized.y) * 2 - 1)
    }

    public init(normalizedPoint: SIMD2<Float>,
                viewportSize: CGSize = CGSize(width: 1, height: 1)) throws {
        try self.init(screenPoint: CGPoint(x: CGFloat(normalizedPoint.x) * viewportSize.width,
                                           y: CGFloat(normalizedPoint.y) * viewportSize.height),
                      viewportSize: viewportSize)
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

public struct WorldRay: Sendable, Equatable {
    public var originWorld: SIMD3<Float>
    public var directionWorld: SIMD3<Float>
    public var originTexture: SIMD3<Float>
    public var directionTexture: SIMD3<Float>

    public init(originWorld: SIMD3<Float>,
                directionWorld: SIMD3<Float>,
                originTexture: SIMD3<Float>,
                directionTexture: SIMD3<Float>) {
        self.originWorld = originWorld
        self.directionWorld = directionWorld
        self.originTexture = originTexture
        self.directionTexture = directionTexture
    }
}

public struct VoxelIndex: Sendable, Equatable {
    public var index: SIMD3<Int32>
    public var continuousIndex: SIMD3<Float>

    public init(index: SIMD3<Int32>,
                continuousIndex: SIMD3<Float>) {
        self.index = index
        self.continuousIndex = continuousIndex
    }
}

public struct VolumeIntensitySample: Sendable, Equatable {
    public var storedScalar: Int32
    public var modalityValue: Float
    public var hounsfieldUnits: Float

    public init(storedScalar: Int32,
                modalityValue: Float,
                hounsfieldUnits: Float) {
        self.storedScalar = storedScalar
        self.modalityValue = modalityValue
        self.hounsfieldUnits = hounsfieldUnits
    }
}

public struct VolumeLabelSample: Sendable, Equatable {
    public var layerID: String
    public var label: UInt16
    public var segment: LabelmapSegment?

    public init(layerID: String,
                label: UInt16,
                segment: LabelmapSegment?) {
        self.layerID = layerID
        self.label = label
        self.segment = segment
    }
}

public struct VolumeScalarSample: Sendable, Equatable {
    public var layerID: String
    public var voxel: VoxelIndex
    public var intensity: VolumeIntensitySample
    public var quantitativeValue: QuantitativeScalarValue?

    public init(layerID: String,
                voxel: VoxelIndex,
                intensity: VolumeIntensitySample,
                quantitativeValue: QuantitativeScalarValue? = nil) {
        self.layerID = layerID
        self.voxel = voxel
        self.intensity = intensity
        self.quantitativeValue = quantitativeValue
    }
}

public struct VolumePickResult: Sendable, Equatable {
    public enum HitKind: Sendable, Equatable {
        case mprPlane(MPRPlaneAxis)
        case volumeVisibleSample
    }

    public var hitKind: HitKind
    public var viewportPoint: ViewportPoint
    public var worldPoint: SIMD3<Float>
    public var voxel: VoxelIndex
    public var textureCoordinate: SIMD3<Float>
    public var intensity: VolumeIntensitySample
    public var label: VolumeLabelSample?
    public var scalarSamples: [VolumeScalarSample]
    public var worldRay: WorldRay?

    public init(hitKind: HitKind,
                viewportPoint: ViewportPoint,
                worldPoint: SIMD3<Float>,
                voxel: VoxelIndex,
                textureCoordinate: SIMD3<Float>,
                intensity: VolumeIntensitySample,
                label: VolumeLabelSample? = nil,
                scalarSamples: [VolumeScalarSample] = [],
                worldRay: WorldRay? = nil) {
        self.hitKind = hitKind
        self.viewportPoint = viewportPoint
        self.worldPoint = worldPoint
        self.voxel = voxel
        self.textureCoordinate = textureCoordinate
        self.intensity = intensity
        self.label = label
        self.scalarSamples = scalarSamples
        self.worldRay = worldRay
    }
}

public enum VolumePickError: Error, Equatable, LocalizedError {
    case invalidViewport
    case invalidViewportSize
    case screenPointOutsideViewport
    case outsideImagedArea
    case rayMissedVolume
    case outsideVolume
    case malformedData
    case degenerateGeometry
    case noVisibleSample

    public var errorDescription: String? {
        switch self {
        case .invalidViewport:
            return "The requested viewport cannot be picked."
        case .invalidViewportSize:
            return "Picking requires a finite, non-zero viewport size."
        case .screenPointOutsideViewport:
            return "The screen point lies outside the viewport."
        case .outsideImagedArea:
            return "The screen point lies in the aspect-fit letterbox band, outside the rendered image."
        case .rayMissedVolume:
            return "The pick ray did not intersect the volume."
        case .outsideVolume:
            return "The pick point lies outside the volume bounds."
        case .malformedData:
            return "The volume data buffer is missing or too small for the declared dimensions."
        case .degenerateGeometry:
            return "The picking geometry is degenerate."
        case .noVisibleSample:
            return "The pick ray intersected the volume but did not hit a visible rendered sample."
        }
    }
}

public struct Volume3DPickConfiguration: Sendable {
    public var camera: VolumeRenderRequest.Camera
    public var viewportSize: CGSize
    public var transferFunction: VolumeTransferFunction?
    public var window: ClosedRange<Int32>?
    public var samplingDistance: Float
    public var compositing: VolumeRenderRequest.Compositing
    public var densityGate: ClosedRange<Float>?
    public var huGate: ClosedRange<Int32>?
    public var clipBounds: ClipBoundsSnapshot
    public var clipPlane: ClipPlaneSnapshot?
    public var clipping: VolumeClippingState

    public init(camera: VolumeRenderRequest.Camera,
                viewportSize: CGSize,
                transferFunction: VolumeTransferFunction? = nil,
                window: ClosedRange<Int32>? = nil,
                samplingDistance: Float = 1.0 / 512.0,
                compositing: VolumeRenderRequest.Compositing = .frontToBack,
                densityGate: ClosedRange<Float>? = 0.02...1.0,
                huGate: ClosedRange<Int32>? = nil,
                clipBounds: ClipBoundsSnapshot = .default,
                clipPlane: ClipPlaneSnapshot? = nil,
                clipping: VolumeClippingState? = nil) {
        self.camera = camera
        self.viewportSize = viewportSize
        self.transferFunction = transferFunction
        self.window = window
        self.samplingDistance = samplingDistance
        self.compositing = compositing
        self.densityGate = densityGate
        self.huGate = huGate
        self.clipBounds = clipBounds
        self.clipPlane = clipPlane
        self.clipping = clipping ?? .disabled
    }

    func resolvedClipping(for dataset: VolumeDataset) throws -> VolumeClippingState {
        if !clipping.isDisabled {
            return clipping
        }

        let cropBox = clipBounds == .default ? nil : try clipBounds.volumeCropBox()
        let planes = try clipPlane?.volumeClipPlane(for: dataset).map { [$0] } ?? []
        return try VolumeClippingState(cropBox: cropBox,
                                       clipPlanes: planes)
    }
}

public enum VolumePicking {
    public static func viewportPoint(screenPoint: CGPoint,
                                     viewportSize: CGSize,
                                     allowOutside: Bool = false) throws -> ViewportPoint {
        try ViewportPoint(screenPoint: screenPoint,
                          viewportSize: viewportSize,
                          allowOutside: allowOutside)
    }

    public static func worldPoint(forVoxelIndex index: SIMD3<Float>,
                                  in dataset: VolumeDataset) -> SIMD3<Float> {
        dataset.imageData.indexToWorld.transformPoint(index)
    }

    public static func textureCoordinate(forVoxelIndex index: SIMD3<Float>,
                                         in dataset: VolumeDataset) -> SIMD3<Float> {
        textureCoordinate(forContinuousIndex: index,
                          dimensions: dataset.dimensions)
    }

    public static func voxelIndex(forWorldPoint worldPoint: SIMD3<Float>,
                                  in dataset: VolumeDataset) throws -> VoxelIndex {
        try voxelIndex(forContinuousIndex: dataset.imageData.worldToIndex.transformPoint(worldPoint),
                       dimensions: dataset.dimensions)
    }

    public static func textureCoordinate(forWorldPoint worldPoint: SIMD3<Float>,
                                         in dataset: VolumeDataset) -> SIMD3<Float> {
        dataset.imageData.worldToTexture.transformPoint(worldPoint)
    }

    public static func sampleIntensity(in dataset: VolumeDataset,
                                       atWorldPoint worldPoint: SIMD3<Float>) throws -> VolumeIntensitySample {
        let voxel = try voxelIndex(forWorldPoint: worldPoint, in: dataset)
        return try sampleIntensity(in: dataset, atVoxelIndex: voxel.index)
    }

    public static func sampleIntensity(in dataset: VolumeDataset,
                                       atTextureCoordinate textureCoordinate: SIMD3<Float>) throws -> VolumeIntensitySample {
        let voxel = try voxelIndex(forContinuousIndex: continuousIndex(forTextureCoordinate: textureCoordinate,
                                                                       dimensions: dataset.dimensions),
                                   dimensions: dataset.dimensions)
        return try sampleIntensity(in: dataset, atVoxelIndex: voxel.index)
    }

    public static func sampleIntensity(in dataset: VolumeDataset,
                                       atVoxelIndex index: SIMD3<Int32>) throws -> VolumeIntensitySample {
        guard isVoxelIndexInBounds(index, dimensions: dataset.dimensions) else {
            throw VolumePickError.outsideVolume
        }
        guard dataset.data.count >= expectedByteCount(for: dataset) else {
            throw VolumePickError.malformedData
        }

        return dataset.data.withUnsafeBytes { rawBuffer in
            sampleIntensity(in: dataset, buffer: rawBuffer, atVoxelIndex: index)
        }
    }

    public static func sampleLabel(in layers: [VolumeLayer],
                                   atBaseWorldPoint worldPoint: SIMD3<Float>) throws -> VolumeLabelSample? {
        for layer in layers where layer.isVisible && layer.clampedOpacity > 0 {
            guard let labelmap = layer.labelmap else { continue }
            let sample: VolumeIntensitySample
            do {
                let layerWorldPoint = layer.baseWorldToLayerWorld.transformPoint(worldPoint)
                let layerVoxel = try voxelIndex(forWorldPoint: layerWorldPoint,
                                                in: labelmap.dataset)
                sample = try sampleIntensity(in: labelmap.dataset,
                                             atVoxelIndex: layerVoxel.index)
            } catch VolumePickError.outsideVolume {
                continue
            }
            guard sample.storedScalar > 0,
                  sample.storedScalar <= Int32(UInt16.max) else {
                continue
            }

            let label = UInt16(sample.storedScalar)
            let segment = labelmap.segmentsByLabel[label]
            if let segment, !segment.isVisible {
                continue
            }
            return VolumeLabelSample(layerID: layer.id,
                                     label: label,
                                     segment: segment)
        }
        return nil
    }

    public static func sampleScalarVolumes(in layers: [VolumeLayer],
                                           atBaseWorldPoint worldPoint: SIMD3<Float>) throws -> [VolumeScalarSample] {
        var samples: [VolumeScalarSample] = []
        for layer in layers where layer.isVisible && layer.clampedOpacity > 0 {
            guard let scalarVolume = layer.scalarVolume else { continue }
            do {
                let layerWorldPoint = layer.baseWorldToLayerWorld.transformPoint(worldPoint)
                let layerVoxel = try voxelIndex(forWorldPoint: layerWorldPoint,
                                                in: scalarVolume.dataset)
                let intensity = try sampleIntensity(in: scalarVolume.dataset,
                                                    atVoxelIndex: layerVoxel.index)
                let linear = linearIndex(layerVoxel.index,
                                         dimensions: scalarVolume.dataset.dimensions)
                let quantitativeValue = scalarVolume.quantitativeMapping?.sample(
                    storedScalar: intensity.storedScalar,
                    linearIndex: linear
                )
                samples.append(
                    VolumeScalarSample(layerID: layer.id,
                                       voxel: layerVoxel,
                                       intensity: intensity,
                                       quantitativeValue: quantitativeValue)
                )
            } catch VolumePickError.outsideVolume {
                continue
            }
        }
        return samples
    }

    public static func pickMPR(screenPoint: CGPoint,
                               viewportSize: CGSize,
                               dataset: VolumeDataset,
                               plane: MPRPlaneGeometry,
                               displayTransform: MPRDisplayTransform,
                               viewportTransform: MPRViewportTransform = .identity,
                               outputAspect: MPROutputAspect,
                               axis: MPRPlaneAxis,
                               layers: [VolumeLayer] = []) throws -> VolumePickResult {
        let viewport = try ViewportPoint(screenPoint: screenPoint,
                                         viewportSize: viewportSize)
        let sourceAspectRatio = displayTransform.displayAspectRatio(
            forSourceAspectRatio: plane.physicalAspectRatio
        )
        let layout = outputAspect.layout(
            destinationSize: viewportSize,
            viewportTransform: viewportTransform
        )
        guard let imagePoint = layout.imagePoint(fromViewportPoint: viewport.normalizedPoint) else {
            throw VolumePickError.outsideImagedArea
        }
        let imageScreenPoint = viewportTransform
            .imageScreenCoordinates(
                forViewportScreen: imagePoint,
                sourceAspectRatio: sourceAspectRatio
            )
        let planePoint = displayTransform.textureCoordinates(forScreen: imageScreenPoint)
        let textureCoordinate = plane.originTexture
            + planePoint.x * plane.axisUTexture
            + planePoint.y * plane.axisVTexture
        let continuousIndex = continuousIndex(forTextureCoordinate: textureCoordinate,
                                              dimensions: dataset.dimensions)
        let voxel = try voxelIndex(forContinuousIndex: continuousIndex,
                                   dimensions: dataset.dimensions)
        let worldPoint = dataset.imageData.indexToWorld.transformPoint(continuousIndex)
        let intensity = try sampleIntensity(in: dataset,
                                            atVoxelIndex: voxel.index)
        let label = try sampleLabel(in: layers,
                                    atBaseWorldPoint: worldPoint)
        let scalarSamples = try sampleScalarVolumes(in: layers,
                                                    atBaseWorldPoint: worldPoint)
        return VolumePickResult(hitKind: .mprPlane(axis),
                                viewportPoint: viewport,
                                worldPoint: worldPoint,
                                voxel: voxel,
                                textureCoordinate: textureCoordinate,
                                intensity: intensity,
                                label: label,
                                scalarSamples: scalarSamples)
    }

    public static func worldRay(screenPoint: CGPoint,
                                dataset: VolumeDataset,
                                configuration: Volume3DPickConfiguration) throws -> WorldRay {
        let viewport = try ViewportPoint(screenPoint: screenPoint,
                                         viewportSize: configuration.viewportSize)
        let geometry = VolumeRenderGeometry.make(for: dataset)
        let camera = geometry.renderCamera(for: configuration.camera)
        let matrices: VolumeCameraMath.Matrices
        do {
            matrices = try VolumeCameraMath.matrices(
                camera: camera,
                viewportWidth: Float(configuration.viewportSize.width),
                viewportHeight: Float(configuration.viewportSize.height)
            )
        } catch {
            throw VolumePickError.degenerateGeometry
        }
        let inverseViewProjection = matrices.inverseViewProjection

        let near = try unproject(clipPoint: SIMD4<Float>(viewport.ndcPoint.x,
                                                         viewport.ndcPoint.y,
                                                         0,
                                                         1),
                                 inverseViewProjection: inverseViewProjection)
        let far = try unproject(clipPoint: SIMD4<Float>(viewport.ndcPoint.x,
                                                        viewport.ndcPoint.y,
                                                        1,
                                                        1),
                                inverseViewProjection: inverseViewProjection)

        let originTexture: SIMD3<Float>
        let targetTexture: SIMD3<Float>
        switch configuration.camera.projectionType {
        case .perspective:
            originTexture = configuration.camera.position
            targetTexture = geometry.textureCoordinate(forWorldPosition: far)
        case .orthographic:
            originTexture = geometry.textureCoordinate(forWorldPosition: near)
            targetTexture = geometry.textureCoordinate(forWorldPosition: far)
        }

        let directionTexture = try normalized(targetTexture - originTexture)
        let originWorld = worldPoint(forTextureCoordinate: originTexture,
                                     in: dataset)
        let directionWorld = try worldDirection(forTextureOrigin: originTexture,
                                                direction: directionTexture,
                                                dataset: dataset)
        return WorldRay(originWorld: originWorld,
                        directionWorld: directionWorld,
                        originTexture: originTexture,
                        directionTexture: directionTexture)
    }

    public static func pickVolume3D(screenPoint: CGPoint,
                                    dataset: VolumeDataset,
                                    configuration: Volume3DPickConfiguration,
                                    layers: [VolumeLayer] = []) throws -> VolumePickResult {
        let viewport = try ViewportPoint(screenPoint: screenPoint,
                                         viewportSize: configuration.viewportSize)
        let ray = try worldRay(screenPoint: screenPoint,
                               dataset: dataset,
                               configuration: configuration)
        let intersection = try intersectUnitCube(origin: ray.originTexture,
                                                 direction: ray.directionTexture)

        let tEnter = max(intersection.lowerBound, 0)
        let tExit = intersection.upperBound
        guard tExit > tEnter else {
            throw VolumePickError.rayMissedVolume
        }

        let start = ray.originTexture + ray.directionTexture * tEnter
        let end = ray.originTexture + ray.directionTexture * tExit
        let totalDistance = max(simd_length(end - start), 1e-5)
        let rawSteps = Int(round(1.0 / max(configuration.samplingDistance, 1e-5)))
        let maxSteps = max(rawSteps, 1)
        let baseStep = max(sqrt(Float(3)) / Float(maxSteps), 1e-5)
        let window = configuration.window ?? dataset.recommendedWindow ?? dataset.intensityRange
        let transfer = configuration.transferFunction ?? .defaultGrayscale(for: dataset)
        let clipping = try configuration.resolvedClipping(for: dataset)
        let shaderPlanes = try clipping.shaderClipPlanes(for: dataset)
        let usesTransfer: Bool
        switch configuration.compositing {
        case .frontToBack:
            usesTransfer = true
        case .maximumIntensity, .minimumIntensity, .averageIntensity:
            usesTransfer = false
        }

        guard dataset.data.count >= expectedByteCount(for: dataset) else {
            throw VolumePickError.malformedData
        }
        let sortedOpacityPoints = usesTransfer
            ? transfer.opacityPoints.sorted { $0.intensity < $1.intensity }
            : []

        return try dataset.data.withUnsafeBytes { rawBuffer in
            var distance: Float = 0
            var iterations = 0
            let maxIterations = max(maxSteps * 4, maxSteps + 16)
            while distance < totalDistance && iterations < maxIterations {
                let textureCoordinate = start + ray.directionTexture * distance
                guard isTextureCoordinateInBounds(textureCoordinate) else {
                    break
                }
                if isClipped(textureCoordinate: textureCoordinate,
                             clipping: clipping,
                             shaderPlanes: shaderPlanes) {
                    distance += baseStep
                    iterations += 1
                    continue
                }

                let continuousIndex = continuousIndex(forTextureCoordinate: textureCoordinate,
                                                      dimensions: dataset.dimensions)
                let voxel: VoxelIndex
                do {
                    voxel = try voxelIndex(forContinuousIndex: continuousIndex,
                                           dimensions: dataset.dimensions)
                } catch VolumePickError.outsideVolume {
                    distance += baseStep
                    iterations += 1
                    continue
                }
                let intensity = sampleIntensity(in: dataset,
                                                buffer: rawBuffer,
                                                atVoxelIndex: voxel.index)
                let densityWindow = normalizedIntensity(Float(intensity.storedScalar),
                                                        lower: Float(window.lowerBound),
                                                        upper: Float(window.upperBound))

                if isGatedOut(storedScalar: intensity.storedScalar,
                              densityWindow: densityWindow,
                              densityGate: configuration.densityGate,
                              huGate: configuration.huGate) {
                    distance += baseStep
                    iterations += 1
                    continue
                }

                let alpha: Float
                if usesTransfer {
                    alpha = opacity(for: intensity.modalityValue,
                                    sortedPoints: sortedOpacityPoints) * densityWindow
                } else {
                    alpha = densityWindow
                }

                if alpha >= 0.001 {
                    let worldPoint = dataset.imageData.indexToWorld.transformPoint(continuousIndex)
                    let label = try sampleLabel(in: layers,
                                                atBaseWorldPoint: worldPoint)
                    let scalarSamples = try sampleScalarVolumes(in: layers,
                                                                atBaseWorldPoint: worldPoint)
                    return VolumePickResult(hitKind: .volumeVisibleSample,
                                            viewportPoint: viewport,
                                            worldPoint: worldPoint,
                                            voxel: voxel,
                                            textureCoordinate: textureCoordinate,
                                            intensity: intensity,
                                            label: label,
                                            scalarSamples: scalarSamples,
                                            worldRay: ray)
                }

                distance += baseStep
                iterations += 1
            }

            throw VolumePickError.noVisibleSample
        }
    }

    public static func screenPoint(forWorldPoint worldPoint: SIMD3<Float>,
                                   dataset: VolumeDataset,
                                   plane: MPRPlaneGeometry,
                                   displayTransform: MPRDisplayTransform,
                                   viewportTransform: MPRViewportTransform = .identity,
                                   outputAspect: MPROutputAspect,
                                   viewportSize: CGSize) throws -> ViewportPoint {
        let texture = dataset.imageData.worldToTexture.transformPoint(worldPoint)
        let uv = try planeUV(forTextureCoordinate: texture,
                             plane: plane)
        let imageScreen = displayTransform.screenCoordinates(forTexture: uv)
        let sourceAspectRatio = displayTransform.displayAspectRatio(
            forSourceAspectRatio: plane.physicalAspectRatio
        )
        let imagePoint = viewportTransform.screenCoordinates(
            forImageScreen: imageScreen,
            sourceAspectRatio: sourceAspectRatio
        )
        let layout = outputAspect.layout(
            destinationSize: viewportSize,
            viewportTransform: viewportTransform
        )
        let normalized = layout.viewportPoint(fromImagePoint: imagePoint)
        return try ViewportPoint(normalizedPoint: normalized,
                                 viewportSize: viewportSize)
    }

    public static func volumeScreenPoint(forWorldPoint worldPoint: SIMD3<Float>,
                                         dataset: VolumeDataset,
                                         camera: VolumeRenderRequest.Camera,
                                         viewportSize: CGSize) throws -> ViewportPoint {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            throw VolumePickError.invalidViewportSize
        }

        let texture = dataset.imageData.worldToTexture.transformPoint(worldPoint)
        let geometry = VolumeRenderGeometry.make(for: dataset)
        let renderPoint = geometry.worldPosition(forTextureCoordinate: texture)
        let renderCamera = geometry.renderCamera(for: camera)
        let matrices: VolumeCameraMath.Matrices
        do {
            matrices = try VolumeCameraMath.matrices(
                camera: renderCamera,
                viewportWidth: Float(viewportSize.width),
                viewportHeight: Float(viewportSize.height)
            )
        } catch {
            throw VolumePickError.degenerateGeometry
        }
        let clip = matrices.projection * matrices.view * SIMD4<Float>(renderPoint, 1)
        guard abs(clip.w) > Float.ulpOfOne else {
            throw VolumePickError.degenerateGeometry
        }
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        let normalized = SIMD2<Float>((ndc.x + 1) * 0.5,
                                      1 - ((ndc.y + 1) * 0.5))
        return try ViewportPoint(normalizedPoint: normalized,
                                 viewportSize: viewportSize)
    }

    static func sampleIntensity(in dataset: VolumeDataset,
                                buffer: UnsafeRawBufferPointer,
                                atVoxelIndex index: SIMD3<Int32>) -> VolumeIntensitySample {
        let linear = linearIndex(index, dimensions: dataset.dimensions)
        let byteOffset = linear * dataset.pixelFormat.bytesPerVoxel
        let stored: Int32
        switch dataset.pixelFormat {
        case .int16Signed:
            stored = Int32(buffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self))
        case .int16Unsigned:
            stored = Int32(buffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
        }
        let modalityValue = Float(stored)
        return VolumeIntensitySample(storedScalar: stored,
                                     modalityValue: modalityValue,
                                     hounsfieldUnits: modalityValue)
    }
}

private extension VolumePicking {
    static func continuousIndex(forTextureCoordinate textureCoordinate: SIMD3<Float>,
                                dimensions: VolumeDimensions) -> SIMD3<Float> {
        let dims = SIMD3<Float>(Float(dimensions.width),
                                Float(dimensions.height),
                                Float(dimensions.depth))
        return textureCoordinate * dims - SIMD3<Float>(repeating: 0.5)
    }

    static func textureCoordinate(forContinuousIndex index: SIMD3<Float>,
                                  dimensions: VolumeDimensions) -> SIMD3<Float> {
        let dims = SIMD3<Float>(Float(dimensions.width),
                                Float(dimensions.height),
                                Float(dimensions.depth))
        return (index + SIMD3<Float>(repeating: 0.5)) / dims
    }

    static func voxelIndex(forContinuousIndex index: SIMD3<Float>,
                           dimensions: VolumeDimensions) throws -> VoxelIndex {
        guard index.x.isFinite, index.y.isFinite, index.z.isFinite else {
            throw VolumePickError.degenerateGeometry
        }
        let nearest = SIMD3<Int32>(
            Int32(floor(index.x + 0.5)),
            Int32(floor(index.y + 0.5)),
            Int32(floor(index.z + 0.5))
        )
        guard isVoxelIndexInBounds(nearest, dimensions: dimensions) else {
            throw VolumePickError.outsideVolume
        }
        return VoxelIndex(index: nearest,
                          continuousIndex: index)
    }

    static func isVoxelIndexInBounds(_ index: SIMD3<Int32>,
                                     dimensions: VolumeDimensions) -> Bool {
        index.x >= 0 && index.x < Int32(dimensions.width) &&
            index.y >= 0 && index.y < Int32(dimensions.height) &&
            index.z >= 0 && index.z < Int32(dimensions.depth)
    }

    static func isTextureCoordinateInBounds(_ coordinate: SIMD3<Float>) -> Bool {
        coordinate.x >= 0 && coordinate.x <= 1 &&
            coordinate.y >= 0 && coordinate.y <= 1 &&
            coordinate.z >= 0 && coordinate.z <= 1
    }

    static func worldPoint(forTextureCoordinate textureCoordinate: SIMD3<Float>,
                           in dataset: VolumeDataset) -> SIMD3<Float> {
        dataset.imageData.indexToWorld.transformPoint(
            continuousIndex(forTextureCoordinate: textureCoordinate,
                            dimensions: dataset.dimensions)
        )
    }

    static func worldDirection(forTextureOrigin origin: SIMD3<Float>,
                               direction: SIMD3<Float>,
                               dataset: VolumeDataset) throws -> SIMD3<Float> {
        let originIndex = continuousIndex(forTextureCoordinate: origin,
                                          dimensions: dataset.dimensions)
        let dims = SIMD3<Float>(Float(dataset.dimensions.width),
                                Float(dataset.dimensions.height),
                                Float(dataset.dimensions.depth))
        let targetIndex = originIndex + direction * dims
        let originWorld = dataset.imageData.indexToWorld.transformPoint(originIndex)
        let targetWorld = dataset.imageData.indexToWorld.transformPoint(targetIndex)
        return try normalized(targetWorld - originWorld)
    }

    static func expectedByteCount(for dataset: VolumeDataset) -> Int {
        dataset.dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
    }

    static func linearIndex(_ index: SIMD3<Int32>,
                            dimensions: VolumeDimensions) -> Int {
        Int(index.z) * dimensions.width * dimensions.height
            + Int(index.y) * dimensions.width
            + Int(index.x)
    }

    static func normalizedIntensity(_ value: Float,
                                    lower: Float,
                                    upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    static func opacity(for intensity: Float,
                        sortedPoints points: [VolumeTransferFunction.OpacityControlPoint]) -> Float {
        guard let first = points.first else { return 0 }
        guard let last = points.last else { return first.opacity }
        if intensity <= first.intensity {
            return min(max(first.opacity, 0), 1)
        }
        if intensity >= last.intensity {
            return min(max(last.opacity, 0), 1)
        }
        for index in 0..<(points.count - 1) {
            let lhs = points[index]
            let rhs = points[index + 1]
            guard intensity >= lhs.intensity, intensity <= rhs.intensity else {
                continue
            }
            let denominator = rhs.intensity - lhs.intensity
            guard abs(denominator) > Float.ulpOfOne else {
                return min(max(rhs.opacity, 0), 1)
            }
            let t = (intensity - lhs.intensity) / denominator
            return min(max(lhs.opacity + (rhs.opacity - lhs.opacity) * t, 0), 1)
        }
        return 0
    }

    static func isGatedOut(storedScalar: Int32,
                           densityWindow: Float,
                           densityGate: ClosedRange<Float>?,
                           huGate: ClosedRange<Int32>?) -> Bool {
        if let huGate,
           (storedScalar < huGate.lowerBound || storedScalar > huGate.upperBound) {
            return true
        }
        if let densityGate,
           (densityWindow < densityGate.lowerBound || densityWindow > densityGate.upperBound) {
            return true
        }
        return false
    }

    static func isClipped(textureCoordinate: SIMD3<Float>,
                          clipping: VolumeClippingState,
                          shaderPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) -> Bool {
        if !clipping.contains(textureCoordinate: textureCoordinate) {
            return true
        }

        let centered = textureCoordinate - SIMD3<Float>(repeating: 0.5)
        let planes = [shaderPlanes.0, shaderPlanes.1, shaderPlanes.2]
        for plane in planes {
            let normal = SIMD3<Float>(plane.x, plane.y, plane.z)
            if normal == .zero {
                continue
            }
            if simd_dot(centered, normal) + plane.w > 0 {
                return true
            }
        }
        return false
    }

    static func intersectUnitCube(origin: SIMD3<Float>,
                                  direction: SIMD3<Float>) throws -> ClosedRange<Float> {
        var tMin = -Float.greatestFiniteMagnitude
        var tMax = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let originValue = origin[axis]
            let directionValue = direction[axis]
            if abs(directionValue) <= 1e-8 {
                guard originValue >= 0, originValue <= 1 else {
                    throw VolumePickError.rayMissedVolume
                }
                continue
            }

            let t1 = (0 - originValue) / directionValue
            let t2 = (1 - originValue) / directionValue
            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }
        guard tMax >= tMin else {
            throw VolumePickError.rayMissedVolume
        }
        return tMin...tMax
    }

    static func unproject(clipPoint: SIMD4<Float>,
                          inverseViewProjection: simd_float4x4) throws -> SIMD3<Float> {
        let unprojected = inverseViewProjection * clipPoint
        guard abs(unprojected.w) > Float.ulpOfOne else {
            throw VolumePickError.degenerateGeometry
        }
        return SIMD3<Float>(unprojected.x, unprojected.y, unprojected.z) / unprojected.w
    }

    static func normalized(_ value: SIMD3<Float>) throws -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > Float.ulpOfOne, length.isFinite else {
            throw VolumePickError.degenerateGeometry
        }
        return value / length
    }

    static func planeUV(forTextureCoordinate texture: SIMD3<Float>,
                        plane: MPRPlaneGeometry) throws -> SIMD2<Float> {
        let p = texture - plane.originTexture
        let u = plane.axisUTexture
        let v = plane.axisVTexture
        let uu = simd_dot(u, u)
        let uv = simd_dot(u, v)
        let vv = simd_dot(v, v)
        let pu = simd_dot(p, u)
        let pv = simd_dot(p, v)
        let determinant = uu * vv - uv * uv
        guard abs(determinant) > Float.ulpOfOne else {
            throw VolumePickError.degenerateGeometry
        }
        return SIMD2<Float>((pu * vv - pv * uv) / determinant,
                            (pv * uu - pu * uv) / determinant)
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
