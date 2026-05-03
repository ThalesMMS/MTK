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
        let contentFingerprint: UInt64
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
            .generateAsync(device: device, commandQueue: commandQueue)
        let uploadTime = CFAbsoluteTimeGetCurrent() - startedAt
        return UploadResult(texture: texture, uploadTime: uploadTime, peakMemoryBytes: nil)
    }

    func upload<S: AsyncSequence>(
        descriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws -> StreamUploadResult where S.Element == VolumeUploadSlice {
        let hasher = StreamContentFingerprintAccumulator()
        let hashingSlices = HashedVolumeUploadSliceSequence(
            base: slices,
            intensityRange: descriptor.intensityRange,
            hasher: hasher
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let uploader = try ChunkedVolumeUploader(device: device, commandQueue: commandQueue)
        let metricsRecorder = VolumeUploadMetricsRecorder()
        let forwardingProgress = makeForwardingProgress(progress, metricsRecorder: metricsRecorder)

        let texture = try await uploader.upload(
            slices: hashingSlices,
            descriptor: descriptor,
            progress: forwardingProgress
        )

        let uploadTime = CFAbsoluteTimeGetCurrent() - startedAt
        let result = UploadResult(
            texture: texture,
            uploadTime: uploadTime,
            peakMemoryBytes: metricsRecorder.metrics?.peakMemoryBytes
        )
        return StreamUploadResult(result: result, contentFingerprint: hasher.value)
    }

    func upload<S: AsyncSequence>(
        sliceStream: S,
        metadata: VolumeUploadDescriptor,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws -> StreamUploadResult where S.Element == SliceData {
        let hasher = StreamContentFingerprintAccumulator()
        let uploadSlices = HashedSliceDataUploadSequence(
            base: sliceStream,
            expectedPixelFormat: metadata.sourcePixelFormat,
            intensityRange: metadata.intensityRange,
            hasher: hasher
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
        return StreamUploadResult(result: result, contentFingerprint: hasher.value)
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

private final class StreamContentFingerprintAccumulator: @unchecked Sendable {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private let lock = NSLock()
    private var hash = fnvOffsetBasis

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return hash
    }

    func mix(slice: VolumeUploadSlice) {
        lock.lock()
        defer { lock.unlock() }

        mixIntegerUnlocked(slice.index)
        mixDoubleUnlocked(slice.slope)
        mixDoubleUnlocked(slice.intercept)
        mixIntegerUnlocked(Int(slice.minClamp))
        mixIntegerUnlocked(Int(slice.maxClamp))
        mixDataUnlocked(slice.data)
    }

    private func mixDataUnlocked(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= Self.fnvPrime
            }
        }
    }

    private func mixIntegerUnlocked(_ value: Int) {
        var encoded = UInt64(bitPattern: Int64(value)).littleEndian
        mixBytesUnlocked(&encoded)
    }

    private func mixDoubleUnlocked(_ value: Double) {
        var encoded = value.bitPattern.littleEndian
        mixBytesUnlocked(&encoded)
    }

    private func mixBytesUnlocked(_ value: inout UInt64) {
        withUnsafeBytes(of: &value) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= Self.fnvPrime
            }
        }
    }
}

private struct HashedVolumeUploadSliceSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == VolumeUploadSlice {
    typealias Element = VolumeUploadSlice

    let base: Base
    let intensityRange: ClosedRange<Int32>
    let hasher: StreamContentFingerprintAccumulator

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Base.AsyncIterator
        let intensityRange: ClosedRange<Int32>
        let hasher: StreamContentFingerprintAccumulator

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

            hasher.mix(slice: slice)
            return slice
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: base.makeAsyncIterator(),
                      intensityRange: intensityRange,
                      hasher: hasher)
    }
}

private struct HashedSliceDataUploadSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == SliceData {
    typealias Element = VolumeUploadSlice

    let base: Base
    let expectedPixelFormat: VolumePixelFormat
    let intensityRange: ClosedRange<Int32>
    let hasher: StreamContentFingerprintAccumulator

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Base.AsyncIterator
        let expectedPixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>
        let hasher: StreamContentFingerprintAccumulator

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
            hasher.mix(slice: uploadSlice)
            return uploadSlice
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: base.makeAsyncIterator(),
                      expectedPixelFormat: expectedPixelFormat,
                      intensityRange: intensityRange,
                      hasher: hasher)
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
