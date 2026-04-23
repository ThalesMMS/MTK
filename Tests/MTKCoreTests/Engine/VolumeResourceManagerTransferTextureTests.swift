import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeResourceManagerTransferTextureTests: XCTestCase {
    @MainActor
    func test_transferTextureForFunction_reusesExistingCacheAndTracksMemory() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)
        let function = makeTransferFunction()

        let first = try XCTUnwrap(manager.transferTexture(for: function, device: device))
        let firstAccessTime = try XCTUnwrap(manager.debugTransferTextureLastAccessTime(for: first))
        let second = try XCTUnwrap(manager.transferTexture(for: function, device: device))
        let secondAccessTime = try XCTUnwrap(manager.debugTransferTextureLastAccessTime(for: second))
        let metrics = manager.gpuResourceMetrics()

        XCTAssertEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(manager.debugTransferTextureCount, 1)
        XCTAssertGreaterThanOrEqual(secondAccessTime, firstAccessTime)
        XCTAssertEqual(metrics.volumeTextureCount, 0)
        XCTAssertEqual(metrics.transferTextureCount, 1)
        XCTAssertEqual(metrics.outputTexturePoolSize, 0)
        XCTAssertEqual(metrics.breakdown.transferTextures, ResourceMemoryEstimator.estimate(for: first))
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: first))
    }

    @MainActor
    func test_transferTextureForPreset_reusesExistingCacheAndTracksMemory() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)

        let first = try XCTUnwrap(manager.transferTexture(for: .ctBone, device: device))
        let second = try XCTUnwrap(manager.transferTexture(for: .ctBone, device: device))
        let metrics = manager.gpuResourceMetrics()

        XCTAssertEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(manager.debugTransferTextureCount, 1)
        XCTAssertEqual(metrics.transferTextureCount, 1)
        XCTAssertEqual(metrics.resources.first?.resourceType, .transferFunction)
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: first))
    }

    @MainActor
    func test_emptyTransferFunctionDoesNotTrackTexture() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)
        let empty = VolumeTransferFunction(opacityPoints: [], colourPoints: [])

        XCTAssertNil(manager.transferTexture(for: empty, device: device))
        XCTAssertEqual(manager.debugTransferTextureCount, 0)
        XCTAssertEqual(manager.resourceMetrics().estimatedMemoryBytes, 0)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    private func makeManager(device: any MTLDevice,
                             featureFlags: FeatureFlags? = nil) throws -> VolumeResourceManager {
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        return VolumeResourceManager(device: device,
                                     commandQueue: commandQueue,
                                     featureFlags: featureFlags)
    }

    private func makeTransferFunction() -> VolumeTransferFunction {
        VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: -1000, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: 1000, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: -1000, colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: 1000, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }
}
