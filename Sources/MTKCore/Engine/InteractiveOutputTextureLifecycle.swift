//
//  InteractiveOutputTextureLifecycle.swift
//  MTK
//
//  Unified lifecycle for interactive output texture leases.
//

import Foundation
@preconcurrency import Metal

package enum InteractiveOutputTextureLifecycleError: Error, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case textureCreationFailed(width: Int, height: Int)
    case teardownCompleted
}

package struct InteractiveOutputTextureLifecycleMetrics: Sendable, Equatable {
    package var acquiredCount: Int
    package var presentedCount: Int
    package var releasedCount: Int
    package var droppedCount: Int
    package var pendingCount: Int
    package var slotCount: Int
    package var availableSlotCount: Int
    package var capacityWaitCount: Int
    package var resizeWaitCount: Int
}

package final class InteractiveOutputTextureLifecycle: @unchecked Sendable {
    private struct Slot {
        let id: Int
        let texture: any MTLTexture
        var inUse: Bool
        var lease: OutputTextureLease?

        var textureID: ObjectIdentifier {
            ObjectIdentifier(texture as AnyObject)
        }
    }

    private enum AcquireResult {
        case lease(OutputTextureLease)
        case wait
    }

    private let capacity: Int
    private let poolIdentifier = UUID()
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var nextSlotID = 0
    private var waiters: [CheckedContinuation<AcquireResult, any Error>] = []
    private var isTornDown = false
    private var acquiredCount = 0
    private var presentedCount = 0
    private var releasedCount = 0
    private var droppedCount = 0
    private var capacityWaitCount = 0
    private var resizeWaitCount = 0

    package init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    package func acquire(width: Int,
                         height: Int,
                         device: any MTLDevice,
                         frameIndex: UInt64?) async throws -> OutputTextureLease {
        guard width > 0, height > 0 else {
            throw InteractiveOutputTextureLifecycleError.invalidDimensions(width: width, height: height)
        }

        while true {
            switch try await acquireOrWait(width: width,
                                           height: height,
                                           device: device,
                                           frameIndex: frameIndex) {
            case .lease(let lease):
                return lease
            case .wait:
                continue
            }
        }
    }

    @discardableResult
    package func prewarm(width: Int,
                         height: Int,
                         device: any MTLDevice,
                         count: Int) throws -> Bool {
        guard width > 0, height > 0 else {
            throw InteractiveOutputTextureLifecycleError.invalidDimensions(width: width, height: height)
        }

        lock.lock()
        defer { lock.unlock() }

        guard !isTornDown else {
            throw InteractiveOutputTextureLifecycleError.teardownCompleted
        }

        if shouldResetForSize(width: width, height: height) {
            guard !slots.contains(where: \.inUse) else {
                resizeWaitCount += 1
                logWait(reason: "prewarmResizePending",
                        width: width,
                        height: height,
                        frameIndex: nil,
                        pending: slots.filter(\.inUse).count)
                return false
            }
            slots.removeAll()
            Self.logEvent(
                "interactive.slot.reset frameIndex=nil width=\(width) height=\(height)"
            )
        }

        let targetCount = min(max(count, 1), capacity)
        while slots.count < targetCount {
            try appendAvailableSlot(width: width,
                                    height: height,
                                    device: device)
        }
        return true
    }

    package func teardown() {
        lock.lock()
        isTornDown = true
        let activeLeases = slots.compactMap(\.lease)
        lock.unlock()

        for lease in activeLeases {
            lease.release()
        }

        lock.lock()
        slots.removeAll()
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()

        continuations.forEach {
            $0.resume(throwing: InteractiveOutputTextureLifecycleError.teardownCompleted)
        }
    }

    package var debugMetrics: InteractiveOutputTextureLifecycleMetrics {
        lock.lock()
        defer { lock.unlock() }
        return InteractiveOutputTextureLifecycleMetrics(
            acquiredCount: acquiredCount,
            presentedCount: presentedCount,
            releasedCount: releasedCount,
            droppedCount: droppedCount,
            pendingCount: slots.filter(\.inUse).count,
            slotCount: slots.count,
            availableSlotCount: slots.filter { !$0.inUse }.count,
            capacityWaitCount: capacityWaitCount,
            resizeWaitCount: resizeWaitCount
        )
    }

    private func acquireOrWait(width: Int,
                               height: Int,
                               device: any MTLDevice,
                               frameIndex: UInt64?) async throws -> AcquireResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            do {
                let result = try acquireOrWaitLocked(width: width,
                                                     height: height,
                                                     device: device,
                                                     frameIndex: frameIndex)
                switch result {
                case .lease:
                    lock.unlock()
                    continuation.resume(returning: result)
                case .wait:
                    waiters.append(continuation)
                    lock.unlock()
                }
            } catch {
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    private func acquireOrWaitLocked(width: Int,
                                     height: Int,
                                     device: any MTLDevice,
                                     frameIndex: UInt64?) throws -> AcquireResult {
        guard !isTornDown else {
            throw InteractiveOutputTextureLifecycleError.teardownCompleted
        }

        if shouldResetForSize(width: width, height: height) {
            if slots.contains(where: \.inUse) {
                resizeWaitCount += 1
                logWait(reason: "resizePending",
                        width: width,
                        height: height,
                        frameIndex: frameIndex,
                        pending: slots.filter(\.inUse).count)
                return .wait
            }

            slots.removeAll()
            Self.logEvent(
                "interactive.slot.reset frameIndex=\(Self.describe(frameIndex)) width=\(width) height=\(height)"
            )
        }

        if let index = slots.firstIndex(where: { !$0.inUse && matches($0.texture, width: width, height: height) }) {
            return .lease(acquireExistingSlot(at: index, frameIndex: frameIndex))
        }

        if slots.count < capacity {
            return .lease(try allocateSlot(width: width,
                                           height: height,
                                           device: device,
                                           frameIndex: frameIndex))
        }

        capacityWaitCount += 1
        logWait(reason: "poolFull",
                width: width,
                height: height,
                frameIndex: frameIndex,
                pending: slots.filter(\.inUse).count)
        return .wait
    }

    private func acquireExistingSlot(at index: Int,
                                     frameIndex: UInt64?) -> OutputTextureLease {
        slots[index].inUse = true
        let lease = makeLease(for: slots[index], frameIndex: frameIndex)
        slots[index].lease = lease
        acquiredCount += 1
        let pending = slots.filter(\.inUse).count
        logAcquire(slot: slots[index],
                   lease: lease,
                   action: "reuse",
                   frameIndex: frameIndex,
                   pending: pending)
        return lease
    }

    private func allocateSlot(width: Int,
                              height: Int,
                              device: any MTLDevice,
                              frameIndex: UInt64?) throws -> OutputTextureLease {
        guard let texture = OutputTextureFactory.makeTexture(
            device: device,
            width: width,
            height: height,
            label: "VolumeCompute.InteractiveOutput.slot\(nextSlotID)"
        ) else {
            throw InteractiveOutputTextureLifecycleError.textureCreationFailed(width: width, height: height)
        }

        let slotID = nextSlotID
        nextSlotID += 1
        var slot = Slot(id: slotID,
                        texture: texture,
                        inUse: true,
                        lease: nil)
        let lease = makeLease(for: slot, frameIndex: frameIndex)
        slot.lease = lease
        slots.append(slot)
        acquiredCount += 1
        let pending = slots.filter(\.inUse).count
        logAcquire(slot: slot,
                   lease: lease,
                   action: "allocate",
                   frameIndex: frameIndex,
                   pending: pending)
        return lease
    }

    private func appendAvailableSlot(width: Int,
                                     height: Int,
                                     device: any MTLDevice) throws {
        guard let texture = OutputTextureFactory.makeTexture(
            device: device,
            width: width,
            height: height,
            label: "VolumeCompute.InteractiveOutput.slot\(nextSlotID)"
        ) else {
            throw InteractiveOutputTextureLifecycleError.textureCreationFailed(width: width, height: height)
        }

        let slotID = nextSlotID
        nextSlotID += 1
        let slot = Slot(id: slotID,
                        texture: texture,
                        inUse: false,
                        lease: nil)
        slots.append(slot)
        Self.logEvent(
            "interactive.slot.prewarm slotID=\(slot.id) textureID=\(String(describing: slot.textureID)) texture=\(slot.texture.width)x\(slot.texture.height) available=\(slots.filter { !$0.inUse }.count)"
        )
    }

    private func makeLease(for slot: Slot,
                           frameIndex: UInt64?) -> OutputTextureLease {
        let lease = OutputTextureLease(
            texture: slot.texture,
            ownerPoolIdentifier: poolIdentifier,
            debugSlotID: slot.id,
            onPresented: { [weak self] lease in
                self?.recordPresentation(for: lease)
            },
            onRelease: { [weak self] lease in
                self?.releaseFromLease(lease)
            }
        )
        lease.updateDebugContext(frameIndex: frameIndex)
        return lease
    }

    private func recordPresentation(for lease: OutputTextureLease) {
        lock.lock()
        let shouldRecord = lease.ownerPoolIdentifier == poolIdentifier
            && slots.contains { $0.lease === lease }
        if shouldRecord {
            presentedCount += 1
        }
        lock.unlock()

        guard shouldRecord else {
            Self.logEvent(
                "interactive.slot.present.ignored reason=foreignOrUnknown slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString)"
            )
            return
        }

        Self.logEvent(
            "interactive.slot.presented slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil")"
        )
    }

    private func releaseFromLease(_ lease: OutputTextureLease) {
        guard lease.ownerPoolIdentifier == poolIdentifier else {
            Self.logEvent(
                "interactive.slot.release.ignored reason=foreignPool slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString)"
            )
            return
        }

        var releasedSlot: Slot?
        var ignoredReason: String?
        let didDrop = !lease.isPresented

        lock.lock()
        if let index = slots.firstIndex(where: { $0.lease === lease }) {
            let slot = slots[index]
            if slots[index].inUse {
                slots[index].inUse = false
                slots[index].lease = nil
                releasedCount += 1
                if didDrop {
                    droppedCount += 1
                }
                releasedSlot = slot
            } else {
                ignoredReason = "duplicate"
            }
        } else {
            ignoredReason = "unknownTexture"
        }
        let pending = slots.filter(\.inUse).count
        lock.unlock()

        if let releasedSlot {
            Self.logEvent(
                "interactive.slot.release slotID=\(releasedSlot.id) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil") presented=\(lease.isPresented) dropped=\(didDrop) pending=\(pending)"
            )
        } else {
            Self.logEvent(
                "interactive.slot.release.ignored reason=\(ignoredReason ?? "unknown") slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil") pending=\(pending)"
            )
        }
        resumeNextWaiter()
    }

    private func shouldResetForSize(width: Int, height: Int) -> Bool {
        slots.contains { !matches($0.texture, width: width, height: height) }
    }

    private func matches(_ texture: any MTLTexture,
                         width: Int,
                         height: Int) -> Bool {
        OutputTextureFactory.matchesPrivateBGRAOutput(texture,
                                                      width: width,
                                                      height: height)
    }

    private func resumeNextWaiter() {
        lock.lock()
        let continuation = waiters.isEmpty ? nil : waiters.removeFirst()
        let shouldFail = isTornDown
        lock.unlock()

        if shouldFail {
            continuation?.resume(throwing: InteractiveOutputTextureLifecycleError.teardownCompleted)
        } else {
            continuation?.resume(returning: .wait)
        }
    }

    private func logAcquire(slot: Slot,
                            lease: OutputTextureLease,
                            action: String,
                            frameIndex: UInt64?,
                            pending: Int) {
        Self.logEvent(
            "interactive.slot.acquire action=\(action) slotID=\(slot.id) frameIndex=\(Self.describe(frameIndex)) textureID=\(String(describing: slot.textureID)) leaseID=\(lease.leaseIdentifier.uuidString) texture=\(slot.texture.width)x\(slot.texture.height) pending=\(pending)"
        )
    }

    private func logWait(reason: String,
                         width: Int,
                         height: Int,
                         frameIndex: UInt64?,
                         pending: Int) {
        Self.logEvent(
            "interactive.slot.wait reason=\(reason) frameIndex=\(Self.describe(frameIndex)) requested=\(width)x\(height) pending=\(pending) capacity=\(capacity)"
        )
    }

    private static func logEvent(_ message: String) {
        guard Logger.performanceLoggingEnabled else { return }
        Logger.info("[MTK3DInteraction] \(message)",
                    category: "com.mtk.volumerendering.MetalVolumeRenderingAdapter")
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func describe(_ value: UInt64?) -> String {
        value.map(String.init) ?? "nil"
    }
}
