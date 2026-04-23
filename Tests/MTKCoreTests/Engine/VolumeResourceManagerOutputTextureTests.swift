import Metal
import XCTest

@testable import MTKCore

final class VolumeResourceManagerOutputTextureTests: XCTestCase {
    func test_acquireOutputTextureTracksPoolMemoryMetrics() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)

        let texture = try manager.acquireOutputTexture(width: 48, height: 32, pixelFormat: .bgra8Unorm)
        let metrics = manager.gpuResourceMetrics()

        XCTAssertEqual(manager.debugOutputTextureCount, 1)
        XCTAssertEqual(manager.debugOutputPoolTextureCount, 1)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 1)
        XCTAssertEqual(manager.debugOutputTextureIsInUse(texture), true)
        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(metrics.outputTexturePoolSize, 1)
        XCTAssertEqual(metrics.transferTextureCount, 0)
        XCTAssertEqual(metrics.volumeTextureCount, 0)
        XCTAssertEqual(metrics.breakdown.outputTextures, ResourceMemoryEstimator.estimate(for: texture))
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: texture))
    }

    func test_releaseOutputTextureKeepsTextureInPoolForReuse() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)

        let first = try manager.acquireOutputTexture(width: 48, height: 32, pixelFormat: .bgra8Unorm)
        manager.releaseOutputTexture(first)
        let second = try manager.acquireOutputTexture(width: 48, height: 32, pixelFormat: .bgra8Unorm)

        XCTAssertEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(manager.debugOutputTextureCount, 1)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 1)
        XCTAssertEqual(manager.debugOutputTextureIsInUse(second), true)
    }

    func test_resizeOutputTextureReusesAvailableMatchingTexture() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)

        let old = try manager.acquireOutputTexture(width: 32, height: 32, pixelFormat: .bgra8Unorm)
        let available = try manager.acquireOutputTexture(width: 64, height: 64, pixelFormat: .bgra8Unorm)
        manager.releaseOutputTexture(available)

        let resized = try manager.resizeOutputTexture(from: old, toWidth: 64, toHeight: 64)

        XCTAssertEqual(ObjectIdentifier(resized as AnyObject), ObjectIdentifier(available as AnyObject))
        XCTAssertEqual(manager.debugOutputTextureIsInUse(old), false)
        XCTAssertEqual(manager.debugOutputTextureIsInUse(resized), true)
        XCTAssertEqual(manager.debugOutputTextureCount, 2)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 1)
    }

    func test_resizeOutputTextureRejectsLeasedTexture() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)
        let lease = try manager.acquireOutputTextureWithLease(width: 32,
                                                              height: 32,
                                                              pixelFormat: .bgra8Unorm)

        XCTAssertThrowsError(
            try manager.resizeOutputTexture(from: lease.texture, toWidth: 64, toHeight: 64)
        ) { error in
            XCTAssertEqual(error as? VolumeResourceManager.OutputTextureError, .textureLeased)
        }

        XCTAssertEqual(manager.debugOutputTextureLeasePendingCount, 1)
        XCTAssertEqual(manager.debugOutputTextureIsInUse(lease.texture), true)

        manager.releaseOutputTextureLease(lease)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 0)
    }

    func test_acquireOutputTextureWithLeaseTracksLeaseLifecycle() throws {
        let device = try makeDevice()
        let manager = try makeManager(device: device)

        let lease = try manager.acquireOutputTextureWithLease(width: 48,
                                                              height: 32,
                                                              pixelFormat: .bgra8Unorm)

        XCTAssertEqual(manager.debugOutputTextureLeaseCount, 1)
        XCTAssertEqual(manager.debugOutputTextureLeaseAcquiredCount, 1)
        XCTAssertEqual(manager.debugOutputTextureLeasePresentedCount, 0)
        XCTAssertEqual(manager.debugOutputTextureLeaseReleasedCount, 0)
        XCTAssertEqual(manager.debugOutputTextureLeasePendingCount, 1)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 1)

        lease.markPresented()
        manager.releaseOutputTextureLease(lease)
        manager.releaseOutputTextureLease(lease)

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(manager.debugOutputTextureLeasePresentedCount, 1)
        XCTAssertEqual(manager.debugOutputTextureLeaseReleasedCount, 1)
        XCTAssertEqual(manager.debugOutputTextureLeasePendingCount, 0)
        XCTAssertEqual(manager.debugOutputPoolInUseCount, 0)
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
}
