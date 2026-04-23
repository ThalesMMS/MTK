//
//  VolumeRenderingPort.swift
//  MetalVolumetrics
//
//  Declares the domain contract used to request GPU-backed volume rendering
//  artefacts from infrastructure providers. Interactive rendering returns
//  GPU-native Metal textures.
//

import Foundation
import CoreGraphics
import simd

@preconcurrency import Metal

public struct VolumeRenderRequest: Sendable, Equatable {
    public struct Camera: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var target: SIMD3<Float>
        public var up: SIMD3<Float>
        public var fieldOfView: Float
        public var projectionType: ProjectionType

        public init(position: SIMD3<Float>,
                    target: SIMD3<Float>,
                    up: SIMD3<Float>,
                    fieldOfView: Float,
                    projectionType: ProjectionType = .perspective) {
            self.position = position
            self.target = target
            self.up = up
            self.fieldOfView = fieldOfView
            self.projectionType = projectionType
        }
    }

    public enum Quality: Sendable, Equatable {
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

public extension VolumeTransferFunction {
    @inlinable
    static func defaultGrayscale(for dataset: VolumeDataset) -> VolumeTransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        return VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                          colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: upper,
                                                          colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
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

public enum VolumeRenderingCommand: Sendable, Equatable {
    case setCompositing(VolumeRenderRequest.Compositing)
    case setWindow(min: Int32, max: Int32)
    case setSamplingStep(Float)
    case setLighting(Bool)
}

/// Volume rendering boundary for Metal-backed clinical rendering.
///
/// Use the API in three tiers:
/// - Interactive rendering: call ``renderFrame(using:)`` and consume the
///   returned ``VolumeRenderFrame``.
/// - Display: bind ``VolumeRenderFrame/texture`` to `MTKView`,
///   `CAMetalLayer`, or another Metal-native presentation surface.
/// - Export/snapshot: call ``SnapshotExporting`` only when a CPU image is
///   explicitly required.
public protocol VolumeRenderingPort: Sendable {
    func renderFrame(using request: VolumeRenderRequest) async throws -> VolumeRenderFrame
    func renderInteractiveTexture(using request: VolumeRenderRequest) async throws -> any MTLTexture
    func updatePreset(_ preset: VolumeRenderingPreset,
                      for dataset: VolumeDataset) async throws -> [VolumeRenderingPreset]
    func refreshHistogram(for dataset: VolumeDataset,
                          descriptor: VolumeHistogramDescriptor,
                          transferFunction: VolumeTransferFunction) async throws -> VolumeHistogram
    func send(_ command: VolumeRenderingCommand) async throws
}
