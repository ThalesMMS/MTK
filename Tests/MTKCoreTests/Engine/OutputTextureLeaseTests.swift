import Dispatch
import Metal
import XCTest

@testable import MTKCore

final class OutputTextureLeaseTests: XCTestCase {
    func test_releaseMarksTextureAsNotInUse() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        XCTAssertEqual(pool.debugLeasePendingCount, 1)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), true)

        lease.release()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), false)
    }

    func test_releaseIsIdempotent() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        lease.release()
        lease.release()

        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
    }

    func test_releaseUnknownTextureIDDoesNotCrash() {
        let pool = TextureLeasePool()

        pool.debugReleaseUnknownLeaseTextureID()

        XCTAssertEqual(pool.debugLeaseReleasedCount, 0)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
    }

    func test_releaseAfterPresentationCompletesReleasesNeverSubmittedLease() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        lease.releaseAfterPresentationCompletes()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), false)
    }

    func test_cancelledPresentationCompletesDeferredRelease() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        lease.markPresentationSubmitted()
        lease.releaseAfterPresentationCompletes()

        XCTAssertFalse(lease.isReleased)

        lease.cancelPresentationSubmission()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    func test_deferredReleaseWaitsForAllSubmittedPresentations() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)

        lease.markPresentationSubmitted()
        lease.markPresentationSubmitted()
        lease.releaseAfterPresentationCompletes()
        lease.markPresented()

        XCTAssertFalse(lease.isReleased)

        lease.markPresented()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeasePresentedCount, 1)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    func test_concurrentReleaseDoesNotCorruptState() throws {
        let device = try makeDevice()
        let pool = TextureLeasePool()
        let lease = try pool.acquireWithLease(width: 24,
                                              height: 24,
                                              pixelFormat: .bgra8Unorm,
                                              device: device)
        let group = DispatchGroup()

        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                lease.release()
                group.leave()
            }
        }

        group.wait()

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
        XCTAssertEqual(pool.debugLeasePendingCount, 0)
        XCTAssertEqual(pool.debugIsInUse(lease.texture), false)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }
}
