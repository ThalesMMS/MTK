//
//  MetalInteractiveOutputTexturePool.swift
//  MTK
//
//  Adapter-facing facade for interactive output texture leases.
//

@preconcurrency import Metal

final actor MetalInteractiveOutputTexturePool {
    private let lifecycle: InteractiveOutputTextureLifecycle

    init(capacity: Int = 3) {
        lifecycle = InteractiveOutputTextureLifecycle(capacity: capacity)
    }

    func acquire(width: Int,
                 height: Int,
                 device: any MTLDevice,
                 frameIndex: UInt64?) async throws -> OutputTextureLease {
        do {
            return try await lifecycle.acquire(width: width,
                                               height: height,
                                               device: device,
                                               frameIndex: frameIndex)
        } catch {
            throw Self.mapLifecycleError(error)
        }
    }

    func prewarm(width: Int,
                 height: Int,
                 device: any MTLDevice,
                 count: Int) throws -> Bool {
        do {
            return try lifecycle.prewarm(width: width,
                                         height: height,
                                         device: device,
                                         count: count)
        } catch {
            throw Self.mapLifecycleError(error)
        }
    }

    func teardown() {
        lifecycle.teardown()
    }

    var debugLifecycleMetrics: InteractiveOutputTextureLifecycleMetrics {
        lifecycle.debugMetrics
    }

    var debugSlotCount: Int {
        lifecycle.debugMetrics.slotCount
    }

    var debugAvailableSlotCount: Int {
        lifecycle.debugMetrics.availableSlotCount
    }

    private static func mapLifecycleError(_ error: any Error) -> any Error {
        switch error {
        case is InteractiveOutputTextureLifecycleError:
            return MetalVolumeRenderingAdapter.RenderingError.outputTextureUnavailable
        default:
            return error
        }
    }
}
