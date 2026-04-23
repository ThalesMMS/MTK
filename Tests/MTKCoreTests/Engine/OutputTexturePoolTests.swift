import Metal
import XCTest

@testable import MTKCore

final class OutputTexturePoolTests: XCTestCase {
    func test_acquireReusesReleasedTextureWithMatchingKey() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        let first = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)
        pool.release(texture: first)
        pool.release(texture: first)
        let second = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)

        XCTAssertEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(second.storageMode, .private)
        XCTAssertEqual(pool.debugTextureCount, 1)
        XCTAssertEqual(pool.debugIsInUse(second), true)
    }

    func test_acquireCreatesNewTextureWhenMatchingEntryIsInUse() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        let first = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)
        let second = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)

        XCTAssertNotEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(pool.debugTextureCount, 2)
        XCTAssertEqual(pool.debugIsInUse(first), true)
        XCTAssertEqual(pool.debugIsInUse(second), true)
    }

    func test_acquireCreatesNewTextureWhenSizeDoesNotMatch() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        let first = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)
        pool.release(texture: first)
        let second = try pool.acquire(width: 64, height: 32, pixelFormat: .bgra8Unorm, device: device)

        XCTAssertNotEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        XCTAssertEqual(pool.debugTextureCount, 2)
        XCTAssertEqual(pool.debugIsInUse(first), false)
        XCTAssertEqual(pool.debugIsInUse(second), true)
    }

    func test_resizeReleasesOldTextureAndReusesAvailableMatchingEntry() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        let old = try pool.acquire(width: 32, height: 32, pixelFormat: .bgra8Unorm, device: device)
        let available = try pool.acquire(width: 64, height: 64, pixelFormat: .bgra8Unorm, device: device)
        pool.release(texture: available)

        let resized = try pool.resize(from: old, toWidth: 64, toHeight: 64, device: device)

        XCTAssertEqual(ObjectIdentifier(resized as AnyObject), ObjectIdentifier(available as AnyObject))
        XCTAssertEqual(pool.debugIsInUse(old), false)
        XCTAssertEqual(pool.debugIsInUse(resized), true)
        XCTAssertEqual(pool.debugTextureCount, 2)
    }

    func test_acquireRejectsInvalidDimensions() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        XCTAssertThrowsError(try pool.acquire(width: 0, height: 32, pixelFormat: .bgra8Unorm, device: device)) { error in
            XCTAssertEqual(error as? OutputTexturePool.PoolError, .invalidDimensions(width: 0, height: 32))
        }
    }

    func test_acquireWithLeaseReleasesTextureExactlyOnce() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()

        let lease = try pool.acquireWithLease(width: 32,
                                              height: 32,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        XCTAssertEqual(pool.debugLeaseCount, 1)
        XCTAssertEqual(pool.debugLeaseAcquiredCount, 1)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 0)
        XCTAssertEqual(pool.debugLeasePendingCount, 1)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), true)

        lease.release()
        lease.release()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), false)
    }

    func test_releaseTextureDoesNotOverrideActiveLease() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()
        let lease = try pool.acquireWithLease(width: 32,
                                              height: 32,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        pool.release(texture: lease.texture)

        XCTAssertFalse(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 0)
        XCTAssertEqual(pool.debugLeasePendingCount, 1)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), true)

        lease.release()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), false)
    }

    func test_releaseForeignLeaseIsIgnored() throws {
        let device = try makeDevice()
        let pool = OutputTexturePool()
        let foreignPool = OutputTexturePool()
        let foreignLease = try foreignPool.acquireWithLease(width: 32,
                                                            height: 32,
                                                            pixelFormat: .bgra8Unorm,
                                                            device: device)

        pool.release(foreignLease)

        XCTAssertFalse(foreignLease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 0)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(foreignPool.debugLeaseReleasedCount, 0)
        XCTAssertEqual(foreignPool.debugLeasePendingCount, 1)
        XCTAssertEqual(foreignPool.debugIsInUse(foreignLease.texture), true)

        foreignLease.release()
        XCTAssertEqual(foreignPool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(foreignPool.debugLeasePendingCount, 0)
        XCTAssertEqual(foreignPool.debugIsInUse(foreignLease.texture), false)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }
}
