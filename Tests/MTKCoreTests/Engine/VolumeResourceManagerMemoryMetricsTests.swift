import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeResourceManagerMemoryMetricsTests: XCTestCase {
    @MainActor
    func test_resourceMetricsAggregatesVolumeTransferAndOutputMemory() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )

        let handle = try await manager.acquire(dataset: dataset,
                                               device: device,
                                               commandQueue: commandQueue)
        let volumeTexture = try XCTUnwrap(manager.texture(for: handle))
        let transferTexture = try XCTUnwrap(manager.transferTexture(for: .ctBone, device: device))
        let outputTexture = try manager.acquireOutputTexture(width: 16,
                                                             height: 8,
                                                             pixelFormat: .bgra8Unorm)

        let volumeBytes = ResourceMemoryEstimator.estimate(for: volumeTexture)
        let transferBytes = ResourceMemoryEstimator.estimate(for: transferTexture)
        let outputBytes = ResourceMemoryEstimator.estimate(for: outputTexture)
        let expectedTotal = volumeBytes + transferBytes + outputBytes
        let breakdown = manager.memoryBreakdown()
        let metrics = manager.resourceMetrics()

        XCTAssertEqual(breakdown.volumeTextures, volumeBytes)
        XCTAssertEqual(breakdown.transferTextures, transferBytes)
        XCTAssertEqual(breakdown.outputTextures, outputBytes)
        XCTAssertEqual(breakdown.total, expectedTotal)
        XCTAssertEqual(manager.estimatedGPUMemoryBytes, expectedTotal)
        XCTAssertEqual(manager.debugMemoryBreakdown, breakdown)

        XCTAssertEqual(metrics.estimatedMemoryBytes, expectedTotal)
        XCTAssertEqual(metrics.volumeTextureCount, 1)
        XCTAssertEqual(metrics.transferTextureCount, 1)
        XCTAssertEqual(metrics.outputTexturePoolSize, 1)
        XCTAssertEqual(metrics.breakdown, breakdown)
        XCTAssertNil(metrics.uploadPeakMemoryBytes)
    }

    @MainActor
    func test_resourceMetricsSurfacesStreamUploadPeakMemory() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let descriptor = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Signed
        )

        let handle = try await manager.acquireFromStream(
            descriptor: descriptor,
            slices: AsyncStream { continuation in
                continuation.yield(
                    VolumeUploadSlice(
                        index: 0,
                        data: [Int16(1), 2, 3, 4].withUnsafeBytes { Data($0) }
                    )
                )
                continuation.finish()
            }
        )
        let uploadPeak = try XCTUnwrap(manager.peakUploadMemoryBytes(for: handle))
        let metrics = manager.resourceMetrics()

        XCTAssertEqual(metrics.uploadPeakMemoryBytes, uploadPeak)
        XCTAssertGreaterThan(uploadPeak, handle.metadata.estimatedBytes)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    private func makeCommandQueue(device: any MTLDevice) throws -> any MTLCommandQueue {
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        return commandQueue
    }
}
