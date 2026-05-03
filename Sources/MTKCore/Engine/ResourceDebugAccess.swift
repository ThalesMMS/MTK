//
//  ResourceDebugAccess.swift
//  MTK
//
//  Debug-only inspection helpers for resource caches.
//

import Foundation
@preconcurrency import Metal

#if DEBUG

/// Thin facade that centralizes debug-only accessors for the rendering engine's
/// resource caches.
///
/// Note: This intentionally keeps logic minimal and delegates to the
/// canonical services so behavior stays consistent.
internal struct ResourceDebugAccess {
    private let volumeTextureCountProvider: () -> Int
    private let transferTextureCountProvider: () -> Int
    private let outputTextureCountProvider: () -> Int
    private let memoryBreakdownProvider: () -> ResourceMemoryBreakdown
    private let outputPoolTextureCountProvider: () -> Int
    private let outputPoolInUseCountProvider: () -> Int
    private let totalReferenceCountProvider: () -> Int
    private let volumeTextureObjectIDProvider: (VolumeResourceHandle) -> ObjectIdentifier?
    private let transferTextureLastAccessProvider: (any MTLTexture) -> CFAbsoluteTime?
    private let outputTextureInUseProvider: (any MTLTexture) -> Bool?
    private let leaseCountProvider: () -> Int
    private let leaseAcquiredCountProvider: () -> Int
    private let leasePresentedCountProvider: () -> Int
    private let leaseReleasedCountProvider: () -> Int
    private let leasePendingCountProvider: () -> Int

    init(volumeTextureCount: @escaping () -> Int,
         transferTextureCount: @escaping () -> Int,
         outputTextureCount: @escaping () -> Int,
         memoryBreakdown: @escaping () -> ResourceMemoryBreakdown,
         outputPoolTextureCount: @escaping () -> Int,
         outputPoolInUseCount: @escaping () -> Int,
         totalReferenceCount: @escaping () -> Int,
         volumeTextureObjectIdentifier: @escaping (VolumeResourceHandle) -> ObjectIdentifier?,
         transferTextureLastAccessTime: @escaping (any MTLTexture) -> CFAbsoluteTime?,
         outputTextureIsInUse: @escaping (any MTLTexture) -> Bool?,
         outputTextureLeaseCount: @escaping () -> Int,
         outputTextureLeaseAcquiredCount: @escaping () -> Int,
         outputTextureLeasePresentedCount: @escaping () -> Int,
         outputTextureLeaseReleasedCount: @escaping () -> Int,
         outputTextureLeasePendingCount: @escaping () -> Int) {
        self.volumeTextureCountProvider = volumeTextureCount
        self.transferTextureCountProvider = transferTextureCount
        self.outputTextureCountProvider = outputTextureCount
        self.memoryBreakdownProvider = memoryBreakdown
        self.outputPoolTextureCountProvider = outputPoolTextureCount
        self.outputPoolInUseCountProvider = outputPoolInUseCount
        self.totalReferenceCountProvider = totalReferenceCount
        self.volumeTextureObjectIDProvider = volumeTextureObjectIdentifier
        self.transferTextureLastAccessProvider = transferTextureLastAccessTime
        self.outputTextureInUseProvider = outputTextureIsInUse
        self.leaseCountProvider = outputTextureLeaseCount
        self.leaseAcquiredCountProvider = outputTextureLeaseAcquiredCount
        self.leasePresentedCountProvider = outputTextureLeasePresentedCount
        self.leaseReleasedCountProvider = outputTextureLeaseReleasedCount
        self.leasePendingCountProvider = outputTextureLeasePendingCount
    }

    var volumeTextureCount: Int { volumeTextureCountProvider() }
    var transferTextureCount: Int { transferTextureCountProvider() }
    var outputTextureCount: Int { outputTextureCountProvider() }
    var memoryBreakdown: ResourceMemoryBreakdown { memoryBreakdownProvider() }
    var outputPoolTextureCount: Int { outputPoolTextureCountProvider() }
    var outputPoolInUseCount: Int { outputPoolInUseCountProvider() }
    var totalReferenceCount: Int { totalReferenceCountProvider() }

    func volumeTextureObjectIdentifier(for handle: VolumeResourceHandle) -> ObjectIdentifier? {
        volumeTextureObjectIDProvider(handle)
    }

    func transferTextureLastAccessTime(for texture: any MTLTexture) -> CFAbsoluteTime? {
        transferTextureLastAccessProvider(texture)
    }

    func outputTextureIsInUse(_ texture: any MTLTexture) -> Bool? {
        outputTextureInUseProvider(texture)
    }

    var outputTextureLeaseCount: Int { leaseCountProvider() }
    var outputTextureLeaseAcquiredCount: Int { leaseAcquiredCountProvider() }
    var outputTextureLeasePresentedCount: Int { leasePresentedCountProvider() }
    var outputTextureLeaseReleasedCount: Int { leaseReleasedCountProvider() }
    var outputTextureLeasePendingCount: Int { leasePendingCountProvider() }
}

#endif
