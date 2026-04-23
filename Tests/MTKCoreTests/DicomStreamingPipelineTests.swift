import Foundation
import Metal
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

final class DicomStreamingPipelineTests: XCTestCase {
    func test_loadVolumeStreamingEmitsRawSlicesAndMetadataWithoutCPUHUConversion() throws {
        let loader = DicomVolumeLoader(seriesLoader: StreamingMockSeriesLoader())
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let slices = SliceRecorder()
        let expectation = expectation(description: "Streaming DICOM load")
        var result: Result<DicomStreamingImportResult, Error>?
        var progressEvents: [DicomVolumeProgress] = []

        loader.loadVolumeStreaming(from: directory,
                                   sliceHandler: slices.handler,
                                   progress: { progressEvents.append($0) },
                                   completion: { outcome in
                                       result = outcome
                                       expectation.fulfill()
                                   })

        wait(for: [expectation], timeout: 5)

        let success = try XCTUnwrap(result?.get())
        XCTAssertEqual(success.metadata.dimensions, VolumeDimensions(width: 2, height: 2, depth: 2))
        XCTAssertEqual(success.metadata.sourcePixelFormat, .int16Signed)
        XCTAssertEqual(success.metadata.spacing.x, 0.001, accuracy: 0.000_000_01)
        XCTAssertEqual(success.metadata.spacing.y, 0.002, accuracy: 0.000_000_01)
        XCTAssertEqual(success.metadata.spacing.z, 0.003, accuracy: 0.000_000_01)
        XCTAssertEqual(success.seriesDescription, "Streaming Test Series")

        let captured = slices.values
        XCTAssertEqual(captured.map(\.index), [0, 1])
        XCTAssertEqual(captured.map(\.slope), [2, 2])
        XCTAssertEqual(captured.map(\.intercept), [-10, -10])
        XCTAssertEqual(captured.map(\.isSigned), [true, true])
        XCTAssertEqual(readInt16Values(from: captured[0].rawData), [1, 2, 3, 4])
        XCTAssertEqual(readInt16Values(from: captured[1].rawData), [5, 6, 7, 8])

        XCTAssertTrue(progressEvents.contains { event in
            if case .started(totalSlices: 2) = event { return true }
            return false
        })
        XCTAssertTrue(progressEvents.contains { event in
            if case .reading(let fraction) = event { return fraction == 1.0 }
            return false
        })
    }

    func test_dicomSliceStreamFeedsVolumeResourceManagerUpload() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let loader = DicomVolumeLoader(seriesLoader: StreamingMockSeriesLoader())
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stream = DicomSliceStream()
        let expectation = expectation(description: "Streaming DICOM load")
        var result: Result<DicomStreamingImportResult, Error>?

        loader.loadVolumeStreaming(from: directory,
                                   sliceHandler: stream.sliceHandler,
                                   progress: { _ in },
                                   completion: { outcome in
                                       result = outcome
                                       switch outcome {
                                       case .success:
                                           stream.finish()
                                       case .failure(let error):
                                           stream.finish(throwing: error)
                                       }
                                       expectation.fulfill()
                                   })

        await fulfillment(of: [expectation], timeout: 5)
        let streamingResult = try XCTUnwrap(result?.get())

        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)
        let handle = try await manager.acquireFromStream(sliceStream: stream,
                                                         metadata: streamingResult.metadata,
                                                         device: device,
                                                         commandQueue: commandQueue)
        let texture = try XCTUnwrap(manager.texture(for: handle))
        let values = try await readBackSignedValues(from: texture,
                                                    device: device,
                                                    commandQueue: commandQueue)

        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(values, [-8, -6, -4, -2, 0, 2, 4, 6])
        XCTAssertNotNil(manager.peakUploadMemoryBytes(for: handle))
        XCTAssertEqual(manager.debugTextureCount, 1)
    }

    func test_streamCacheFingerprintIncludesConversionParameters() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let metadata = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)
        _ = try await manager.acquireFromStream(
            sliceStream: AsyncStream { continuation in
                continuation.yield(makeSlice(index: 0, values: [1, 2, 3, 4], intercept: 0))
                continuation.finish()
            },
            metadata: metadata,
            device: device,
            commandQueue: commandQueue
        )
        let shiftedHandle = try await manager.acquireFromStream(
            sliceStream: AsyncStream { continuation in
                continuation.yield(makeSlice(index: 0, values: [1, 2, 3, 4], intercept: 100))
                continuation.finish()
            },
            metadata: metadata,
            device: device,
            commandQueue: commandQueue
        )
        let shiftedTexture = try XCTUnwrap(manager.texture(for: shiftedHandle))
        let shiftedValues = try await readBackSignedValues(from: shiftedTexture,
                                                           device: device,
                                                           commandQueue: commandQueue)

        XCTAssertEqual(shiftedValues, [101, 102, 103, 104])
        XCTAssertEqual(manager.debugTextureCount, 2)
    }

    func test_sliceDataStreamUsesDescriptorIntensityRangeForClamp() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let metadata = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed,
            intensityRange: 0...3
        )
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)
        let handle = try await manager.acquireFromStream(
            sliceStream: AsyncStream { continuation in
                continuation.yield(makeSlice(index: 0, values: [-10, 2, 10, 4]))
                continuation.finish()
            },
            metadata: metadata,
            device: device,
            commandQueue: commandQueue
        )
        let texture = try XCTUnwrap(manager.texture(for: handle))
        let values = try await readBackSignedValues(from: texture,
                                                    device: device,
                                                    commandQueue: commandQueue)

        XCTAssertEqual(values, [0, 2, 3, 3])
    }

    func test_acquireFromCancelledSliceStreamDoesNotCachePartialTexture() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let metadata = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue)
        let task = Task {
            try await manager.acquireFromStream(
                sliceStream: DelayedSliceDataSequence(slices: [
                    makeSlice(index: 0, values: [1, 2, 3, 4]),
                    makeSlice(index: 1, values: [5, 6, 7, 8])
                ]),
                metadata: metadata,
                device: device,
                commandQueue: commandQueue
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(manager.debugTextureCount, 0)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomStreamingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class StreamingMockSeriesLoader: DicomSeriesLoading {
    func loadSeries(at url: URL,
                    progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        let volume = TestStreamingVolume()
        progress?(0.5, 1, [Int16(1), 2, 3, 4].withUnsafeBytes { Data($0) }, volume)
        progress?(1.0, 2, [Int16(5), 6, 7, 8].withUnsafeBytes { Data($0) }, volume)
        return volume
    }
}

private struct TestStreamingVolume: DICOMSeriesVolumeProtocol {
    let bitsAllocated = 16
    let width = 2
    let height = 2
    let depth = 2
    let spacingX = 1.0
    let spacingY = 2.0
    let spacingZ = 3.0
    let orientation = matrix_identity_float3x3
    let origin = SIMD3<Float>(repeating: 0)
    let rescaleSlope = 2.0
    let rescaleIntercept = -10.0
    let isSignedPixel = true
    let seriesDescription = "Streaming Test Series"
}

private struct RecordedSlice: Sendable {
    let index: Int
    let rawData: Data
    let slope: Double
    let intercept: Double
    let isSigned: Bool
}

private final class SliceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedSlice] = []

    var values: [RecordedSlice] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var handler: DicomStreamingSliceHandler {
        { [weak self] index, rawData, slope, intercept, isSigned in
            self?.append(RecordedSlice(index: index,
                                       rawData: rawData,
                                       slope: slope,
                                       intercept: intercept,
                                       isSigned: isSigned))
        }
    }

    private func append(_ slice: RecordedSlice) {
        lock.lock()
        recorded.append(slice)
        lock.unlock()
    }
}

private struct DelayedSliceDataSequence: AsyncSequence {
    typealias Element = SliceData

    let slices: [SliceData]

    func makeAsyncIterator() -> Iterator {
        Iterator(slices: slices)
    }

    struct Iterator: AsyncIteratorProtocol {
        let slices: [SliceData]
        var index = 0

        mutating func next() async throws -> SliceData? {
            guard index < slices.count else {
                return nil
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try Task.checkCancellation()
            let slice = slices[index]
            index += 1
            return slice
        }
    }
}

private func makeSlice(index: Int,
                       values: [Int16],
                       intercept: Double = 0) -> SliceData {
    SliceData(index: index,
              rawBytes: values.withUnsafeBytes { Data($0) },
              slope: 1,
              intercept: intercept,
              isSigned: true)
}

private func readInt16Values(from data: Data) -> [Int16] {
    data.withUnsafeBytes { rawBuffer in
        let values = rawBuffer.bindMemory(to: Int16.self)
        return Array(values)
    }
}

private func readBackSignedValues(from texture: any MTLTexture,
                                  device: any MTLDevice,
                                  commandQueue: any MTLCommandQueue) async throws -> [Int16] {
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
