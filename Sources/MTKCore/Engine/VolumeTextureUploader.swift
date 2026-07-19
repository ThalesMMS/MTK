//
//  VolumeTextureUploader.swift
//  MTK
//
//  Extracted from VolumeResourceManager to isolate dataset-to-texture upload.
//  This type is internal and intentionally thin; it preserves existing upload
//  behavior and profiling measurements.
//

import Foundation
@preconcurrency import Metal

/// Uploads volume datasets / slice streams into 3D Metal textures.
///
/// Note: `VolumeResourceManager` and `MTKRenderingEngine` provide actor isolation
/// for thread-safety. This uploader does not add additional synchronization.
final class VolumeTextureUploader {
    struct UploadResult {
        let texture: any MTLTexture
        let uploadTime: CFAbsoluteTime
        let peakMemoryBytes: Int?
    }

    struct StreamUploadResult {
        let result: UploadResult
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
    }

    func upload(dataset: VolumeDataset) async throws -> UploadResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let texture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device,
                           commandQueue: commandQueue,
                           usage: [.shaderRead, .pixelFormatView])
        let uploadTime = CFAbsoluteTimeGetCurrent() - startedAt
        return UploadResult(texture: texture, uploadTime: uploadTime, peakMemoryBytes: nil)
    }

    func upload<S: AsyncSequence>(
        descriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws -> StreamUploadResult where S.Element == VolumeUploadSlice {
        let validatedSlices = ValidatedVolumeUploadSliceSequence(
            base: slices,
            intensityRange: descriptor.intensityRange
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let uploader = try ChunkedVolumeUploader(device: device, commandQueue: commandQueue)
        let metricsRecorder = VolumeUploadMetricsRecorder()
        let forwardingProgress = makeForwardingProgress(progress, metricsRecorder: metricsRecorder)

        let texture = try await uploader.upload(
            slices: validatedSlices,
            descriptor: descriptor,
            progress: forwardingProgress
        )

        let uploadTime = CFAbsoluteTimeGetCurrent() - startedAt
        let result = UploadResult(
            texture: texture,
            uploadTime: uploadTime,
            peakMemoryBytes: metricsRecorder.metrics?.peakMemoryBytes
        )
        return StreamUploadResult(result: result)
    }

    func upload<S: AsyncSequence>(
        sliceStream: S,
        metadata: VolumeUploadDescriptor,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws -> StreamUploadResult where S.Element == SliceData {
        let uploadSlices = ValidatedSliceDataUploadSequence(
            base: sliceStream,
            expectedPixelFormat: metadata.sourcePixelFormat,
            intensityRange: metadata.intensityRange
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let uploader = try ChunkedVolumeUploader(device: device, commandQueue: commandQueue)
        let metricsRecorder = VolumeUploadMetricsRecorder()
        let forwardingProgress = makeForwardingProgress(progress, metricsRecorder: metricsRecorder)

        let texture = try await uploader.upload(
            slices: uploadSlices,
            descriptor: metadata,
            progress: forwardingProgress
        )

        let uploadTime = CFAbsoluteTimeGetCurrent() - startedAt
        let result = UploadResult(
            texture: texture,
            uploadTime: uploadTime,
            peakMemoryBytes: metricsRecorder.metrics?.peakMemoryBytes
        )
        return StreamUploadResult(result: result)
    }

    private func makeForwardingProgress(
        _ progress: VolumeUploadProgressHandler?,
        metricsRecorder: VolumeUploadMetricsRecorder
    ) -> VolumeUploadProgressHandler {
        { event in
            if case .completed(let metrics) = event {
                metricsRecorder.record(metrics)
            }
            progress?(event)
        }
    }
}

final class VolumeUploadMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMetrics: VolumeUploadMetrics?

    var metrics: VolumeUploadMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMetrics
    }

    func record(_ metrics: VolumeUploadMetrics) {
        lock.lock()
        defer { lock.unlock() }
        recordedMetrics = metrics
    }
}

private struct ValidatedVolumeUploadSliceSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == VolumeUploadSlice {
    typealias Element = VolumeUploadSlice

    let base: Base
    let intensityRange: ClosedRange<Int32>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Base.AsyncIterator
        let intensityRange: ClosedRange<Int32>

        mutating func next() async throws -> VolumeUploadSlice? {
            guard let slice = try await iterator.next() else {
                return nil
            }

            guard slice.minClamp >= intensityRange.lowerBound,
                  slice.maxClamp <= intensityRange.upperBound
            else {
                throw StreamUploadError.mismatchedIntensityRange(expected: intensityRange,
                                                                actual: slice.minClamp...slice.maxClamp)
            }

            return slice
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: base.makeAsyncIterator(), intensityRange: intensityRange)
    }
}

private struct ValidatedSliceDataUploadSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == SliceData {
    typealias Element = VolumeUploadSlice

    let base: Base
    let expectedPixelFormat: VolumePixelFormat
    let intensityRange: ClosedRange<Int32>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Base.AsyncIterator
        let expectedPixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>

        mutating func next() async throws -> VolumeUploadSlice? {
            guard let slice = try await iterator.next() else {
                return nil
            }

            let actualPixelFormat: VolumePixelFormat = slice.isSigned ? .int16Signed : .int16Unsigned
            guard actualPixelFormat == expectedPixelFormat else {
                throw StreamUploadError.sliceSignednessMismatch(sliceIndex: slice.index,
                                                               expected: expectedPixelFormat,
                                                               actual: actualPixelFormat)
            }

            let uploadSlice = VolumeUploadSlice(index: slice.index,
                                                data: slice.rawBytes,
                                                slope: slice.slope,
                                                intercept: slice.intercept,
                                                minClamp: intensityRange.lowerBound,
                                                maxClamp: intensityRange.upperBound)
            return uploadSlice
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: base.makeAsyncIterator(),
                      expectedPixelFormat: expectedPixelFormat,
                      intensityRange: intensityRange)
    }
}

private enum StreamUploadError: LocalizedError {
    case mismatchedIntensityRange(expected: ClosedRange<Int32>, actual: ClosedRange<Int32>)
    case sliceSignednessMismatch(sliceIndex: Int, expected: VolumePixelFormat, actual: VolumePixelFormat)

    var errorDescription: String? {
        switch self {
        case .mismatchedIntensityRange(let expected, let actual):
            return "Slice intensity clamps \(actual) must be contained in descriptor intensity range \(expected)."
        case .sliceSignednessMismatch(let sliceIndex, let expected, let actual):
            return "Slice \(sliceIndex) pixel format \(actual) does not match expected \(expected)."
        }
    }
}
