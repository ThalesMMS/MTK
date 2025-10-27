//
//  MPSVolumeRenderer.swift
//  Isis DICOM Viewer
//
//  Implementa um renderizador volumétrico baseado em Metal Performance Shaders capaz de calcular histogramas, filtros gaussianos e texturas 3D para volumes DICOM.
//  Também administra interseções de raios e buffers auxiliares para acelerar amostragens, encapsulando detalhes de GPU e garantindo fallback seguros para dispositivos incompatíveis.
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation
import Metal
import MetalPerformanceShaders
import OSLog
import simd

#if canImport(MetalPerformanceShaders)
public final class MPSVolumeRenderer {
    public struct HistogramResult: Equatable {
        public let bins: [Float]
        public let intensityRange: ClosedRange<Float>
    }

    public struct Ray: Equatable {
        public var origin: SIMD3<Float>
        public var direction: SIMD3<Float>

        /// Creates a ray using the provided origin and normalizes the supplied
        /// direction, falling back to the positive Z axis when normalization
        /// produces an invalid vector.
        init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
            let normalized = simd_normalize(direction)
            self.origin = origin
            if normalized.x.isFinite && normalized.y.isFinite && normalized.z.isFinite {
                self.direction = normalized
            } else {
                self.direction = SIMD3<Float>(0, 0, 1)
            }
        }
    }

    public struct RayCastingSample: Equatable {
        public var ray: Ray
        public var entryDistance: Float
        public var exitDistance: Float
    }

    public enum RendererError: Swift.Error, Equatable {
        case unsupportedDevice
        case commandBufferUnavailable
        case histogramEncodingFailed
        case texturePreparationFailed
        case blitEncoderUnavailable
        case sliceViewUnavailable
        case unsupportedPixelFormat
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let logger = Logger(subsystem: "com.isis.volumerenderingkit",
                                category: "MPSVolumeRenderer")
    private var histogramInfo: MPSImageHistogramInfo
    private let histogramKernel: MPSImageHistogram

    public init?(device: any MTLDevice, commandQueue: (any MTLCommandQueue)? = nil) {
        guard MPSSupportsMTLDevice(device) else { return nil }
        guard let queue = commandQueue ?? device.makeCommandQueue() else { return nil }

        self.device = device
        self.commandQueue = queue

        var histogramInfo = MPSImageHistogramInfo(
            numberOfHistogramEntries: 4096,
            histogramForAlpha: false,
            minPixelValue: SIMD4<Float>(repeating: -1024),
            maxPixelValue: SIMD4<Float>(repeating: 3071)
        )
        self.histogramInfo = histogramInfo
        self.histogramKernel = MPSImageHistogram(device: device, histogramInfo: &histogramInfo)
    }

    public func prepareHistogram(dataset: VolumeDataset) throws -> HistogramResult {
        guard shouldUseGPUHistogram(for: dataset) else {
            return prepareHistogramOnCPU(dataset: dataset)
        }

        guard let texture = VolumeTextureFactory(dataset: dataset).generate(device: device) else {
            throw RendererError.texturePreparationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.commandBufferUnavailable
        }
        let sliceTexture = try makeSliceTexture(
            from: texture,
            on: commandBuffer,
            label: "MPSVolumeRenderer.Histogram.Slices"
        )

        let histogramSize = histogramKernel.histogramSize(forSourceFormat: sliceTexture.pixelFormat)
        guard let histogramBuffer = device.makeBuffer(length: histogramSize, options: .storageModeShared) else {
            throw RendererError.histogramEncodingFailed
        }

        histogramBuffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: histogramSize)

        switch sliceTexture.textureType {
        case .type2D:
            histogramKernel.encode(
                to: commandBuffer,
                sourceTexture: sliceTexture,
                histogram: histogramBuffer,
                histogramOffset: 0
            )
        case .type2DArray:
            let sliceCount = max(sliceTexture.arrayLength, 1)
            for sliceIndex in 0..<sliceCount {
                guard let sliceView = sliceTexture.makeTextureView(
                    pixelFormat: sliceTexture.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: sliceIndex..<(sliceIndex + 1)
                ) else {
                    throw RendererError.sliceViewUnavailable
                }
                histogramKernel.encode(
                    to: commandBuffer,
                    sourceTexture: sliceView,
                    histogram: histogramBuffer,
                    histogramOffset: 0
                )
            }
        default:
            throw RendererError.sliceViewUnavailable
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let entryCount = Int(histogramInfo.numberOfHistogramEntries)
        var bins = [Float](repeating: 0, count: entryCount)
        histogramBuffer.contents().withMemoryRebound(to: UInt32.self, capacity: entryCount) { pointer in
            for index in 0..<entryCount {
                bins[index] = Float(pointer[index])
            }
        }

        return HistogramResult(
            bins: bins,
            intensityRange: Float(histogramInfo.minPixelValue.x)...Float(histogramInfo.maxPixelValue.x)
        )
    }

    public func applyGaussianFilter(dataset: VolumeDataset, sigma: Float) throws -> (any MTLTexture) {
        let factory = VolumeTextureFactory(dataset: dataset)
        guard let source = factory.generate(device: device) else {
            throw RendererError.texturePreparationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.commandBufferUnavailable
        }
        let view = try makeSliceTexture(from: source,
                                        on: commandBuffer,
                                        label: "MPSVolumeRenderer.Gaussian.SourceSlices")
        guard let floatPixelFormat = view.pixelFormat.gaussianCompatibleFloatFormat else {
            throw RendererError.unsupportedPixelFormat
        }

        let floatDescriptor = makeSliceDescriptor(
            from: view,
            pixelFormat: floatPixelFormat,
            usage: [.shaderRead, .shaderWrite]
        )

        guard let floatSource = device.makeTexture(descriptor: floatDescriptor),
              let floatDestination = device.makeTexture(descriptor: floatDescriptor) else {
            throw RendererError.texturePreparationFailed
        }
        floatSource.label = "MPSVolumeRenderer.Gaussian.FloatSource"
        floatDestination.label = "MPSVolumeRenderer.Gaussian.FloatDestination"

        convertTexture(on: commandBuffer,
                        source: view,
                        destination: floatSource)

        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.encode(commandBuffer: commandBuffer,
                      sourceTexture: floatSource,
                      destinationTexture: floatDestination)

        let integerDescriptor = makeSliceDescriptor(
            from: view,
            pixelFormat: view.pixelFormat,
            usage: [.shaderRead, .shaderWrite]
        )
        guard let destination = device.makeTexture(descriptor: integerDescriptor) else {
            throw RendererError.texturePreparationFailed
        }
        destination.label = "MPSVolumeRenderer.Gaussian.Slices"

        convertTexture(on: commandBuffer,
                        source: floatDestination,
                        destination: destination)

        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = source.pixelFormat
        volumeDescriptor.width = source.width
        volumeDescriptor.height = source.height
        volumeDescriptor.depth = source.depth
        volumeDescriptor.mipmapLevelCount = 1
        volumeDescriptor.usage = [.shaderRead]
        guard let volumeTexture = device.makeTexture(descriptor: volumeDescriptor) else {
            throw RendererError.texturePreparationFailed
        }
        volumeTexture.label = "MPSVolumeRenderer.Gaussian.Volume"

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "MPSVolumeRenderer.Gaussian.Copy"
            let size = MTLSize(width: source.width, height: source.height, depth: 1)
            let origin = MTLOrigin(x: 0, y: 0, z: 0)
            for slice in 0..<source.depth {
                blit.copy(from: destination,
                          sourceSlice: slice,
                          sourceLevel: 0,
                          sourceOrigin: origin,
                          sourceSize: size,
                          to: volumeTexture,
                          destinationSlice: 0,
                          destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: slice))
            }
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return volumeTexture
    }

    public func performBoundingBoxRayCast(dataset: VolumeDataset,
                                           rays: [Ray]) throws -> [RayCastingSample] {
        guard !rays.isEmpty else { return [] }

        let boundingBox = makeBoundingBox(for: dataset)
        let minPoint = SIMD3<Float>(boundingBox.min.x, boundingBox.min.y, boundingBox.min.z)
        let maxPoint = SIMD3<Float>(boundingBox.max.x, boundingBox.max.y, boundingBox.max.z)

        var samples: [RayCastingSample] = []
        samples.reserveCapacity(rays.count)

        for ray in rays {
            guard let (entry, exit) = intersect(ray: ray, minPoint: minPoint, maxPoint: maxPoint) else {
                continue
            }
            let clampedEntry = max(entry, 0)
            guard exit >= clampedEntry else { continue }
            samples.append(RayCastingSample(ray: ray, entryDistance: clampedEntry, exitDistance: exit))
        }

        return samples
    }
}

private extension MPSVolumeRenderer {
    private func shouldUseGPUHistogram(for dataset: VolumeDataset) -> Bool {
        switch dataset.pixelFormat {
        case .int16Signed, .int16Unsigned:
            return false
        }
    }

    private func prepareHistogramOnCPU(dataset: VolumeDataset) -> HistogramResult {
        let entryCount = Int(histogramInfo.numberOfHistogramEntries)
        guard entryCount > 0 else {
            let intensityRange = Float(histogramInfo.minPixelValue.x)...Float(histogramInfo.maxPixelValue.x)
            return HistogramResult(bins: [], intensityRange: intensityRange)
        }

        var bins = [Float](repeating: 0, count: entryCount)
        histogramInfo.minPixelValue = SIMD4<Float>(repeating: Float(dataset.intensityRange.lowerBound))
        histogramInfo.maxPixelValue = SIMD4<Float>(repeating: Float(dataset.intensityRange.upperBound))
        let minimum = Int(dataset.intensityRange.lowerBound)
        let maximum = Int(dataset.intensityRange.upperBound)

        if minimum >= maximum || entryCount == 1 {
            if entryCount > 0 {
                bins[0] = Float(dataset.voxelCount)
            }
            let intensityRange = Float(minimum)...Float(maximum)
            return HistogramResult(bins: bins, intensityRange: intensityRange)
        }

        let range = maximum - minimum
        let scale = Double(entryCount - 1) / Double(range)

        func accumulate(_ rawValue: Int) {
            let clamped = min(max(rawValue, minimum), maximum)
            let normalized = Double(clamped - minimum) * scale
            let index = max(0, min(entryCount - 1, Int(normalized)))
            bins[index] += 1
        }

        dataset.data.withUnsafeBytes { rawBuffer in
            guard !rawBuffer.isEmpty else { return }
            switch dataset.pixelFormat {
            case .int16Signed:
                let values = rawBuffer.bindMemory(to: Int16.self)
                for value in values {
                    accumulate(Int(value))
                }
            case .int16Unsigned:
                let values = rawBuffer.bindMemory(to: UInt16.self)
                for value in values {
                    accumulate(Int(value))
                }
            }
        }

        let intensityRange = Float(minimum)...Float(maximum)
        return HistogramResult(bins: bins, intensityRange: intensityRange)
    }

    private func makeSliceTexture(
        from volume: any MTLTexture,
        on commandBuffer: any MTLCommandBuffer,
        label: String
    ) throws -> any MTLTexture {
        guard volume.textureType == .type3D else {
            return volume
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = volume.pixelFormat
        descriptor.width = volume.width
        descriptor.height = volume.height
        descriptor.arrayLength = volume.depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = volume.storageMode

        guard let sliceTexture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.texturePreparationFailed
        }
        sliceTexture.label = label

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.blitEncoderUnavailable
        }
        let copySize = MTLSize(width: volume.width, height: volume.height, depth: 1)
        let destinationOrigin = MTLOrigin(x: 0, y: 0, z: 0)
        for slice in 0..<volume.depth {
            blitEncoder.copy(from: volume,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: slice),
                             sourceSize: copySize,
                             to: sliceTexture,
                             destinationSlice: slice,
                             destinationLevel: 0,
                             destinationOrigin: destinationOrigin)
        }
        blitEncoder.endEncoding()
        return sliceTexture
    }

    private func intersect(ray: Ray,
                           minPoint: SIMD3<Float>,
                           maxPoint: SIMD3<Float>) -> (Float, Float)? {
        let slabs: [(Float, Float, Float, Float)] = [
            (ray.origin.x, ray.direction.x, minPoint.x, maxPoint.x),
            (ray.origin.y, ray.direction.y, minPoint.y, maxPoint.y),
            (ray.origin.z, ray.direction.z, minPoint.z, maxPoint.z)
        ]

        var entry: Float = -.infinity
        var exit: Float = .infinity

        for (origin, direction, minimum, maximum) in slabs {
            if abs(direction) <= Float.ulpOfOne {
                if origin < minimum || origin > maximum {
                    return nil
                }
                continue
            }

            let inverse = 1 / direction
            let t0 = (minimum - origin) * inverse
            let t1 = (maximum - origin) * inverse
            let slabMin = min(t0, t1)
            let slabMax = max(t0, t1)

            entry = max(entry, slabMin)
            exit = min(exit, slabMax)

            if exit < entry {
                return nil
            }
        }

        return (entry, exit)
    }

    private func makeBoundingBox(for dataset: VolumeDataset) -> MPSAxisAlignedBoundingBox {
        let width = Float(dataset.dimensions.width)
        let height = Float(dataset.dimensions.height)
        let depth = Float(dataset.dimensions.depth)
        let spacing = dataset.spacing
        let maxPoint = vector_float3(Float(spacing.x) * width,
                                     Float(spacing.y) * height,
                                     Float(spacing.z) * depth)
        var box = MPSAxisAlignedBoundingBox()
        box.min = vector_float3(0, 0, 0)
        box.max = maxPoint
        return box
    }

}

private extension MPSVolumeRenderer {
    func convertTexture(on commandBuffer: any MTLCommandBuffer,
                        source: any MTLTexture,
                        destination: any MTLTexture) {
        let conversion = MPSImageConversion(
            device: device,
            srcAlpha: .alphaIsOne,
            destAlpha: .alphaIsOne,
            backgroundColor: nil,
            conversionInfo: nil
        )
        conversion.encode(commandBuffer: commandBuffer,
                           sourceTexture: source,
                           destinationTexture: destination)
    }

    func makeSliceDescriptor(from texture: any MTLTexture,
                             pixelFormat: MTLPixelFormat,
                             usage: MTLTextureUsage) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = max(texture.arrayLength, 1)
        descriptor.pixelFormat = pixelFormat
        descriptor.width = texture.width
        descriptor.height = texture.height
        descriptor.mipmapLevelCount = 1
        descriptor.usage = usage
        descriptor.storageMode = texture.storageMode
        return descriptor
    }
}

private extension MTLPixelFormat {
    var gaussianCompatibleFloatFormat: MTLPixelFormat? {
        switch self {
        case .r16Sint:
            return .r16Float
        case .r16Float, .r32Float:
            return self
        default:
            return nil
        }
    }
}
#endif
