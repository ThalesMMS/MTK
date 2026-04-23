import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeUploadVerificationTests: XCTestCase {
    func test_chunkedUploadMatchesCPUReferenceTextureVoxelByVoxel() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let dimensions = VolumeDimensions(width: 4, height: 3, depth: 2)
        var values = (0..<dimensions.voxelCount).map { Int16(($0 * 257) % 4096 - 2048) }
        values[0] = Int16.min
        values[values.count - 1] = Int16.max
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            pixelFormat: .int16Signed
        )

        let cpuTexture = try XCTUnwrap(VolumeTextureFactory(dataset: dataset).generate(device: device))
        let gpuTexture = try await upload(dataset: dataset,
                                          device: device,
                                          commandQueue: commandQueue)
        let cpuValues = try await readBackInt16Values(from: cpuTexture,
                                                      device: device,
                                                      commandQueue: commandQueue)
        let gpuValues = try await readBackInt16Values(from: gpuTexture,
                                                      device: device,
                                                      commandQueue: commandQueue)

        XCTAssertEqual(gpuTexture.storageMode, .private)
        XCTAssertEqual(cpuValues.count, gpuValues.count)
        assertVoxelsEqual(cpuValues, gpuValues, tolerance: 0)
    }

    func test_chunkedUploadHandlesHUConversionClampAndSignednessBoundaries() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let dimensions = VolumeDimensions(width: 4, height: 2, depth: 1)
        let signedValues: [Int16] = [Int16.min, -2048, -1024, -1, 0, 1024, 2048, Int16.max]
        let signedTexture = try await upload(values: signedValues,
                                             dimensions: dimensions,
                                             pixelFormat: .int16Signed,
                                             slope: 1.5,
                                             intercept: -100,
                                             minClamp: -1024,
                                             maxClamp: 3071,
                                             device: device,
                                             commandQueue: commandQueue)
        let signedResult = try await readBackInt16Values(from: signedTexture,
                                                         device: device,
                                                         commandQueue: commandQueue)
        let signedExpected = signedValues.map {
            convert(raw: Double($0),
                    slope: 1.5,
                    intercept: -100,
                    minClamp: -1024,
                    maxClamp: 3071)
        }

        let unsignedValues: [UInt16] = [0, 1, 1024, 2048, 4095, 32768, 60000, UInt16.max]
        let unsignedTexture = try await upload(values: unsignedValues,
                                               dimensions: dimensions,
                                               pixelFormat: .int16Unsigned,
                                               slope: 0.5,
                                               intercept: -2048,
                                               minClamp: -1500,
                                               maxClamp: 1500,
                                               device: device,
                                               commandQueue: commandQueue)
        let unsignedResult = try await readBackInt16Values(from: unsignedTexture,
                                                           device: device,
                                                           commandQueue: commandQueue)
        let unsignedExpected = unsignedValues.map {
            convert(raw: Double($0),
                    slope: 0.5,
                    intercept: -2048,
                    minClamp: -1500,
                    maxClamp: 1500)
        }

        assertVoxelsEqual(signedExpected, signedResult, tolerance: 1)
        assertVoxelsEqual(unsignedExpected, unsignedResult, tolerance: 1)
    }

    func test_chunkedUploadPeakMemoryIsLowerThanFullVolumeStaging() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 16)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: dimensions,
            pixelFormat: .int16Signed
        )
        let recorder = UploadMetricsRecorder()

        let texture = try await upload(dataset: dataset,
                                       device: device,
                                       commandQueue: commandQueue) { event in
            recorder.record(event)
        }
        let metrics = try XCTUnwrap(recorder.metrics)
        let fullVolumeStagingPeak = ResourceMemoryEstimator.estimate(for: texture) + dataset.data.count

        XCTAssertEqual(metrics.slicesProcessed, dimensions.depth)
        XCTAssertLessThan(metrics.peakMemoryBytes, Int(Double(fullVolumeStagingPeak) * 0.75))
    }

    func test_shaderLibraryResolvesHUConversionKernels() throws {
        let device = try makeDevice()
        let library = try ShaderLibraryLoader.loadLibrary(for: device)

        XCTAssertNotNil(library.makeFunction(name: "convertHUSlice"))
        XCTAssertNotNil(library.makeFunction(name: "convertHUSliceUnsigned"))
    }

    private func upload(dataset: VolumeDataset,
                        device: any MTLDevice,
                        commandQueue: any MTLCommandQueue,
                        progress: VolumeUploadProgressHandler? = nil) async throws -> any MTLTexture {
        try await upload(data: dataset.data,
                         dimensions: dataset.dimensions,
                         pixelFormat: dataset.pixelFormat,
                         slope: 1,
                         intercept: 0,
                         minClamp: Int32(Int16.min),
                         maxClamp: Int32(Int16.max),
                         device: device,
                         commandQueue: commandQueue,
                         progress: progress)
    }

    private func upload<T: FixedWidthInteger>(values: [T],
                                              dimensions: VolumeDimensions,
                                              pixelFormat: VolumePixelFormat,
                                              slope: Double,
                                              intercept: Double,
                                              minClamp: Int32,
                                              maxClamp: Int32,
                                              device: any MTLDevice,
                                              commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        try await upload(data: values.withUnsafeBytes { Data($0) },
                         dimensions: dimensions,
                         pixelFormat: pixelFormat,
                         slope: slope,
                         intercept: intercept,
                         minClamp: minClamp,
                         maxClamp: maxClamp,
                         device: device,
                         commandQueue: commandQueue)
    }

    private func upload(data: Data,
                        dimensions: VolumeDimensions,
                        pixelFormat: VolumePixelFormat,
                        slope: Double,
                        intercept: Double,
                        minClamp: Int32,
                        maxClamp: Int32,
                        device: any MTLDevice,
                        commandQueue: any MTLCommandQueue,
                        progress: VolumeUploadProgressHandler? = nil) async throws -> any MTLTexture {
        let descriptor = VolumeUploadDescriptor(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: pixelFormat
        )
        let uploader = try ChunkedVolumeUploader(device: device,
                                                 commandQueue: commandQueue)
        return try await uploader.upload(
            slices: DatasetSliceSequence(data: data,
                                         dimensions: dimensions,
                                         pixelFormat: pixelFormat,
                                         slope: slope,
                                         intercept: intercept,
                                         minClamp: minClamp,
                                         maxClamp: maxClamp),
            descriptor: descriptor,
            progress: progress
        )
    }
}

private final class UploadMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMetrics: VolumeUploadMetrics?

    var metrics: VolumeUploadMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMetrics
    }

    func record(_ event: VolumeUploadProgress) {
        guard case .completed(let metrics) = event else {
            return
        }
        lock.lock()
        recordedMetrics = metrics
        lock.unlock()
    }
}

private struct DatasetSliceSequence: AsyncSequence {
    typealias Element = VolumeUploadSlice

    let data: Data
    let dimensions: VolumeDimensions
    let pixelFormat: VolumePixelFormat
    let slope: Double
    let intercept: Double
    let minClamp: Int32
    let maxClamp: Int32

    func makeAsyncIterator() -> Iterator {
        Iterator(data: data,
                 sliceByteCount: dimensions.width * dimensions.height * pixelFormat.bytesPerVoxel,
                 totalSlices: dimensions.depth,
                 nextSliceIndex: 0,
                 slope: slope,
                 intercept: intercept,
                 minClamp: minClamp,
                 maxClamp: maxClamp)
    }

    struct Iterator: AsyncIteratorProtocol {
        let data: Data
        let sliceByteCount: Int
        let totalSlices: Int
        var nextSliceIndex: Int
        let slope: Double
        let intercept: Double
        let minClamp: Int32
        let maxClamp: Int32

        mutating func next() async throws -> VolumeUploadSlice? {
            guard nextSliceIndex < totalSlices else {
                return nil
            }
            let offset = nextSliceIndex * sliceByteCount
            let slice = VolumeUploadSlice(index: nextSliceIndex,
                                          data: data.subdata(in: offset..<(offset + sliceByteCount)),
                                          slope: slope,
                                          intercept: intercept,
                                          minClamp: minClamp,
                                          maxClamp: maxClamp)
            nextSliceIndex += 1
            return slice
        }
    }
}

private func readBackInt16Values(from texture: any MTLTexture,
                                 device: any MTLDevice,
                                 commandQueue: any MTLCommandQueue) async throws -> [Int16] {
    let bytesPerRow = texture.width * MemoryLayout<Int16>.stride
    let bytesPerImage = bytesPerRow * texture.height
    let byteCount = bytesPerImage * texture.depth
    guard let readbackBuffer = device.makeBuffer(length: byteCount,
                                                 options: .storageModeShared),
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        XCTFail("Failed to allocate readback blit resources")
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
    return Array(UnsafeBufferPointer(start: pointer, count: byteCount / MemoryLayout<Int16>.stride))
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

private func convert(raw: Double,
                     slope: Double,
                     intercept: Double,
                     minClamp: Int32,
                     maxClamp: Int32) -> Int16 {
    let rounded = Int32((raw * slope + intercept).rounded())
    let clamped = min(max(rounded, minClamp), maxClamp)
    return Int16(min(max(clamped, Int32(Int16.min)), Int32(Int16.max)))
}

private func assertVoxelsEqual(_ expected: [Int16],
                               _ actual: [Int16],
                               tolerance: Int16,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
    XCTAssertEqual(expected.count, actual.count, file: file, line: line)
    for index in 0..<min(expected.count, actual.count) {
        let delta = abs(Int(expected[index]) - Int(actual[index]))
        XCTAssertLessThanOrEqual(delta, Int(tolerance), "Voxel mismatch at \(index)", file: file, line: line)
    }
}

private func makeDevice() throws -> any MTLDevice {
    try makeTestMetalDevice()
}

private func makeCommandQueue(device: any MTLDevice) throws -> any MTLCommandQueue {
    guard let commandQueue = device.makeCommandQueue() else {
        throw XCTSkip("Metal command queue unavailable on this test runner")
    }
    return commandQueue
}
