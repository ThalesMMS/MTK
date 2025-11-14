//
//  MetalRaycaster.swift
//  MTK
//
//  Facade over the Metal pipelines backing volume rendering and MPR.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog
import simd
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

public final class MetalRaycaster {
    public enum Technique: CaseIterable {
        case dvr
        case mip
        case minip
    }

    public struct DatasetResources {
        public let dataset: VolumeDataset
        public let texture: any MTLTexture
        public let dimensions: SIMD3<Int32>
        public let spacing: SIMD3<Float>
    }

    public enum Error: Swift.Error {
        case libraryUnavailable
        case pipelineUnavailable(function: String)
        case commandQueueUnavailable
        case datasetUnavailable
        case transferFunctionUnavailable
        case unsupportedDevice
    }

    private struct FragmentSignature: Hashable {
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var sampleCount: Int
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalRaycaster")
    private var fragmentCache: [FragmentSignature: any MTLRenderPipelineState] = [:]
    private var computeCache: [Technique: any MTLComputePipelineState] = [:]

    public private(set) var currentDataset: DatasetResources?

#if canImport(MetalPerformanceShaders)
    private let mpsAvailable: Bool
#else
    private let mpsAvailable = false
#endif

    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil) throws {
        var supports3DTextures = false
#if os(iOS) || os(tvOS)
        if #available(iOS 13.0, tvOS 13.0, *) {
            supports3DTextures = device.supportsFamily(.apple3) || device.supportsFamily(.apple4) || device.supportsFamily(.apple5)
        } else {
            supports3DTextures = true
        }
#elseif os(macOS)
        if #available(macOS 11.0, *) {
            supports3DTextures = device.supportsFamily(.mac2)
        } else {
            supports3DTextures = true
        }
#else
        supports3DTextures = true
#endif

        if #available(iOS 13.0, tvOS 13.0, macOS 11.0, *) {
            supports3DTextures = supports3DTextures || device.supportsFamily(.apple4) || device.supportsFamily(.mac2)
        }

        guard supports3DTextures else {
            throw Error.unsupportedDevice
        }

        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw Error.commandQueueUnavailable
        }

        let resolvedLibrary: (any MTLLibrary)?
        if let library {
            resolvedLibrary = library
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            resolvedLibrary = defaultLibrary
        } else if #available(iOS 13.0, tvOS 13.0, macOS 11.0, *),
                  let bundleLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            resolvedLibrary = bundleLibrary
        } else {
            resolvedLibrary = nil
        }

        guard let resolvedLibrary else {
            throw Error.libraryUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.library = resolvedLibrary
#if canImport(MetalPerformanceShaders)
        self.mpsAvailable = MPSSupportsMTLDevice(device)
#endif
    }

    public var isMetalPerformanceShadersAvailable: Bool { mpsAvailable }

    public func makeFragmentPipeline(colorPixelFormat: MTLPixelFormat,
                                     depthPixelFormat: MTLPixelFormat = .invalid,
                                     sampleCount: Int = 1,
                                     label: String? = nil) throws -> any MTLRenderPipelineState {
        let signature = FragmentSignature(color: colorPixelFormat,
                                          depth: depthPixelFormat,
                                          sampleCount: sampleCount)
        if let cached = fragmentCache[signature] {
            return cached
        }

        guard let vertexFunction = library.makeFunction(name: "volume_vertex") else {
            throw Error.pipelineUnavailable(function: "volume_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "volume_fragment") else {
            throw Error.pipelineUnavailable(function: "volume_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label ?? "VolumeRenderingKit.Volume.Fragment"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        if depthPixelFormat != .invalid {
            descriptor.depthAttachmentPixelFormat = depthPixelFormat
        }
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        fragmentCache[signature] = pipeline
        return pipeline
    }

    public func makeComputePipeline(for technique: Technique,
                                    label: String? = nil) throws -> any MTLComputePipelineState {
        if let cached = computeCache[technique] {
            return cached
        }

        let functionName: String
        switch technique {
        case .dvr:
            functionName = "dvrKernel"
        case .mip, .minip:
            functionName = "slabKernel"
        }

        guard let function = library.makeFunction(name: functionName) else {
            throw Error.pipelineUnavailable(function: functionName)
        }

        let pipeline = try device.makeComputePipelineState(function: function)
        computeCache[technique] = pipeline
        return pipeline
    }

    public func prepare(dataset: VolumeDataset,
                        texture: (any MTLTexture)? = nil) throws -> DatasetResources {
        let factory = VolumeTextureFactory(dataset: dataset)
        guard let texture = texture ?? factory.generate(device: device) else {
            throw Error.datasetUnavailable
        }

        let resources = DatasetResources(
            dataset: dataset,
            texture: texture,
            dimensions: factory.dimension,
            spacing: factory.resolution
        )
        currentDataset = resources
        return resources
    }

    @discardableResult
    public func load(dataset: VolumeDataset) throws -> DatasetResources {
        try prepare(dataset: dataset, texture: nil)
    }

    @discardableResult
    public func loadBuiltinDataset(for preset: VolumeDatasetPreset) throws -> DatasetResources {
        let factory = VolumeTextureFactory(preset: preset)
        guard let texture = factory.generate(device: device) else {
            logger.error("Failed to create built-in dataset for preset: \(preset.rawValue)")
            throw Error.datasetUnavailable
        }
        let resources = DatasetResources(
            dataset: factory.dataset,
            texture: texture,
            dimensions: factory.dimension,
            spacing: factory.resolution
        )
        currentDataset = resources
        return resources
    }

    public func makeFallbackImage(dataset: VolumeDataset,
                                  slice index: Int? = nil) -> CGImage? {
#if canImport(CoreGraphics)
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        let sliceIndex = max(0, min(index ?? depth / 2, depth - 1))
        let voxelsPerSlice = width * height
        var pixels = [UInt8](repeating: 0, count: voxelsPerSlice)
        let minValue = dataset.intensityRange.lowerBound
        let maxValue = dataset.intensityRange.upperBound
        let span = max(maxValue - minValue, 1)

        let startOffset = sliceIndex * voxelsPerSlice

        return dataset.data.withUnsafeBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            switch dataset.pixelFormat {
            case .int16Signed:
                let typed = baseAddress.bindMemory(to: Int16.self, capacity: dataset.voxelCount)
                for voxel in 0..<voxelsPerSlice {
                    let value = Int32(typed[startOffset + voxel])
                    let normalized = Float(value - minValue) / Float(span)
                    let clamped = simd_clamp(normalized, 0, 1)
                    pixels[voxel] = UInt8(clamping: Int(clamped * 255))
                }
            case .int16Unsigned:
                let typed = baseAddress.bindMemory(to: UInt16.self, capacity: dataset.voxelCount)
                for voxel in 0..<voxelsPerSlice {
                    let value = Int32(typed[startOffset + voxel])
                    let normalized = Float(value - minValue) / Float(span)
                    let clamped = simd_clamp(normalized, 0, 1)
                    pixels[voxel] = UInt8(clamping: Int(clamped * 255))
                }
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            let colorSpace = CGColorSpaceCreateDeviceGray()
            return CGImage(width: width,
                           height: height,
                           bitsPerComponent: 8,
                           bitsPerPixel: 8,
                           bytesPerRow: width,
                           space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider,
                           decode: nil,
                           shouldInterpolate: false,
                           intent: .defaultIntent)
        }
#else
        return nil
#endif
    }

    public func makeCommandBuffer(label: String? = nil) -> (any MTLCommandBuffer)? {
        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer?.label = label ?? "VolumeRenderingKit.CommandBuffer"
        return commandBuffer
    }

    public func resetCaches() {
        fragmentCache.removeAll(keepingCapacity: true)
        computeCache.removeAll(keepingCapacity: true)
    }
}
