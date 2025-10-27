//
//  MetalVolumeRenderingAdapter.swift
//  MetalVolumetrics
//
//  Provides a CPU-backed approximation of the Metal volume renderer so unit
//  tests can exercise the domain contracts without depending on GPU
//  availability. The adapter maintains basic rendering state (windowing,
//  compositing, lighting) and returns fallback images alongside rich metadata.
//  Real GPU work will replace these code paths in future milestones.
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Metal
import OSLog
import simd
import DomainPorts
@preconcurrency import MetalRendering

@preconcurrency
public actor MetalVolumeRenderingAdapter: VolumeRenderingPort {
    public enum AdapterError: Error, Equatable {
        case invalidHistogramBinCount
    }

    public struct Overrides {
        public var compositing: VolumeRenderRequest.Compositing?
        public var samplingDistance: Float?
        public var window: ClosedRange<Int32>?
        public var lightingEnabled: Bool = true
    }

    public struct RenderSnapshot {
        public var dataset: VolumeDataset
        public var metadata: VolumeRenderResult.Metadata
        public var window: ClosedRange<Int32>
    }

    private let logger = Logger(subsystem: "com.isis.metalvolumetrics",
                                category: "MetalVolumeRenderingAdapter")
    private var overrides = Overrides()
    private var currentPreset: VolumeRenderingPreset?
    private var lastSnapshot: RenderSnapshot?
    private var metalState: MetalState?

    private struct DatasetIdentity: Equatable, Sendable {
        let pointer: UInt
        let count: Int

        init(dataset: VolumeDataset) {
            self.count = dataset.data.count
            self.pointer = dataset.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return UInt(bitPattern: baseAddress)
            }
        }
    }

    private struct MetalState: @unchecked Sendable {
        let device: any MTLDevice
        let raycaster: MetalRaycaster
        var datasetIdentity: DatasetIdentity?
    }

    public init() {}

    public func renderImage(using request: VolumeRenderRequest) async throws -> VolumeRenderResult {
        var effectiveRequest = request

        if let compositing = overrides.compositing {
            effectiveRequest.compositing = compositing
        }
        if let samplingDistance = overrides.samplingDistance {
            effectiveRequest.samplingDistance = samplingDistance
        }

        let window = overrides.window
            ?? request.dataset.recommendedWindow
            ?? request.dataset.intensityRange

        if let state = await resolveMetalState() {
            do {
                let updated = try updateMetalState(state, dataset: effectiveRequest.dataset)
                metalState = updated
            } catch {
                logger.error("Metal preparation failed: \(error.localizedDescription)")
                metalState = nil
            }
        }

        let result = await Task(priority: .userInitiated) {
            let image = Self.makeFallbackImage(dataset: effectiveRequest.dataset,
                                               window: window)
            let metadata = VolumeRenderResult.Metadata(
                viewportSize: effectiveRequest.viewportSize,
                samplingDistance: effectiveRequest.samplingDistance,
                compositing: effectiveRequest.compositing,
                quality: effectiveRequest.quality
            )
            return VolumeRenderResult(cgImage: image, metadata: metadata)
        }.value

        lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                      metadata: result.metadata,
                                      window: window)
        return result
    }

    public func updatePreset(_ preset: VolumeRenderingPreset,
                             for dataset: VolumeDataset) async throws -> [VolumeRenderingPreset] {
        currentPreset = preset
        if let state = metalState {
            do {
                let updated = try updateMetalState(state, dataset: dataset)
                metalState = updated
            } catch {
                logger.error("Preset update failed: \(error.localizedDescription)")
            }
        }
        return [preset]
    }

    public func refreshHistogram(for dataset: VolumeDataset,
                                 descriptor: VolumeHistogramDescriptor,
                                 transferFunction: VolumeTransferFunction) async throws -> VolumeHistogram {
        guard descriptor.binCount > 0 else {
            throw AdapterError.invalidHistogramBinCount
        }

        let bins = await Task.detached(priority: .userInitiated) {
            dataset.data.withUnsafeBytes { buffer -> [Float] in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    return [Float](repeating: 0, count: descriptor.binCount)
                }

                let binCount = descriptor.binCount
                var histogram = [Float](repeating: 0, count: binCount)

                let lowerBound = descriptor.intensityRange.lowerBound
                let upperBound = descriptor.intensityRange.upperBound
                let span = max(upperBound - lowerBound, Float.leastNonzeroMagnitude)
                let binWidth = span / Float(binCount)

                reader.forEachIntensity { sample in
                    let clamped = min(max(sample, lowerBound), upperBound)
                    var index = Int((clamped - lowerBound) / binWidth)
                    if index >= binCount {
                        index = binCount - 1
                    }
                    histogram[index] += 1
                }

                if descriptor.normalize {
                    let total = histogram.reduce(0, +)
                    if total > 0 {
                        for index in histogram.indices {
                            histogram[index] /= total
                        }
                    }
                }

                return histogram
            }
        }.value

        return VolumeHistogram(descriptor: descriptor, bins: bins)
    }

    public func send(_ command: VolumeRenderingCommand) async throws {
        switch command {
        case .setCompositing(let compositing):
            overrides.compositing = compositing
        case .setWindow(let minValue, let maxValue):
            overrides.window = minValue...maxValue
        case .setSamplingStep(let samplingDistance):
            overrides.samplingDistance = samplingDistance
        case .setLighting(let enabled):
            overrides.lightingEnabled = enabled
        }
    }
}

// MARK: - Testing SPI

extension MetalVolumeRenderingAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: RenderSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugCurrentPreset: VolumeRenderingPreset? { currentPreset }
}

// MARK: - Helpers

private extension MetalVolumeRenderingAdapter {
    private func resolveMetalState() async -> MetalState? {
        if let state = metalState {
            return state
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        do {
            let raycaster = try MetalRaycaster(device: device)
            let state = MetalState(device: device, raycaster: raycaster, datasetIdentity: nil)
            metalState = state
            return state
        } catch {
            logger.error("Unable to create Metal raycaster: \(error.localizedDescription)")
            return nil
        }
    }

    private func updateMetalState(_ state: MetalState,
                                  dataset: VolumeDataset) throws -> MetalState {
        var updated = state
        let identity = DatasetIdentity(dataset: dataset)
        if updated.datasetIdentity != identity {
            _ = try updated.raycaster.load(dataset: dataset)
            updated.datasetIdentity = identity
        }
        return updated
    }

    static func makeFallbackImage(dataset: VolumeDataset,
                                  window: ClosedRange<Int32>) -> CGImage? {
#if canImport(CoreGraphics)
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        guard width > 0, height > 0, depth > 0 else { return nil }

        let sliceIndex = depth / 2
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        let lower = Float(window.lowerBound)
        let upper = Float(window.upperBound)
        let span = max(upper - lower, Float.leastNonzeroMagnitude)

        dataset.data.withUnsafeBytes { buffer in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else { return }

            for y in 0..<height {
                for x in 0..<width {
                    let intensity = reader.intensity(x: x, y: y, z: sliceIndex)
                    let normalized = (intensity - lower) / span
                    let clamped = max(0, min(1, normalized))
                    pixels[y * width + x] = UInt8(clamping: Int(round(clamped * 255)))
                }
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
#else
        return nil
#endif
    }
}
