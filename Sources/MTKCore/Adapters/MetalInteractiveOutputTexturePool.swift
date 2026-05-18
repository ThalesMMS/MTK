//
//  MetalInteractiveOutputTexturePool.swift
//  MTK
//
//  Leased output texture pool for async interactive Metal volume frames.
//

import Foundation
@preconcurrency import Metal

final actor MetalInteractiveOutputTexturePool {
    private struct Slot {
        let id: Int
        let texture: any MTLTexture
        var inUse: Bool

        var textureID: ObjectIdentifier {
            ObjectIdentifier(texture as AnyObject)
        }
    }

    private let capacity: Int
    private let poolIdentifier = UUID()
    private var slots: [Slot] = []
    private var nextSlotID = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    func acquire(width: Int,
                 height: Int,
                 device: any MTLDevice,
                 frameIndex: UInt64?) async throws -> OutputTextureLease {
        guard width > 0, height > 0 else {
            throw MetalVolumeRenderingAdapter.RenderingError.outputTextureUnavailable
        }

        while true {
            if shouldResetForSize(width: width, height: height) {
                if slots.contains(where: \.inUse) {
                    logWait(reason: "resizePending",
                            width: width,
                            height: height,
                            frameIndex: frameIndex)
                    await waitForRelease()
                    continue
                }

                slots.removeAll()
                Self.logEvent(
                    "interactive.slot.reset frameIndex=\(Self.describe(frameIndex)) width=\(width) height=\(height)"
                )
            }

            if let index = slots.firstIndex(where: { !$0.inUse && matches($0.texture, width: width, height: height) }) {
                return acquireExistingSlot(at: index, frameIndex: frameIndex)
            }

            if slots.count < capacity {
                return try allocateSlot(width: width,
                                        height: height,
                                        device: device,
                                        frameIndex: frameIndex)
            }

            logWait(reason: "poolFull",
                    width: width,
                    height: height,
                    frameIndex: frameIndex)
            await waitForRelease()
        }
    }

    func prewarm(width: Int,
                 height: Int,
                 device: any MTLDevice,
                 count: Int) throws -> Bool {
        guard width > 0, height > 0 else {
            throw MetalVolumeRenderingAdapter.RenderingError.outputTextureUnavailable
        }

        if shouldResetForSize(width: width, height: height) {
            guard !slots.contains(where: \.inUse) else {
                logWait(reason: "prewarmResizePending",
                        width: width,
                        height: height,
                        frameIndex: nil)
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

    var debugSlotCount: Int {
        slots.count
    }

    var debugAvailableSlotCount: Int {
        slots.filter { !$0.inUse }.count
    }

    private func acquireExistingSlot(at index: Int,
                                     frameIndex: UInt64?) -> OutputTextureLease {
        slots[index].inUse = true
        let slot = slots[index]
        let lease = makeLease(for: slot, frameIndex: frameIndex)
        logAcquire(slot: slot,
                   lease: lease,
                   action: "reuse",
                   frameIndex: frameIndex)
        return lease
    }

    private func allocateSlot(width: Int,
                              height: Int,
                              device: any MTLDevice,
                              frameIndex: UInt64?) throws -> OutputTextureLease {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalVolumeRenderingAdapter.RenderingError.outputTextureUnavailable
        }

        let slotID = nextSlotID
        nextSlotID += 1
        texture.label = "VolumeCompute.InteractiveOutput.slot\(slotID)"
        let slot = Slot(id: slotID,
                        texture: texture,
                        inUse: true)
        slots.append(slot)
        let lease = makeLease(for: slot, frameIndex: frameIndex)
        logAcquire(slot: slot,
                   lease: lease,
                   action: "allocate",
                   frameIndex: frameIndex)
        return lease
    }

    private func appendAvailableSlot(width: Int,
                                     height: Int,
                                     device: any MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalVolumeRenderingAdapter.RenderingError.outputTextureUnavailable
        }

        let slotID = nextSlotID
        nextSlotID += 1
        texture.label = "VolumeCompute.InteractiveOutput.slot\(slotID)"
        let slot = Slot(id: slotID,
                        texture: texture,
                        inUse: false)
        slots.append(slot)
        Self.logEvent(
            "interactive.slot.prewarm slotID=\(slot.id) textureID=\(String(describing: slot.textureID)) texture=\(slot.texture.width)x\(slot.texture.height) available=\(debugAvailableSlotCount)"
        )
    }

    private func makeLease(for slot: Slot,
                           frameIndex: UInt64?) -> OutputTextureLease {
        let lease = OutputTextureLease(
            texture: slot.texture,
            ownerPoolIdentifier: poolIdentifier,
            debugSlotID: slot.id,
            onPresented: { lease in
                Self.logEvent(
                    "interactive.slot.presented slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil")"
                )
            },
            onRelease: { lease in
                Task {
                    await self.release(lease)
                }
            }
        )
        lease.updateDebugContext(frameIndex: frameIndex)
        return lease
    }

    private func release(_ lease: OutputTextureLease) {
        guard lease.ownerPoolIdentifier == poolIdentifier else {
            Self.logEvent(
                "interactive.slot.release.ignored reason=foreignPool slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString)"
            )
            return
        }

        guard let index = slots.firstIndex(where: { $0.textureID == lease.textureIdentifier }) else {
            Self.logEvent(
                "interactive.slot.release.ignored reason=unknownTexture slotID=\(Self.describe(lease.debugSlotID)) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString)"
            )
            resumeNextWaiter()
            return
        }

        let slot = slots[index]
        if slots[index].inUse {
            slots[index].inUse = false
            Self.logEvent(
                "interactive.slot.release slotID=\(slot.id) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil") presented=\(lease.isPresented) pending=\(inUseCount)"
            )
        } else {
            Self.logEvent(
                "interactive.slot.release.ignored reason=duplicate slotID=\(slot.id) frameIndex=\(Self.describe(lease.debugFrameIndex)) textureID=\(String(describing: lease.textureIdentifier)) leaseID=\(lease.leaseIdentifier.uuidString) presentationToken=\(lease.debugPresentationToken ?? "nil") pending=\(inUseCount)"
            )
        }
        resumeNextWaiter()
    }

    private var inUseCount: Int {
        slots.filter(\.inUse).count
    }

    private func shouldResetForSize(width: Int, height: Int) -> Bool {
        slots.contains { !matches($0.texture, width: width, height: height) }
    }

    private func matches(_ texture: any MTLTexture,
                         width: Int,
                         height: Int) -> Bool {
        texture.width == width
            && texture.height == height
            && texture.pixelFormat == .bgra8Unorm
            && texture.storageMode == .private
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeNextWaiter() {
        guard waiters.isEmpty == false else {
            return
        }
        waiters.removeFirst().resume()
    }

    private func logAcquire(slot: Slot,
                            lease: OutputTextureLease,
                            action: String,
                            frameIndex: UInt64?) {
        Self.logEvent(
            "interactive.slot.acquire action=\(action) slotID=\(slot.id) frameIndex=\(Self.describe(frameIndex)) textureID=\(String(describing: slot.textureID)) leaseID=\(lease.leaseIdentifier.uuidString) texture=\(slot.texture.width)x\(slot.texture.height) pending=\(inUseCount)"
        )
    }

    private func logWait(reason: String,
                         width: Int,
                         height: Int,
                         frameIndex: UInt64?) {
        Self.logEvent(
            "interactive.slot.wait reason=\(reason) frameIndex=\(Self.describe(frameIndex)) requested=\(width)x\(height) pending=\(inUseCount) capacity=\(capacity)"
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
