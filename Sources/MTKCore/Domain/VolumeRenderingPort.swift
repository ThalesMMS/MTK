//
//  VolumeRenderingPort.swift
//  MetalVolumetrics
//
//  Declares the domain contract used to request GPU-backed volume rendering
//  artefacts from infrastructure providers. The API is intentionally SceneKit
//  agnostic, focusing on delivery of CoreGraphics and Metal friendly payloads
//  so presentation layers remain free to choose their rendering stack.
//

import Foundation
import CoreGraphics
import simd

#if canImport(Metal)
@preconcurrency import Metal
#endif

public struct VolumeRenderRequest: Sendable, Equatable {
    public struct Camera: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var target: SIMD3<Float>
        public var up: SIMD3<Float>
        public var fieldOfView: Float
        public var parallelProjection: Bool
        public var parallelScale: Float
        public var windowCenter: SIMD2<Float>

        public init(position: SIMD3<Float>,
                    target: SIMD3<Float>,
                    up: SIMD3<Float>,
                    fieldOfView: Float,
                    parallelProjection: Bool = false,
                    parallelScale: Float = 1,
                    windowCenter: SIMD2<Float> = .zero) {
            self.position = position
            self.target = target
            self.up = up
            self.fieldOfView = fieldOfView
            self.parallelProjection = parallelProjection
            self.parallelScale = parallelScale
            self.windowCenter = windowCenter
        }
    }

    public enum Quality: Sendable {
        case preview
        case interactive
        case production
    }

    public enum Compositing: Sendable {
        case maximumIntensity
        case minimumIntensity
        case averageIntensity
        case frontToBack
    }

    // Per-mode early-exit thresholds; defaults preserve current behaviour
    public struct EarlyExitThresholds: Sendable, Equatable {
        public var frontToBack: Float
        public var maximumIntensity: Float
        public var minimumIntensity: Float
        public var averageIntensity: Float

        public static let defaults = EarlyExitThresholds(frontToBack: 0.99,
                                                          maximumIntensity: 1.0, // disable for MIP
                                                          minimumIntensity: 1.0, // disable for MinIP
                                                          averageIntensity: 0.99)

        public func value(for mode: Compositing) -> Float {
            switch mode {
            case .frontToBack: return frontToBack
            case .maximumIntensity: return maximumIntensity
            case .minimumIntensity: return minimumIntensity
            case .averageIntensity: return averageIntensity
            }
        }
    }

    // Empty-space skipping controls
    public struct EmptySpaceSkipping: Sendable, Equatable {
        public var enabled: Bool
        public var occupancyEnabled: Bool
        public var minMaxEnabled: Bool
        public var zeroRunLength: UInt16
        public var zeroSkipDistance: UInt16
        public var alphaThreshold: Float
        public var gradientThreshold: Float // <=0 disables
        public var densityThreshold: Float  // <=0 disables

        public static let defaults = EmptySpaceSkipping(enabled: true,
                                                        occupancyEnabled: false,
                                                        minMaxEnabled: false,
                                                        zeroRunLength: 4,
                                                        zeroSkipDistance: 3,
                                                        alphaThreshold: 0.001,
                                                        gradientThreshold: 0.0,
                                                        densityThreshold: 0.0)
    }

    public enum ReconstructionKernel: UInt32, Sendable, Equatable {
        case linear = 0
        case cubic = 1
        case lanczos2 = 2
    }

    public var dataset: VolumeDataset
    public var transferFunction: VolumeTransferFunction
    public var viewportSize: CGSize
    public var camera: Camera
    public var samplingDistance: Float
    public var compositing: Compositing
    public var quality: Quality
    public var earlyExit: EarlyExitThresholds
    public var emptySpaceSkipping: EmptySpaceSkipping
    public var gradientSmoothness: Float
    public var usePreIntegratedTF: Bool
    public var reconstructionKernel: ReconstructionKernel
    public var useDualParameterTF: Bool
    public var useLightOcclusion: Bool
    public var lightOcclusionStrength: Float
    public var adaptiveStepMinScale: Float
    public var adaptiveStepMaxScale: Float
    public var adaptiveGradientScale: Float
    public var adaptiveFlatThreshold: Float
    public var adaptiveFlatBoost: Float
    public var preTFBlurRadius: Float

    public init(dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction,
                viewportSize: CGSize,
                camera: Camera,
                samplingDistance: Float? = nil,
                compositing: Compositing,
                quality: Quality,
                earlyExit: EarlyExitThresholds = .defaults,
                emptySpaceSkipping: EmptySpaceSkipping = .defaults,
                gradientSmoothness: Float = 0.0,
                usePreIntegratedTF: Bool = false,
                reconstructionKernel: ReconstructionKernel = .linear,
                useDualParameterTF: Bool = false,
                useLightOcclusion: Bool = false,
                lightOcclusionStrength: Float = 0.0,
                adaptiveStepMinScale: Float = 1.0,
                adaptiveStepMaxScale: Float = 1.0,
                adaptiveGradientScale: Float = 0.0,
                adaptiveFlatThreshold: Float = 0.02,
                adaptiveFlatBoost: Float = 1.5,
                preTFBlurRadius: Float = 0.0) {
        self.dataset = dataset
        self.transferFunction = transferFunction
        self.viewportSize = viewportSize
        self.camera = camera
        // If caller did not provide a sampling distance, compute a default based on voxel spacing and quality.
        let computed = samplingDistance ?? dataset.CompatibleSampleDistance(quality: quality.sampleQuality)
        self.samplingDistance = computed
        self.compositing = compositing
        self.quality = quality
        self.earlyExit = earlyExit
        self.emptySpaceSkipping = emptySpaceSkipping
        self.gradientSmoothness = gradientSmoothness
        self.usePreIntegratedTF = usePreIntegratedTF
        self.reconstructionKernel = reconstructionKernel
        self.useDualParameterTF = useDualParameterTF
        self.useLightOcclusion = useLightOcclusion
        self.lightOcclusionStrength = lightOcclusionStrength
        self.adaptiveStepMinScale = adaptiveStepMinScale
        self.adaptiveStepMaxScale = adaptiveStepMaxScale
        self.adaptiveGradientScale = adaptiveGradientScale
        self.adaptiveFlatThreshold = adaptiveFlatThreshold
        self.adaptiveFlatBoost = adaptiveFlatBoost
        self.preTFBlurRadius = preTFBlurRadius
    }
}

public struct VolumeTransferFunction: Sendable, Equatable {
    public struct OpacityControlPoint: Sendable, Equatable {
        public var intensity: Float
        public var opacity: Float

        public init(intensity: Float, opacity: Float) {
            self.intensity = intensity
            self.opacity = opacity
        }
    }

    public struct ColourControlPoint: Sendable, Equatable {
        public var intensity: Float
        public var colour: SIMD4<Float>

        public init(intensity: Float, colour: SIMD4<Float>) {
            self.intensity = intensity
            self.colour = colour
        }
    }

    public var opacityPoints: [OpacityControlPoint]
    public var colourPoints: [ColourControlPoint]
    public var gradientResolution: Int

    public init(opacityPoints: [OpacityControlPoint],
                colourPoints: [ColourControlPoint],
                gradientResolution: Int = 1) {
        self.opacityPoints = opacityPoints
        self.colourPoints = colourPoints
        self.gradientResolution = max(1, gradientResolution)
    }
}

public struct VolumeRenderingPreset: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var description: String?
    public var transferFunction: VolumeTransferFunction
    public var samplingDistance: Float
    public var compositing: VolumeRenderRequest.Compositing

    public init(id: UUID = UUID(),
                name: String,
                description: String? = nil,
                transferFunction: VolumeTransferFunction,
                samplingDistance: Float,
                compositing: VolumeRenderRequest.Compositing) {
        self.id = id
        self.name = name
        self.description = description
        self.transferFunction = transferFunction
        self.samplingDistance = samplingDistance
        self.compositing = compositing
    }
}

public struct VolumeHistogramDescriptor: Sendable, Equatable {
    public var binCount: Int
    public var intensityRange: ClosedRange<Float>
    public var normalize: Bool

    public init(binCount: Int,
                intensityRange: ClosedRange<Float>,
                normalize: Bool) {
        self.binCount = binCount
        self.intensityRange = intensityRange
        self.normalize = normalize
    }
}

public struct VolumeHistogram: Sendable, Equatable {
    public var descriptor: VolumeHistogramDescriptor
    public var bins: [Float]

    public init(descriptor: VolumeHistogramDescriptor, bins: [Float]) {
        self.descriptor = descriptor
        self.bins = bins
    }
}

public struct VolumeRenderResult {
    public struct Metadata: Sendable {
        public var viewportSize: CGSize
        public var samplingDistance: Float
        public var compositing: VolumeRenderRequest.Compositing
        public var quality: VolumeRenderRequest.Quality

        public init(viewportSize: CGSize,
                    samplingDistance: Float,
                    compositing: VolumeRenderRequest.Compositing,
                    quality: VolumeRenderRequest.Quality) {
            self.viewportSize = viewportSize
            self.samplingDistance = samplingDistance
            self.compositing = compositing
            self.quality = quality
        }
    }

    public var cgImage: CGImage?

    #if canImport(Metal)
    public var metalTexture: (any MTLTexture)?
    #endif

    public var metadata: Metadata

    public init(cgImage: CGImage?, metadata: Metadata) {
        self.cgImage = cgImage
#if canImport(Metal)
        self.metalTexture = nil
#endif
        self.metadata = metadata
    }

#if canImport(Metal)
    public init(cgImage: CGImage?, metalTexture: (any MTLTexture)?, metadata: Metadata) {
        self.cgImage = cgImage
        self.metalTexture = metalTexture
        self.metadata = metadata
    }
#endif
}

extension VolumeRenderResult: @unchecked Sendable {}

public enum VolumeRenderingCommand: Sendable, Equatable {
    case setCompositing(VolumeRenderRequest.Compositing)
    case setWindow(min: Int32, max: Int32)
    case setSamplingStep(Float)
    case setLighting(Bool)
}

public protocol VolumeRenderingPort: Sendable {
    func renderImage(using request: VolumeRenderRequest) async throws -> VolumeRenderResult
    func updatePreset(_ preset: VolumeRenderingPreset,
                      for dataset: VolumeDataset) async throws -> [VolumeRenderingPreset]
    func refreshHistogram(for dataset: VolumeDataset,
                          descriptor: VolumeHistogramDescriptor,
                          transferFunction: VolumeTransferFunction) async throws -> VolumeHistogram
    func send(_ command: VolumeRenderingCommand) async throws
}
