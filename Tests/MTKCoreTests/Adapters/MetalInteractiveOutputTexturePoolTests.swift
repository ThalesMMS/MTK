import Metal
import XCTest

@testable import MTKCore

final class MetalInteractiveOutputTexturePoolTests: XCTestCase {
    func testPrewarmCreatesAvailableSlotsForRequestedSize() async throws {
        let device = try makeDevice()
        let pool = MetalInteractiveOutputTexturePool(capacity: 3)

        let ready = try await pool.prewarm(width: 32,
                                           height: 24,
                                           device: device,
                                           count: 3)

        XCTAssertTrue(ready)
        let prewarmedSlotCount = await pool.debugSlotCount
        let prewarmedAvailableCount = await pool.debugAvailableSlotCount
        XCTAssertEqual(prewarmedSlotCount, 3)
        XCTAssertEqual(prewarmedAvailableCount, 3)

        let lease = try await pool.acquire(width: 32,
                                           height: 24,
                                           device: device,
                                           frameIndex: nil)
        XCTAssertEqual(lease.texture.width, 32)
        XCTAssertEqual(lease.texture.height, 24)
        let acquiredSlotCount = await pool.debugSlotCount
        let acquiredAvailableCount = await pool.debugAvailableSlotCount
        XCTAssertEqual(acquiredSlotCount, 3)
        XCTAssertEqual(acquiredAvailableCount, 2)

        lease.release()
    }

    func testPrewarmDoesNotResetPoolWhileSlotIsInUse() async throws {
        let device = try makeDevice()
        let pool = MetalInteractiveOutputTexturePool(capacity: 3)
        _ = try await pool.prewarm(width: 32,
                                   height: 24,
                                   device: device,
                                   count: 3)
        let lease = try await pool.acquire(width: 32,
                                           height: 24,
                                           device: device,
                                           frameIndex: nil)

        let resizedWhileBusy = try await pool.prewarm(width: 64,
                                                      height: 48,
                                                      device: device,
                                                      count: 3)

        XCTAssertFalse(resizedWhileBusy)
        let busySlotCount = await pool.debugSlotCount
        XCTAssertEqual(busySlotCount, 3)

        lease.release()
        try await Task.sleep(nanoseconds: 20_000_000)

        let resizedAfterRelease = try await pool.prewarm(width: 64,
                                                         height: 48,
                                                         device: device,
                                                         count: 3)
        XCTAssertTrue(resizedAfterRelease)
        let resizedSlotCount = await pool.debugSlotCount
        let resizedAvailableCount = await pool.debugAvailableSlotCount
        XCTAssertEqual(resizedSlotCount, 3)
        XCTAssertEqual(resizedAvailableCount, 3)
    }

    func testDebugLifecycleMetricsExposeAcquirePresentationAndRelease() async throws {
        let device = try makeDevice()
        let pool = MetalInteractiveOutputTexturePool(capacity: 2)

        let lease = try await pool.acquire(width: 32,
                                           height: 24,
                                           device: device,
                                           frameIndex: 4)

        var metrics = await pool.debugLifecycleMetrics
        XCTAssertEqual(metrics.acquiredCount, 1)
        XCTAssertEqual(metrics.presentedCount, 0)
        XCTAssertEqual(metrics.releasedCount, 0)
        XCTAssertEqual(metrics.pendingCount, 1)

        lease.markPresented()
        lease.release()

        metrics = await pool.debugLifecycleMetrics
        XCTAssertEqual(metrics.acquiredCount, 1)
        XCTAssertEqual(metrics.presentedCount, 1)
        XCTAssertEqual(metrics.releasedCount, 1)
        XCTAssertEqual(metrics.droppedCount, 0)
        XCTAssertEqual(metrics.pendingCount, 0)
        XCTAssertEqual(metrics.availableSlotCount, 1)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }
}
