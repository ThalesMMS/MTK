import Metal
import XCTest

@testable import MTKCore

final class InteractiveOutputTextureLifecycleTests: XCTestCase {
    func testAcquirePresentationAndReleaseUpdateLifecycleMetrics() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 2)

        let lease = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: 7)

        var metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.acquiredCount, 1)
        XCTAssertEqual(metrics.presentedCount, 0)
        XCTAssertEqual(metrics.releasedCount, 0)
        XCTAssertEqual(metrics.droppedCount, 0)
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.slotCount, 1)
        XCTAssertEqual(metrics.availableSlotCount, 0)
        XCTAssertEqual(lease.debugFrameIndex, 7)

        lease.markPresented()
        metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.presentedCount, 1)
        XCTAssertEqual(metrics.pendingCount, 1)

        lease.release()
        metrics = lifecycle.debugMetrics
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(metrics.releasedCount, 1)
        XCTAssertEqual(metrics.droppedCount, 0)
        XCTAssertEqual(metrics.pendingCount, 0)
        XCTAssertEqual(metrics.availableSlotCount, 1)
    }

    func testReleaseWithoutPresentationRecordsDroppedPresentation() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 1)

        let lease = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: nil)

        lease.release()

        let metrics = lifecycle.debugMetrics
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(metrics.acquiredCount, 1)
        XCTAssertEqual(metrics.presentedCount, 0)
        XCTAssertEqual(metrics.releasedCount, 1)
        XCTAssertEqual(metrics.droppedCount, 1)
        XCTAssertEqual(metrics.pendingCount, 0)
        XCTAssertEqual(metrics.availableSlotCount, 1)
    }

    func testCapacityPressureWaitsUntilLeaseReleaseAndRecordsBackpressure() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 1)
        let first = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: 1)

        let blockedAcquire = Task {
            try await lifecycle.acquire(width: 32,
                                        height: 24,
                                        device: device,
                                        frameIndex: 2)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        var metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.capacityWaitCount, 1)
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.availableSlotCount, 0)

        first.release()
        let second = try await blockedAcquire.value
        metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.acquiredCount, 2)
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.slotCount, 1)
        XCTAssertEqual(ObjectIdentifier(first.texture as AnyObject),
                       ObjectIdentifier(second.texture as AnyObject))

        second.release()
    }

    func testResizePressureWaitsUntilLeaseReleaseAndRecordsBackpressure() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 1)
        let first = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: 1)

        let blockedResize = Task {
            try await lifecycle.acquire(width: 64,
                                        height: 48,
                                        device: device,
                                        frameIndex: 2)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        var metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.resizeWaitCount, 1)
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.slotCount, 1)

        first.release()
        let resized = try await blockedResize.value
        metrics = lifecycle.debugMetrics
        XCTAssertEqual(metrics.acquiredCount, 2)
        XCTAssertEqual(metrics.releasedCount, 1)
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.slotCount, 1)
        XCTAssertEqual(resized.texture.width, 64)
        XCTAssertEqual(resized.texture.height, 48)

        resized.release()
    }

    func testTeardownReleasesPendingLeasesAndDropsSlots() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 2)
        let first = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: 1)
        let second = try await lifecycle.acquire(width: 32,
                                                 height: 24,
                                                 device: device,
                                                 frameIndex: 2)

        lifecycle.teardown()

        let metrics = lifecycle.debugMetrics
        XCTAssertTrue(first.isReleased)
        XCTAssertTrue(second.isReleased)
        XCTAssertEqual(metrics.releasedCount, 2)
        XCTAssertEqual(metrics.droppedCount, 2)
        XCTAssertEqual(metrics.pendingCount, 0)
        XCTAssertEqual(metrics.slotCount, 0)
        XCTAssertEqual(metrics.availableSlotCount, 0)
    }

    func testTeardownWakesBlockedAcquireWithError() async throws {
        let device = try makeDevice()
        let lifecycle = InteractiveOutputTextureLifecycle(capacity: 1)
        let first = try await lifecycle.acquire(width: 32,
                                                height: 24,
                                                device: device,
                                                frameIndex: 1)

        let blockedAcquire = Task {
            try await lifecycle.acquire(width: 32,
                                        height: 24,
                                        device: device,
                                        frameIndex: 2)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(lifecycle.debugMetrics.capacityWaitCount, 1)

        lifecycle.teardown()

        do {
            let lease = try await blockedAcquire.value
            lease.release()
            XCTFail("Expected teardown to fail blocked acquire instead of returning a lease")
        } catch let error as InteractiveOutputTextureLifecycleError {
            XCTAssertEqual(error, .teardownCompleted)
            XCTAssertTrue(first.isReleased)
        } catch {
            XCTFail("Expected teardownCompleted, got \(error)")
        }
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }
}
