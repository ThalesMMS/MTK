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

        public init(position: SIMD3<Float>,
                    target: SIMD3<Float>,
                    up: SIMD3<Float>,
                    fieldOfView: Float) {
            self.position = position
            self.target = target
            self.up = up
            self.fieldOfView = fieldOfView
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

    public var dataset: VolumeDataset
    public var transferFunction: VolumeTransferFunction
    public var viewportSize: CGSize
    public var camera: Camera
    public var samplingDistance: Float
    public var compositing: Compositing
    public var quality: Quality

    public init(dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction,
                viewportSize: CGSize,
                camera: Camera,
                samplingDistance: Float,
                compositing: Compositing,
                quality: Quality) {
        self.dataset = dataset
        self.transferFunction = transferFunction
        self.viewportSize = viewportSize
        self.camera = camera
        self.samplingDistance = samplingDistance
        self.compositing = compositing
        self.quality = quality
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

    public init(opacityPoints: [OpacityControlPoint], colourPoints: [ColourControlPoint]) {
        self.opacityPoints = opacityPoints
        self.colourPoints = colourPoints
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
