import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeUploadPerformanceTests: XCTestCase {
    func test_benchmarkLargeSyntheticVolumeCPUPathAndChunkedGPUPath() async throws {
        let device = try makeTestMetalDevice()
        let commandQueue = try makePerformanceCommandQueue(device: device)
        let dimensions = VolumeDimensions(width: 512, height: 512, depth: 200)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensions,
            pixelFormat: .int16Signed,
            seed: 17
        )
        let dataset = VolumeDataset(
            data: sharedData.data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.0005, y: 0.0005, z: 0.001),
            pixelFormat: .int16Signed
        )

        let cpuStartedAt = CFAbsoluteTimeGetCurrent()
        var cpuTexture: (any MTLTexture)? = VolumeTextureFactory(dataset: dataset).generate(device: device)
        let cpuUploadTime = CFAbsoluteTimeGetCurrent() - cpuStartedAt
        XCTAssertNotNil(cpuTexture)
        cpuTexture = nil

        let metricsRecorder = PerformanceUploadMetricsRecorder()
        let gpuStartedAt = CFAbsoluteTimeGetCurrent()
        let gpuTexture = try await ChunkedVolumeUploader(device: device, commandQueue: commandQueue).upload(
            slices: PerformanceDatasetSliceSequence(data: dataset.data,
                                                    dimensions: dimensions,
                                                    pixelFormat: dataset.pixelFormat),
            descriptor: VolumeUploadDescriptor(
                dimensions: dimensions,
                spacing: dataset.spacing,
                sourcePixelFormat: dataset.pixelFormat
            )
        ) { event in
            metricsRecorder.record(event)
        }
        let wallClockGPUUploadTime = CFAbsoluteTimeGetCurrent() - gpuStartedAt
        let metrics = try XCTUnwrap(metricsRecorder.metrics)
        let fullVolumeStagingPeak = ResourceMemoryEstimator.estimate(for: gpuTexture) + dataset.data.count

        // Expected shape: the CPU reference path stages the full volume on the CPU,
        // while chunked upload keeps upload memory near one private texture plus one slice.
        XCTAssertEqual(metrics.slicesProcessed, dimensions.depth)
        XCTAssertLessThan(metrics.peakMemoryBytes, fullVolumeStagingPeak)
        XCTAssertGreaterThan(cpuUploadTime, 0)
        XCTAssertGreaterThan(wallClockGPUUploadTime, 0)

        let perSliceWallClock = wallClockGPUUploadTime / Double(dimensions.depth)
        print(
            """
            Volume upload benchmark 512x512x200:
              cpuUploadSeconds=\(cpuUploadTime)
              gpuWallClockSeconds=\(wallClockGPUUploadTime)
              gpuReportedSeconds=\(metrics.uploadTimeSeconds)
              gpuPerSliceWallClockSeconds=\(perSliceWallClock)
              gpuPeakMemoryBytes=\(metrics.peakMemoryBytes)
              fullVolumeStagingPeakBytes=\(fullVolumeStagingPeak)
            """
        )

        _ = sharedData.storage
    }
}

private final class PerformanceUploadMetricsRecorder: @unchecked Sendable {
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

private struct PerformanceDatasetSliceSequence: AsyncSequence {
    typealias Element = VolumeUploadSlice

    let data: Data
    let dimensions: VolumeDimensions
    let pixelFormat: VolumePixelFormat

    func makeAsyncIterator() -> Iterator {
        Iterator(data: data,
                 sliceByteCount: dimensions.width * dimensions.height * pixelFormat.bytesPerVoxel,
                 totalSlices: dimensions.depth,
                 nextSliceIndex: 0)
    }

    struct Iterator: AsyncIteratorProtocol {
        let data: Data
        let sliceByteCount: Int
        let totalSlices: Int
        var nextSliceIndex: Int

        mutating func next() async throws -> VolumeUploadSlice? {
            guard nextSliceIndex < totalSlices else {
                return nil
            }
            let offset = nextSliceIndex * sliceByteCount
            let slice = VolumeUploadSlice(
                index: nextSliceIndex,
                data: data.subdata(in: offset..<(offset + sliceByteCount))
            )
            nextSliceIndex += 1
            return slice
        }
    }
}

private func makePerformanceCommandQueue(device: any MTLDevice) throws -> any MTLCommandQueue {
    guard let commandQueue = device.makeCommandQueue() else {
        throw XCTSkip("Metal command queue unavailable on this test runner")
    }
    return commandQueue
}
