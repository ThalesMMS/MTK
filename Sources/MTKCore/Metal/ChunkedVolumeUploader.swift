//
//  ChunkedVolumeUploader.swift
//  MTK
//
//  Slice-by-slice GPU upload into private volume textures.
//

import Foundation
@preconcurrency import Metal
import os.signpost

public enum ChunkedVolumeUploadError: Error, Equatable {
    case textureCreationFailed
    case stagingBufferCreationFailed
    case commandBufferCreationFailed
    case invalidDimensions(VolumeDimensions)
    case invalidSliceIndex(Int)
    case duplicateSliceIndex(Int)
    case missingSliceIndices([Int])
    case dimensionByteCountOverflow(VolumeDimensions)
    case invalidSliceByteCount(expected: Int, actual: Int)
    case invalidSliceData(sliceIndex: Int)
    case commandBufferExecutionFailed(String)
}

public final class ChunkedVolumeUploader {
    public typealias ProgressHandler = VolumeUploadProgressHandler

    private static let maximumInFlightUploads = 3
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: HUConversionPipeline
    private let memorySignpostLog = OSLog(subsystem: "com.mtk.volumerendering",
                                          category: "UploadMemory")

    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue,
                pipeline: HUConversionPipeline? = nil) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try pipeline ?? HUConversionPipeline(device: device)
    }

    public func upload<S: AsyncSequence>(
        slices: S,
        descriptor: VolumeUploadDescriptor,
        progress: ProgressHandler? = nil
    ) async throws -> any MTLTexture where S.Element == VolumeUploadSlice {
        let cancellationState = ChunkedUploadCancellationState()
        return try await withTaskCancellationHandler {
            try await performUpload(slices: slices,
                                    descriptor: descriptor,
                                    progress: progress,
                                    cancellationState: cancellationState)
        } onCancel: {
            cancellationState.markCancelled()
        }
    }

    private func performUpload<S: AsyncSequence>(
        slices: S,
        descriptor: VolumeUploadDescriptor,
        progress: ProgressHandler?,
        cancellationState: ChunkedUploadCancellationState
    ) async throws -> any MTLTexture where S.Element == VolumeUploadSlice {
        let preparationStartedAt = CFAbsoluteTimeGetCurrent()
        try validate(dimensions: descriptor.dimensions)
        try Task.checkCancellation()
        if cancellationState.isCancelled {
            throw CancellationError()
        }
        let sliceByteCount = try makeSliceByteCount(dimensions: descriptor.dimensions,
                                                    sourcePixelFormat: descriptor.sourcePixelFormat)

        // StorageModePolicy.md: chunked uploads always target the final private volume texture.
        let textureDescriptor = VolumeTextureFactory.makeVolumeTextureDescriptor(
            dimensions: descriptor.dimensions,
            pixelFormat: .int16Signed,
            storageMode: .private,
            usage: [.shaderRead, .shaderWrite, .pixelFormatView]
        )

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ChunkedVolumeUploadError.textureCreationFailed
        }
        texture.label = "ChunkedVolumeUploader.VolumeTexture3D"

        // StorageModePolicy.md: keep a bounded ring of shared/write-combined staging slices.
        let stagingBufferCount = min(Self.maximumInFlightUploads, descriptor.dimensions.depth)
        var stagingBuffers: [any MTLBuffer] = []
        stagingBuffers.reserveCapacity(stagingBufferCount)
        for index in 0..<stagingBufferCount {
            guard let stagingBuffer = device.makeBuffer(
                length: sliceByteCount,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]
            ) else {
                throw ChunkedVolumeUploadError.stagingBufferCreationFailed
            }
            stagingBuffer.label = "ChunkedVolumeUploader.StagingSlice.\(index)"
            stagingBuffers.append(stagingBuffer)
        }
        let stagingMemory = stagingBuffers.reduce(0) { $0 + $1.length }

        let totalSlices = descriptor.dimensions.depth
        let textureMemory = ResourceMemoryEstimator.estimate(for: texture)
        var peakMemoryBytes = 0
        let startedAt = CFAbsoluteTimeGetCurrent()
        ClinicalProfiler.shared.recordSample(
            stage: .texturePreparation,
            cpuTime: ClinicalProfiler.milliseconds(from: preparationStartedAt),
            memory: textureMemory + stagingMemory,
            viewport: .unknown,
            metadata: [
                "path": "ChunkedVolumeUploader.prepare",
                "dimensions": "\(descriptor.dimensions.width)x\(descriptor.dimensions.height)x\(descriptor.dimensions.depth)",
                "sliceCount": String(totalSlices),
                "stagingBufferCount": String(stagingBufferCount)
            ],
            device: device
        )
        var processedSlices = 0
        var submittedSlices = 0
        var seenIndices = Set<Int>()
        var inFlightUploads = Array<InFlightUpload?>(repeating: nil,
                                                     count: stagingBufferCount)
        var totalCommandCPUTime = 0.0
        var totalCommandGPUTime = 0.0
        var totalKernelTime = 0.0
        let signpostID = OSSignpostID(log: memorySignpostLog)
        os_signpost(.begin,
                    log: memorySignpostLog,
                    name: "ChunkedVolumeUploadMemory",
                    signpostID: signpostID,
                    "texture=%{public}ld staging=%{public}ld buffers=%{public}ld",
                    textureMemory,
                    stagingMemory,
                    stagingBufferCount)
        defer {
            os_signpost(.end,
                        log: memorySignpostLog,
                        name: "ChunkedVolumeUploadMemory",
                        signpostID: signpostID,
                        "peak=%{public}ld",
                        peakMemoryBytes)
        }

        updatePeakMemory(textureBytes: textureMemory,
                         stagingBytes: stagingMemory,
                         peakMemoryBytes: &peakMemoryBytes,
                         signpostID: signpostID)

        await emit(.started(totalSlices: totalSlices), to: progress)

        do {
            for try await slice in slices {
                try Task.checkCancellation()
                if cancellationState.isCancelled {
                    throw CancellationError()
                }
                guard (0..<totalSlices).contains(slice.index) else {
                    throw ChunkedVolumeUploadError.invalidSliceIndex(slice.index)
                }
                guard seenIndices.insert(slice.index).inserted else {
                    throw ChunkedVolumeUploadError.duplicateSliceIndex(slice.index)
                }
                guard slice.data.count == sliceByteCount else {
                    throw ChunkedVolumeUploadError.invalidSliceByteCount(expected: sliceByteCount,
                                                                        actual: slice.data.count)
                }

                let stagingSlot = submittedSlices % stagingBufferCount
                if let pendingUpload = inFlightUploads[stagingSlot] {
                    inFlightUploads[stagingSlot] = nil
                    let timings = try await pendingUpload.completion.value
                    if cancellationState.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }
                    totalCommandCPUTime += timings.cpuTime
                    totalCommandGPUTime += timings.gpuTime
                    totalKernelTime += timings.kernelTime
                    processedSlices += 1
                    await emit(.uploadingSlice(current: processedSlices,
                                               total: totalSlices),
                               to: progress)
                }

                let stagingBuffer = stagingBuffers[stagingSlot]
                try copy(slice: slice,
                         expectedByteCount: sliceByteCount,
                         to: stagingBuffer)

                guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                    throw ChunkedVolumeUploadError.commandBufferCreationFailed
                }
                let commandStartedAt = CFAbsoluteTimeGetCurrent()
                commandBuffer.label = "ChunkedVolumeUploader.UploadSlice.\(slice.index)"

                let params = HUConversionParameters(
                    slope: Float(slice.slope),
                    intercept: Float(slice.intercept),
                    minClamp: slice.minClamp,
                    maxClamp: slice.maxClamp,
                    sliceIndex: UInt32(slice.index),
                    sliceWidth: UInt32(descriptor.dimensions.width),
                    sliceHeight: UInt32(descriptor.dimensions.height)
                )
                try pipeline.encode(stagingBuffer: stagingBuffer,
                                    to: texture,
                                    sourcePixelFormat: descriptor.sourcePixelFormat,
                                    params: params,
                                    commandBuffer: commandBuffer)
                CommandBufferProfiler.captureTimes(for: commandBuffer,
                                                   label: "chunked-upload-in-flight",
                                                   category: "Upload")

                let completion = Task {
                    try await self.waitForCompletion(commandBuffer,
                                                     cpuStart: commandStartedAt)
                }
                inFlightUploads[stagingSlot] = InFlightUpload(
                    submissionOrder: submittedSlices,
                    completion: completion
                )
                submittedSlices += 1
            }

            let remainingUploads = inFlightUploads.compactMap { $0 }.sorted {
                $0.submissionOrder < $1.submissionOrder
            }
            for pendingUpload in remainingUploads {
                let timings = try await pendingUpload.completion.value
                if cancellationState.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                totalCommandCPUTime += timings.cpuTime
                totalCommandGPUTime += timings.gpuTime
                totalKernelTime += timings.kernelTime
                processedSlices += 1
                await emit(.uploadingSlice(current: processedSlices,
                                           total: totalSlices),
                               to: progress)
            }
            inFlightUploads = Array(repeating: nil, count: stagingBufferCount)
        } catch {
            for pendingUpload in inFlightUploads.compactMap({ $0 }) {
                _ = try? await pendingUpload.completion.value
            }
            throw error
        }

        let missingIndices = (0..<totalSlices).filter { !seenIndices.contains($0) }
        guard missingIndices.isEmpty else {
            throw ChunkedVolumeUploadError.missingSliceIndices(missingIndices)
        }
        try Task.checkCancellation()
        if cancellationState.isCancelled {
            throw CancellationError()
        }

        ClinicalProfiler.shared.recordSample(
            stage: .huConversion,
            cpuTime: totalCommandCPUTime,
            gpuTime: totalCommandGPUTime > 0 ? totalCommandGPUTime : nil,
            memory: textureMemory + stagingMemory,
            viewport: .unknown,
            metadata: [
                "path": "ChunkedVolumeUploader.upload",
                "slicesProcessed": String(processedSlices),
                "effectiveStagingBufferCount": String(stagingBufferCount),
                "kernelTimeMilliseconds": String(format: "%.6f", totalKernelTime)
            ],
            device: device
        )

        let metrics = VolumeUploadMetrics(
            uploadTimeSeconds: CFAbsoluteTimeGetCurrent() - startedAt,
            peakMemoryBytes: peakMemoryBytes,
            slicesProcessed: processedSlices
        )
        ClinicalProfiler.shared.recordSample(
            stage: .textureUpload,
            cpuTime: metrics.uploadTimeSeconds * 1000.0,
            memory: metrics.peakMemoryBytes,
            viewport: .unknown,
            metadata: [
                "path": "ChunkedVolumeUploader.upload",
                "slicesProcessed": String(processedSlices),
                "dimensions": "\(descriptor.dimensions.width)x\(descriptor.dimensions.height)x\(descriptor.dimensions.depth)"
            ],
            device: device
        )
        await emit(.completed(metrics: metrics), to: progress)
        return texture
    }

    private func updatePeakMemory(textureBytes: Int,
                                  stagingBytes: Int,
                                  peakMemoryBytes: inout Int,
                                  signpostID: OSSignpostID) {
        let currentBytes = textureBytes + stagingBytes
        guard currentBytes > peakMemoryBytes else {
            return
        }
        peakMemoryBytes = currentBytes
        os_signpost(.event,
                    log: memorySignpostLog,
                    name: "ChunkedVolumeUploadMemoryPeak",
                    signpostID: signpostID,
                    "peak=%{public}ld",
                    peakMemoryBytes)
    }

    private func emit(_ event: VolumeUploadProgress,
                      to progress: ProgressHandler?) async {
        guard let progress else { return }
        await progress(event)
    }

    /// - Important: the ceiling here is `type3D`'s **2048**, not `UInt32.max`.
    ///   Anything past it reaches `-[MTLTextureDescriptorInternal
    ///   validateWithDevice:]`, which calls `abort()` — so the `guard let` on
    ///   `makeTexture` below never runs and the process is simply gone. This
    ///   uploader is a second route to that same descriptor, and #1682 only
    ///   closed the one in `VolumeTextureFactory`.
    private func validate(dimensions: VolumeDimensions) throws {
        let maximumExtent = VolumeTextureFactory.maximumVolumeTextureExtent
        guard dimensions.width > 0,
              dimensions.height > 0,
              dimensions.depth > 0,
              dimensions.width <= maximumExtent,
              dimensions.height <= maximumExtent,
              dimensions.depth <= maximumExtent else {
            throw ChunkedVolumeUploadError.invalidDimensions(dimensions)
        }
    }

    private func makeSliceByteCount(dimensions: VolumeDimensions,
                                    sourcePixelFormat: VolumePixelFormat) throws -> Int {
        let sliceVoxels = dimensions.width.multipliedReportingOverflow(by: dimensions.height)
        guard !sliceVoxels.overflow, sliceVoxels.partialValue > 0 else {
            throw ChunkedVolumeUploadError.dimensionByteCountOverflow(dimensions)
        }

        let sliceBytes = sliceVoxels.partialValue.multipliedReportingOverflow(
            by: sourcePixelFormat.bytesPerVoxel
        )
        guard !sliceBytes.overflow, sliceBytes.partialValue > 0 else {
            throw ChunkedVolumeUploadError.dimensionByteCountOverflow(dimensions)
        }
        return sliceBytes.partialValue
    }

    private func copy(slice: VolumeUploadSlice,
                      expectedByteCount: Int,
                      to stagingBuffer: any MTLBuffer) throws {
        try slice.data.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.baseAddress else {
                throw ChunkedVolumeUploadError.invalidSliceData(sliceIndex: slice.index)
            }
            memcpy(stagingBuffer.contents(), source, expectedByteCount)
        }
    }

    private func waitForCompletion(_ commandBuffer: any MTLCommandBuffer,
                                   cpuStart: CFAbsoluteTime) async throws -> CommandBufferTimings {
        let cpuEnd = CFAbsoluteTimeGetCurrent()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                // The conversion kernel writes into a `.private` 3D texture, so there is
                // nothing readable here to check against: only the command buffer's
                // terminal state says whether the slice reached the volume, and only
                // `.completed` says it did. A buffer the driver discarded as the innocent
                // victim of another process's GPU error stops on `.error` — status raw
                // value 5 — and can carry no error object at all, which is why the status
                // is asked about and not just `buffer.error`.
                //
                // There is no retry here on purpose: by the time this handler runs the
                // caller is free to refill this slot's staging buffer with the next slice,
                // so the voxels this dispatch was given are already gone. Recovering one
                // discarded slice means starting the upload over, which is the caller's
                // decision, not ours.
                if let reason = CommandBufferCompletion.reasonItDidNotRun(buffer) {
                    continuation.resume(throwing: ChunkedVolumeUploadError.commandBufferExecutionFailed(reason))
                    return
                }
                continuation.resume()
            }
            commandBuffer.commit()
        }
        return commandBuffer.timings(cpuStart: cpuStart,
                                     cpuEnd: cpuEnd)
    }
}

private struct InFlightUpload {
    let submissionOrder: Int
    let completion: Task<CommandBufferTimings, Error>
}

private final class ChunkedUploadCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
