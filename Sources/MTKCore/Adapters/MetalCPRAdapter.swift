//
//  MetalCPRAdapter.swift
//  MTK
//
//  Metal-backed stretched CPR and synchronized perpendicular reslicing.
//

import Foundation
@preconcurrency import Metal
import OSLog
import simd

@preconcurrency
public actor MetalCPRAdapter {
    public enum AdapterError: Error, LocalizedError {
        case commandQueueUnavailable
        case shaderLibraryUnavailable
        case pipelineUnavailable
        case volumeTextureCreationFailed
        case outputTextureCreationFailed
        case commandEncodingFailed
        /// The command buffer reached a terminal state other than `.completed`, so the
        /// kernel never ran and the output texture holds whatever it was allocated with.
        case dispatchDidNotRun(String)

        public var errorDescription: String? {
            switch self {
            case .commandQueueUnavailable:
                return "The CPR renderer could not create a Metal command queue."
            case .shaderLibraryUnavailable:
                return "The CPR Metal shader library is unavailable."
            case .pipelineUnavailable:
                return "The CPR Metal compute pipeline is unavailable."
            case .volumeTextureCreationFailed:
                return "The CPR renderer could not upload the volume texture."
            case .outputTextureCreationFailed:
                return "The CPR renderer could not allocate its output texture."
            case .commandEncodingFailed:
                return "The CPR renderer could not encode its compute command."
            case .dispatchDidNotRun(let reason):
                return "The CPR compute dispatch never ran: \(reason)."
            }
        }
    }

    private struct ColumnSample {
        var centerTexture: SIMD3<Float>
        var _pad0: Float = 0
        var verticalSpanTexture: SIMD3<Float>
        var _pad1: Float = 0
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let featureFlags: FeatureFlags
    private let mprAdapter: MetalMPRComputeAdapter
    private var pipelines: [VolumePixelFormat: any MTLComputePipelineState] = [:]
    private var cachedVolumeTexture: (any MTLTexture)?
    private var cachedDatasetIdentity: DatasetIdentity.CachedContent?
    /// Number of leading dispatches that skip the commit, standing in for a driver that
    /// discarded them. Tests only; zero everywhere else.
    private var discardedDispatchesForTesting = 0
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalCPRAdapter")

    /// Makes the next `count` dispatches skip the commit, so they complete with no error
    /// over an output texture the GPU never touched — what an innocent-victim discard
    /// leaves behind.
    @_spi(Testing)
    public func setDiscardedDispatchesForTesting(_ count: Int) {
        discardedDispatchesForTesting = count
    }

    public init(device: any MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw AdapterError.commandQueueUnavailable
        }
        let library: any MTLLibrary
        do {
            library = try ShaderLibraryLoader.loadLibrary(for: device)
        } catch {
            throw AdapterError.shaderLibraryUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        self.featureFlags = FeatureFlags.evaluate(for: device)
        self.mprAdapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: featureFlags,
            debugOptions: VolumeRenderingDebugOptions()
        )
    }

    public func makeStretchedTextureFrame(dataset: VolumeDataset,
                                          path: CPRSampledPath,
                                          authoringPlane: MPRPlaneGeometry,
                                          outputWidth: Int? = nil,
                                          outputHeight: Int = 512) async throws -> MPRTextureFrame {
        let width = min(max(outputWidth ?? path.samples.count, 2), 2_048)
        let height = min(max(outputHeight, 2), 2_048)
        let volumeTexture = try await provideVolumeTexture(for: dataset)
        let columns = makeColumns(path: path,
                                  authoringPlane: authoringPlane,
                                  dataset: dataset,
                                  count: width)
        guard let columnBuffer = device.makeBuffer(bytes: columns,
                                                   length: MemoryLayout<ColumnSample>.stride * columns.count,
                                                   options: .storageModeShared) else {
            throw AdapterError.commandEncodingFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: dataset.pixelFormat.rawIntensityMetalPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw AdapterError.outputTextureCreationFailed
        }
        outputTexture.label = "CPR.stretched.output"
        let pipeline = try pipeline(for: dataset.pixelFormat)
        try await dispatch(pipeline: pipeline,
                           volumeTexture: volumeTexture,
                           outputTexture: outputTexture,
                           columnBuffer: columnBuffer,
                           width: width,
                           height: height)
        var outputPlane = authoringPlane.sizedForOutput(
            CGSize(width: width, height: height)
        )
        if let first = path.samples.first, let last = path.samples.last {
            outputPlane.axisUWorld = CPRPathSampler.normalized(
                last.positionWorld - first.positionWorld,
                fallback: authoringPlane.axisUWorld
            ) * path.lengthMillimeters
        }
        return MPRTextureFrame(texture: outputTexture,
                               intensityRange: dataset.intensityRange,
                               pixelFormat: dataset.pixelFormat,
                               planeGeometry: outputPlane)
    }

    public func makePerpendicularTextureFrame(dataset: VolumeDataset,
                                              path: CPRSampledPath,
                                              progress: Float,
                                              outputSize: Int = 384) async throws -> MPRTextureFrame {
        let volumeTexture = try await provideVolumeTexture(for: dataset)
        let plane = CPRPlaneFactory.makePerpendicularPlane(path: path,
                                                           progress: progress,
                                                           dataset: dataset,
                                                           outputSize: outputSize)
        return try await mprAdapter.makeSlabTexture(dataset: dataset,
                                                    volumeTexture: volumeTexture,
                                                    plane: plane,
                                                    thickness: 1,
                                                    steps: 1,
                                                    blend: .single)
    }

    private func provideVolumeTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        if let cachedVolumeTexture,
           let cachedDatasetIdentity,
           cachedDatasetIdentity.matches(dataset: dataset) {
            return cachedVolumeTexture
        }
        do {
            let texture = try await VolumeTextureFactory(dataset: dataset).generateAsync(
                device: device,
                commandQueue: commandQueue,
                usage: .shaderRead
            )
            texture.label = "CPR.volumeTexture"
            cachedVolumeTexture = texture
            cachedDatasetIdentity = DatasetIdentity.CachedContent(dataset: dataset)
            return texture
        } catch {
            throw AdapterError.volumeTextureCreationFailed
        }
    }

    private func pipeline(for pixelFormat: VolumePixelFormat) throws -> any MTLComputePipelineState {
        if let pipeline = pipelines[pixelFormat] {
            return pipeline
        }
        let functionName = pixelFormat == .int16Signed
            ? "computeStretchedCPR"
            : "computeStretchedCPRUnsigned"
        guard let function = library.makeFunction(name: functionName) else {
            throw AdapterError.pipelineUnavailable
        }
        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            pipelines[pixelFormat] = pipeline
            return pipeline
        } catch {
            throw AdapterError.pipelineUnavailable
        }
    }

    private func makeColumns(path: CPRSampledPath,
                             authoringPlane: MPRPlaneGeometry,
                             dataset: VolumeDataset,
                             count: Int) -> [ColumnSample] {
        let span = CPRPlaneFactory.physicalSpan(for: dataset)
        let planeNormal = CPRPathSampler.normalized(authoringPlane.normalWorld,
                                                    fallback: dataset.imageData.sliceDirection)
        return (0..<count).map { index in
            let progress = count > 1 ? Float(index) / Float(count - 1) : 0
            let sample = path.sample(at: progress)
            let verticalUnit = CPRPathSampler.normalized(
                simd_cross(planeNormal, sample.tangentWorld),
                fallback: authoringPlane.axisVWorld
            )
            let centerTexture = CPRPlaneFactory.transformPoint(
                sample.positionWorld,
                by: dataset.imageData.worldToTexture
            )
            let verticalEndTexture = CPRPlaneFactory.transformPoint(
                sample.positionWorld + verticalUnit * span,
                by: dataset.imageData.worldToTexture
            )
            return ColumnSample(centerTexture: centerTexture,
                                verticalSpanTexture: verticalEndTexture - centerTexture)
        }
    }

    /// One retry after a dispatch that never ran; a real failure fails both attempts.
    ///
    /// The volume, the column buffer and the output texture are all still alive when it
    /// comes back, so the second attempt encodes the same curve, not a different one.
    private static let retriesAfterADiscardedDispatch = 1

    private func dispatch(pipeline: any MTLComputePipelineState,
                          volumeTexture: any MTLTexture,
                          outputTexture: any MTLTexture,
                          columnBuffer: any MTLBuffer,
                          width: Int,
                          height: Int) async throws {
        var attemptsLeft = Self.retriesAfterADiscardedDispatch
        while true {
            let attemptsMade = Self.retriesAfterADiscardedDispatch - attemptsLeft
            do {
                return try await dispatchOnce(pipeline: pipeline,
                                              volumeTexture: volumeTexture,
                                              outputTexture: outputTexture,
                                              columnBuffer: columnBuffer,
                                              width: width,
                                              height: height,
                                              simulatesDiscard: attemptsMade < discardedDispatchesForTesting)
            } catch let error as AdapterError {
                guard case .dispatchDidNotRun(let reason) = error, attemptsLeft > 0 else {
                    throw error
                }
                logger.error("CPR dispatch \(reason); retrying once.")
                attemptsLeft -= 1
            }
        }
    }

    /// Runs one stretched-CPR dispatch, or says it did not run.
    ///
    /// The kernel writes every column of a freshly allocated `.private` texture, and the
    /// CPU can read none of it, so the image carries no invariant to check: whatever is
    /// in that allocation looks like a curved reformat to everyone downstream. The
    /// command buffer's terminal state is the only thing that says the kernel ran, and
    /// only `.completed` says so — a buffer the driver discarded as the innocent victim
    /// of another process's GPU error stops on `.error`, status raw value 5, and can
    /// carry no error object at all.
    ///
    /// - Parameter simulatesDiscard: Skips the commit, standing in for a driver that
    ///   discarded the buffer. Tests only.
    private func dispatchOnce(pipeline: any MTLComputePipelineState,
                              volumeTexture: any MTLTexture,
                              outputTexture: any MTLTexture,
                              columnBuffer: any MTLBuffer,
                              width: Int,
                              height: Int,
                              simulatesDiscard: Bool) async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AdapterError.commandEncodingFailed
        }
        commandBuffer.label = "cpr_compute"
        encoder.label = "cpr_compute"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(columnBuffer, offset: 0, index: 0)
        let configuration = ThreadgroupDispatchConfiguration.default(for: pipeline)
        MetalDispatch.dispatch(
            encoder: encoder,
            threadsPerGrid: MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: configuration.threadsPerThreadgroup,
            featureFlags: featureFlags
        )
        encoder.endEncoding()
        // The test seam leaves the buffer uncommitted and asks it the same question, so a
        // check that stopped telling a dispatch that ran from one that did not would hand
        // the untouched texture back here as well — which is the bug, and what the test
        // sees.
        if simulatesDiscard {
            if let reason = CommandBufferCompletion.reasonItDidNotRun(commandBuffer) {
                throw AdapterError.dispatchDidNotRun(reason)
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let reason = CommandBufferCompletion.reasonItDidNotRun(buffer) {
                    continuation.resume(throwing: AdapterError.dispatchDidNotRun(reason))
                    return
                }
                continuation.resume(returning: ())
            }
            commandBuffer.commit()
        }
    }
}
