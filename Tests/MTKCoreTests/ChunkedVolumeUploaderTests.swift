import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class ChunkedVolumeUploaderTests: XCTestCase {
    private var device: (any MTLDevice)!
    private var commandQueue: (any MTLCommandQueue)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        self.device = device
        self.commandQueue = commandQueue
    }

    func test_uploadSignedSlicesConvertsHUAndClampsIntoPrivateTexture() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let slices = SliceSequence([
            makeSignedSlice(index: 0,
                            values: [-1024, 0, 1000, 4000],
                            minClamp: -1024,
                            maxClamp: 3071),
            makeSignedSlice(index: 1,
                            values: [1, 2, 3, 4],
                            slope: 2,
                            intercept: -10,
                            minClamp: -1024,
                            maxClamp: 3071)
        ])
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed,
            intensityRange: -1024...3071
        )
        let progressRecorder = ProgressRecorder()
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        let texture = try await uploader.upload(slices: slices,
                                                descriptor: descriptor) { event in
            progressRecorder.append(event)
        }
        let values = try await readBackSignedValues(from: texture)
        let progressEvents = progressRecorder.events

        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(texture.pixelFormat, .r16Sint)
        XCTAssertEqual(values, [-1024, 0, 1000, 3071, -8, -6, -4, -2])
        XCTAssertEqual(progressEvents.first, .started(totalSlices: 2))
        XCTAssertEqual(progressEvents.dropLast().last, .uploadingSlice(current: 2, total: 2))
        guard case .completed(let metrics)? = progressEvents.last else {
            XCTFail("Expected completed progress event")
            return
        }
        XCTAssertEqual(metrics.slicesProcessed, 2)
        XCTAssertGreaterThan(metrics.peakMemoryBytes, ResourceMemoryEstimator.estimate(for: texture))
    }

    func test_uploadUnsignedSlicesConvertsToSignedHUTexture() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 1)
        let slices = SliceSequence([
            makeUnsignedSlice(index: 0,
                              values: [0, 1024, 2048, 4095],
                              intercept: -1024,
                              minClamp: -1024,
                              maxClamp: 3071)
        ])
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Unsigned,
            intensityRange: -1024...3071
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        let texture = try await uploader.upload(slices: slices,
                                                descriptor: descriptor)
        let values = try await readBackSignedValues(from: texture)

        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(texture.pixelFormat, .r16Sint)
        XCTAssertEqual(values, [-1024, 0, 1024, 3071])
    }

    func test_resourceManagerAcquireFromStreamStoresPrivateTextureMetadata() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 1)
        let slices = SliceSequence([
            makeSignedSlice(index: 0, values: [1, 2, 3, 4])
        ])
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed,
            cacheKey: "chunked-resource-manager-test"
        )
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)

        let handle = try await manager.acquireFromStream(descriptor: descriptor,
                                                         slices: slices)
        let texture = try XCTUnwrap(manager.texture(for: handle))

        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(handle.metadata.storageMode, .private)
        XCTAssertEqual(handle.metadata.pixelFormat, .r16Sint)
        XCTAssertEqual(handle.metadata.estimatedBytes, ResourceMemoryEstimator.estimate(for: texture))
    }

#if DEBUG
    func test_resourceManagerAcquireFromStreamUpdatesDebugUploadCounters() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 1)
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)
        let slices = [
            makeSignedSlice(index: 0, values: [1, 2, 3, 4])
        ]

        _ = try await manager.acquireFromStream(descriptor: descriptor,
                                                slices: SliceSequence(slices))
        _ = try await manager.acquireFromStream(descriptor: descriptor,
                                                slices: SliceSequence(slices))

        XCTAssertEqual(manager.debugCounters.volumeTextureCreates, 2)
        XCTAssertEqual(manager.debugCounters.volumeCacheHits, 1)
        XCTAssertEqual(manager.debugTextureCount, 1)
    }
#endif

    func test_uploadCancellationStopsPendingSliceIngest() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let slices = DelayedSliceSequence(
            slices: [
                makeSignedSlice(index: 0, values: [1, 2, 3, 4]),
                makeSignedSlice(index: 1, values: [5, 6, 7, 8])
            ],
            delayNanoseconds: 1_000_000_000
        )
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        let task = Task {
            try await uploader.upload(slices: slices,
                                      descriptor: descriptor)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func test_uploadRejectsDuplicateSliceIndex() async throws {
        let dimensions = VolumeDimensions(width: 1, height: 1, depth: 2)
        let slices = SliceSequence([
            makeSignedSlice(index: 0, values: [1]),
            makeSignedSlice(index: 0, values: [2])
        ])
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        do {
            _ = try await uploader.upload(slices: slices,
                                          descriptor: descriptor)
            XCTFail("Expected duplicate slice index error")
        } catch ChunkedVolumeUploadError.duplicateSliceIndex(0) {
            // Expected.
        }
    }

    func test_uploadRejectsMissingSliceIndices() async throws {
        let dimensions = VolumeDimensions(width: 1, height: 1, depth: 2)
        let slices = SliceSequence([
            makeSignedSlice(index: 1, values: [2])
        ])
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        do {
            _ = try await uploader.upload(slices: slices,
                                          descriptor: descriptor)
            XCTFail("Expected missing slice indices")
        } catch ChunkedVolumeUploadError.missingSliceIndices(let indices) {
            XCTAssertEqual(indices, [0])
        }
    }

    func test_uploadRejectsDimensionOverflowBeforeAllocation() async throws {
        let dimensions = VolumeDimensions(width: Int(UInt32.max),
                                          height: Int(UInt32.max),
                                          depth: 1)
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)

        do {
            _ = try await uploader.upload(slices: SliceSequence([]),
                                          descriptor: descriptor)
            XCTFail("Expected byte count overflow")
        } catch ChunkedVolumeUploadError.dimensionByteCountOverflow(let errorDimensions) {
            XCTAssertEqual(errorDimensions, dimensions)
        }
    }

    private func makeSignedSlice(index: Int,
                                 values: [Int16],
                                 slope: Double = 1,
                                 intercept: Double = 0,
                                 minClamp: Int32 = Int32(Int16.min),
                                 maxClamp: Int32 = Int32(Int16.max)) -> VolumeUploadSlice {
        VolumeUploadSlice(index: index,
                          data: values.withUnsafeBytes { Data($0) },
                          slope: slope,
                          intercept: intercept,
                          minClamp: minClamp,
                          maxClamp: maxClamp)
    }

    private func makeUnsignedSlice(index: Int,
                                   values: [UInt16],
                                   slope: Double = 1,
                                   intercept: Double = 0,
                                   minClamp: Int32 = Int32(Int16.min),
                                   maxClamp: Int32 = Int32(Int16.max)) -> VolumeUploadSlice {
        VolumeUploadSlice(index: index,
                          data: values.withUnsafeBytes { Data($0) },
                          slope: slope,
                          intercept: intercept,
                          minClamp: minClamp,
                          maxClamp: maxClamp)
    }

    private func readBackSignedValues(from texture: any MTLTexture) async throws -> [Int16] {
        let bytesPerRow = texture.width * MemoryLayout<Int16>.stride
        let bytesPerImage = bytesPerRow * texture.height
        let byteCount = bytesPerImage * texture.depth
        guard let readbackBuffer = device.makeBuffer(length: byteCount,
                                                     options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            XCTFail("Failed to allocate readback resources")
            return []
        }

        blitEncoder.copy(from: texture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: texture.width,
                                             height: texture.height,
                                             depth: texture.depth),
                         to: readbackBuffer,
                         destinationOffset: 0,
                         destinationBytesPerRow: bytesPerRow,
                         destinationBytesPerImage: bytesPerImage)
        blitEncoder.endEncoding()
        try await waitForCompletion(commandBuffer)

        let pointer = readbackBuffer.contents().assumingMemoryBound(to: Int16.self)
        return Array(UnsafeBufferPointer(start: pointer,
                                         count: texture.width * texture.height * texture.depth))
    }

    private func waitForCompletion(_ commandBuffer: any MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            commandBuffer.commit()
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [VolumeUploadProgress] = []

    var events: [VolumeUploadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func append(_ event: VolumeUploadProgress) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private struct SliceSequence: AsyncSequence {
    typealias Element = VolumeUploadSlice

    private let slices: [VolumeUploadSlice]

    init(_ slices: [VolumeUploadSlice]) {
        self.slices = slices
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(slices: slices)
    }

    struct Iterator: AsyncIteratorProtocol {
        private let slices: [VolumeUploadSlice]
        private var index = 0

        init(slices: [VolumeUploadSlice]) {
            self.slices = slices
        }

        mutating func next() async -> VolumeUploadSlice? {
            guard index < slices.count else {
                return nil
            }
            let slice = slices[index]
            index += 1
            return slice
        }
    }
}

private struct DelayedSliceSequence: AsyncSequence {
    typealias Element = VolumeUploadSlice

    private let slices: [VolumeUploadSlice]
    private let delayNanoseconds: UInt64

    init(slices: [VolumeUploadSlice],
         delayNanoseconds: UInt64) {
        self.slices = slices
        self.delayNanoseconds = delayNanoseconds
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(slices: slices,
                 delayNanoseconds: delayNanoseconds)
    }

    struct Iterator: AsyncIteratorProtocol {
        private let slices: [VolumeUploadSlice]
        private let delayNanoseconds: UInt64
        private var index = 0

        init(slices: [VolumeUploadSlice],
             delayNanoseconds: UInt64) {
            self.slices = slices
            self.delayNanoseconds = delayNanoseconds
        }

        mutating func next() async throws -> VolumeUploadSlice? {
            guard index < slices.count else {
                return nil
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delayNanoseconds)
            try Task.checkCancellation()
            let slice = slices[index]
            index += 1
            return slice
        }
    }
}
