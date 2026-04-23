//
//  OutputTexturePool.swift
//  MTK
//
//  Reusable Metal output texture pool for viewport render targets.
//

import Foundation
import os.log
@preconcurrency import Metal

struct OutputTextureKey: Hashable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
}

struct PooledTexture {
    var texture: any MTLTexture
    var key: OutputTextureKey
    var estimatedBytes: Int
    var inUse: Bool

    var metadata: VolumeResourceHandle.Metadata {
        VolumeResourceHandle.Metadata(
            resourceType: .outputTexture,
            debugLabel: texture.label,
            estimatedBytes: estimatedBytes,
            pixelFormat: texture.pixelFormat,
            storageMode: texture.storageMode,
            dimensions: VolumeResourceHandle.Metadata.Dimensions(
                width: texture.width,
                height: texture.height,
                depth: texture.depth
            )
        )
    }
}

final class OutputTexturePool {
    enum PoolError: Error, Equatable {
        case invalidDimensions(width: Int, height: Int)
        case textureCreationFailed(width: Int, height: Int, pixelFormat: MTLPixelFormat)
    }

    private var entries: [ObjectIdentifier: PooledTexture] = [:]
    private var activeLeaseTextureIDs: Set<ObjectIdentifier> = []
    private let poolIdentifier = UUID()
    private let stateLock = NSLock()
    private let featureFlags: FeatureFlags
    private let lifecycleLogger = os.Logger(subsystem: "com.mtk.volumerendering",
                                            category: "ResourceLifecycle")
    private var debugLeaseAcquiredCountStorage = 0
    private var debugLeasePresentedCountStorage = 0
    private var debugLeaseReleasedCountStorage = 0

    init(featureFlags: FeatureFlags = []) {
        self.featureFlags = featureFlags
    }

    func acquire(width: Int,
                 height: Int,
                 pixelFormat: MTLPixelFormat,
                 device: any MTLDevice) throws -> any MTLTexture {
        let acquisition = try acquireTexture(width: width,
                                             height: height,
                                             pixelFormat: pixelFormat,
                                             device: device,
                                             reserveLease: false)
        recordLifecycleEvent(action: acquisition.action,
                             estimatedBytes: acquisition.estimatedBytes,
                             textureID: acquisition.textureID,
                             leaseID: nil,
                             device: acquisition.texture.device)
        return acquisition.texture
    }

    func acquireWithLease(width: Int,
                          height: Int,
                          pixelFormat: MTLPixelFormat,
                          device: any MTLDevice) throws -> OutputTextureLease {
        let acquisition = try acquireTexture(width: width,
                                             height: height,
                                             pixelFormat: pixelFormat,
                                             device: device,
                                             reserveLease: true)
        let lease = OutputTextureLease(
            texture: acquisition.texture,
            ownerPoolIdentifier: poolIdentifier,
            onPresented: { [weak self] lease in
                self?.recordPresentation(for: lease)
            },
            onRelease: { [weak self] lease in
                self?.releaseFromLease(lease)
            }
        )

        stateLock.withLock {
            debugLeaseAcquiredCountStorage += 1
        }
        recordLifecycleEvent(action: acquisition.action,
                             estimatedBytes: acquisition.estimatedBytes,
                             textureID: acquisition.textureID,
                             leaseID: lease.leaseIdentifier,
                             device: acquisition.texture.device)
        return lease
    }

    func release(_ lease: OutputTextureLease) {
        guard lease.ownerPoolIdentifier == poolIdentifier else {
            logLifecycle(resourceType: "outputTexture",
                         action: "lease.foreignReleaseIgnored",
                         estimatedBytes: 0,
                         textureID: lease.textureIdentifier,
                         leaseID: lease.leaseIdentifier)
            return
        }

        lease.release()
    }

    func release(texture: any MTLTexture) {
        let id = ObjectIdentifier(texture as AnyObject)
        let estimatedBytes: Int?
        let didRelease: Bool

        stateLock.lock()
        guard var entry = entries[id] else {
            stateLock.unlock()
            logLifecycle(resourceType: "outputTexture",
                         action: "release.unknownTextureIgnored",
                         estimatedBytes: 0,
                         textureID: id,
                         leaseID: nil)
            return
        }

        estimatedBytes = entry.estimatedBytes
        if activeLeaseTextureIDs.contains(id) {
            stateLock.unlock()
            logLifecycle(resourceType: "outputTexture",
                         action: "release.leaseActiveIgnored",
                         estimatedBytes: estimatedBytes ?? 0,
                         textureID: id,
                         leaseID: nil)
            return
        }

        if entry.inUse {
            entry.inUse = false
            entries[id] = entry
            activeLeaseTextureIDs.remove(id)
            didRelease = true
        } else {
            didRelease = false
        }
        stateLock.unlock()

        guard didRelease, let estimatedBytes else {
            return
        }

        recordLifecycleEvent(action: "released",
                             estimatedBytes: estimatedBytes,
                             textureID: id,
                             leaseID: nil,
                             device: texture.device)
    }

    func resize(from texture: any MTLTexture,
                to key: OutputTextureKey,
                device: any MTLDevice) throws -> any MTLTexture {
        let oldBytes = stateLock.withLock {
            entries[ObjectIdentifier(texture as AnyObject)]?.estimatedBytes ?? ResourceMemoryEstimator.estimate(for: texture)
        }
        logLifecycle(resourceType: "outputTexture",
                     action: "resize",
                     estimatedBytes: oldBytes,
                     textureID: ObjectIdentifier(texture as AnyObject),
                     leaseID: nil)
        release(texture: texture)
        return try acquire(width: key.width,
                           height: key.height,
                           pixelFormat: key.pixelFormat,
                           device: device)
    }

    func resize(from texture: any MTLTexture,
                toWidth width: Int,
                toHeight height: Int,
                device: any MTLDevice) throws -> any MTLTexture {
        let key = OutputTextureKey(width: width,
                                   height: height,
                                   pixelFormat: texture.pixelFormat)
        return try resize(from: texture, to: key, device: device)
    }

    func hasLease(for texture: any MTLTexture) -> Bool {
        stateLock.withLock {
            activeLeaseTextureIDs.contains(ObjectIdentifier(texture as AnyObject))
        }
    }

    var metadata: [VolumeResourceHandle.Metadata] {
        stateLock.withLock {
            entries.values.map(\.metadata)
        }
    }

    var estimatedBytes: Int {
        stateLock.withLock {
            entries.values.reduce(0) { $0 + $1.estimatedBytes }
        }
    }

    var textureCount: Int {
        stateLock.withLock {
            entries.count
        }
    }

    var inUseCount: Int {
        stateLock.withLock {
            entries.values.filter(\.inUse).count
        }
    }

    var debugTextureCount: Int {
        textureCount
    }

    var debugLeaseAcquiredCount: Int {
        stateLock.withLock {
            debugLeaseAcquiredCountStorage
        }
    }

    var debugLeasePresentedCount: Int {
        stateLock.withLock {
            debugLeasePresentedCountStorage
        }
    }

    var debugLeaseReleasedCount: Int {
        stateLock.withLock {
            debugLeaseReleasedCountStorage
        }
    }

    var debugLeaseCount: Int {
        debugLeaseAcquiredCount
    }

    var debugLeasePendingCount: Int {
        stateLock.withLock {
            max(0, debugLeaseAcquiredCountStorage - debugLeaseReleasedCountStorage)
        }
    }

    func debugReleaseUnknownLeaseTextureID() {
        releaseFromCallback(textureID: ObjectIdentifier(UUIDBox()),
                            leaseID: UUID(),
                            device: nil)
    }

    func debugIsInUse(_ texture: any MTLTexture) -> Bool? {
        stateLock.withLock {
            entries[ObjectIdentifier(texture as AnyObject)]?.inUse
        }
    }

    private struct Acquisition {
        var texture: any MTLTexture
        var textureID: ObjectIdentifier
        var estimatedBytes: Int
        var action: String
    }

    private func acquireTexture(width: Int,
                                height: Int,
                                pixelFormat: MTLPixelFormat,
                                device: any MTLDevice,
                                reserveLease: Bool) throws -> Acquisition {
        guard width > 0, height > 0 else {
            throw PoolError.invalidDimensions(width: width, height: height)
        }

        let key = OutputTextureKey(width: width, height: height, pixelFormat: pixelFormat)
        stateLock.lock()
        if let existingID = entries.first(where: { $0.value.key == key && !$0.value.inUse })?.key,
           var entry = entries[existingID] {
            entry.inUse = true
            entries[existingID] = entry
            if reserveLease {
                activeLeaseTextureIDs.insert(existingID)
            }
            stateLock.unlock()
            return Acquisition(texture: entry.texture,
                               textureID: existingID,
                               estimatedBytes: entry.estimatedBytes,
                               action: "reused")
        }
        stateLock.unlock()

        // StorageModePolicy.md: output render targets are GPU-only and private.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PoolError.textureCreationFailed(width: width, height: height, pixelFormat: pixelFormat)
        }
        texture.label = MTL_label.outputTexture

        let id = ObjectIdentifier(texture as AnyObject)
        let estimatedBytes = ResourceMemoryEstimator.estimate(for: texture)

        stateLock.lock()
        let acquisition: Acquisition
        if let existingID = entries.first(where: { $0.value.key == key && !$0.value.inUse })?.key,
           var entry = entries[existingID] {
            entry.inUse = true
            entries[existingID] = entry
            if reserveLease {
                activeLeaseTextureIDs.insert(existingID)
            }
            acquisition = Acquisition(texture: entry.texture,
                                      textureID: existingID,
                                      estimatedBytes: entry.estimatedBytes,
                                      action: "reused")
        } else {
            entries[id] = PooledTexture(texture: texture,
                                        key: key,
                                        estimatedBytes: estimatedBytes,
                                        inUse: true)
            if reserveLease {
                activeLeaseTextureIDs.insert(id)
            }
            acquisition = Acquisition(texture: texture,
                                      textureID: id,
                                      estimatedBytes: estimatedBytes,
                                      action: "newAllocation")
        }
        stateLock.unlock()

        return acquisition
    }

    private func recordPresentation(for lease: OutputTextureLease) {
        guard lease.ownerPoolIdentifier == poolIdentifier else {
            logLifecycle(resourceType: "outputTexture",
                         action: "lease.foreignPresentIgnored",
                         estimatedBytes: 0,
                         textureID: lease.textureIdentifier,
                         leaseID: lease.leaseIdentifier)
            return
        }

        let estimatedBytes: Int?
        stateLock.lock()
        estimatedBytes = entries[lease.textureIdentifier]?.estimatedBytes
        if estimatedBytes != nil {
            debugLeasePresentedCountStorage += 1
        }
        stateLock.unlock()

        recordLifecycleEvent(action: "presented",
                             estimatedBytes: estimatedBytes ?? 0,
                             textureID: lease.textureIdentifier,
                             leaseID: lease.leaseIdentifier,
                             device: lease.texture.device)
    }

    private func releaseFromLease(_ lease: OutputTextureLease) {
        guard lease.ownerPoolIdentifier == poolIdentifier else {
            logLifecycle(resourceType: "outputTexture",
                         action: "lease.foreignCallbackIgnored",
                         estimatedBytes: 0,
                         textureID: lease.textureIdentifier,
                         leaseID: lease.leaseIdentifier)
            return
        }

        releaseFromCallback(textureID: lease.textureIdentifier,
                            leaseID: lease.leaseIdentifier,
                            device: lease.texture.device)
    }

    private func releaseFromCallback(textureID: ObjectIdentifier,
                                     leaseID: UUID,
                                     device: (any MTLDevice)?) {
        let estimatedBytes: Int?
        let action: String

        stateLock.lock()
        if var entry = entries[textureID] {
            estimatedBytes = entry.estimatedBytes
            if entry.inUse {
                entry.inUse = false
                entries[textureID] = entry
                activeLeaseTextureIDs.remove(textureID)
                debugLeaseReleasedCountStorage += 1
                action = "released"
            } else {
                action = "release.duplicateIgnored"
            }
        } else {
            estimatedBytes = nil
            action = "release.unknownLeaseIgnored"
        }
        stateLock.unlock()

        recordLifecycleEvent(action: action,
                             estimatedBytes: estimatedBytes ?? 0,
                             textureID: textureID,
                             leaseID: leaseID,
                             device: device)
    }

    private func recordLifecycleEvent(action: String,
                                      estimatedBytes: Int,
                                      textureID: ObjectIdentifier,
                                      leaseID: UUID?,
                                      device: (any MTLDevice)?) {
        logLifecycle(resourceType: "outputTexture",
                     action: action,
                     estimatedBytes: estimatedBytes,
                     textureID: textureID,
                     leaseID: leaseID)
    }

    private func logLifecycle(resourceType: String,
                              action: String,
                              estimatedBytes: Int,
                              textureID: ObjectIdentifier,
                              leaseID: UUID?) {
        guard featureFlags.contains(.diagnosticLogging) else {
            return
        }

        lifecycleLogger.info(
            "resource=\(resourceType, privacy: .public) action=\(action, privacy: .public) estimatedBytes=\(estimatedBytes, privacy: .public) textureID=\(String(describing: textureID), privacy: .public) leaseID=\(leaseID?.uuidString ?? "none", privacy: .public)"
        )
    }
}

private final class UUIDBox {}
