//
//  TextureLeasePool.swift
//  MTK
//
//  Facade service for output texture allocation + leasing.
//  Extracted from VolumeResourceManager to isolate pooling/lease semantics.
//

import Foundation
@preconcurrency import Metal

final class TextureLeasePool {
    private let outputPool: OutputTexturePool

    init(featureFlags: FeatureFlags = []) {
        self.outputPool = OutputTexturePool(featureFlags: featureFlags)
    }

    func acquire(width: Int,
                 height: Int,
                 pixelFormat: MTLPixelFormat,
                 device: any MTLDevice) throws -> any MTLTexture {
        try outputPool.acquire(width: width,
                               height: height,
                               pixelFormat: pixelFormat,
                               device: device)
    }

    func acquireWithLease(width: Int,
                          height: Int,
                          pixelFormat: MTLPixelFormat,
                          device: any MTLDevice) throws -> OutputTextureLease {
        try outputPool.acquireWithLease(width: width,
                                        height: height,
                                        pixelFormat: pixelFormat,
                                        device: device)
    }

    func release(texture: any MTLTexture) {
        outputPool.release(texture: texture)
    }

    func release(_ lease: OutputTextureLease) {
        outputPool.release(lease)
    }

    func resize(from texture: any MTLTexture,
                toWidth width: Int,
                toHeight height: Int,
                device: any MTLDevice) throws -> any MTLTexture {
        try outputPool.resize(from: texture,
                              toWidth: width,
                              toHeight: height,
                              device: device)
    }

    func hasLease(for texture: any MTLTexture) -> Bool {
        outputPool.hasLease(for: texture)
    }

    var estimatedBytes: Int {
        outputPool.estimatedBytes
    }

    var metadata: [VolumeResourceHandle.Metadata] {
        outputPool.metadata
    }

    var textureCount: Int {
        outputPool.textureCount
    }

    var inUseCount: Int {
        outputPool.inUseCount
    }

    // MARK: - Debug

    var debugTextureCount: Int {
        outputPool.debugTextureCount
    }

    func debugIsInUse(_ texture: any MTLTexture) -> Bool? {
        outputPool.debugIsInUse(texture)
    }

    var debugLeaseCount: Int {
        outputPool.debugLeaseCount
    }

    var debugLeaseAcquiredCount: Int {
        outputPool.debugLeaseAcquiredCount
    }

    var debugLeasePresentedCount: Int {
        outputPool.debugLeasePresentedCount
    }

    var debugLeaseReleasedCount: Int {
        outputPool.debugLeaseReleasedCount
    }

    var debugLeasePendingCount: Int {
        outputPool.debugLeasePendingCount
    }

    func debugReleaseUnknownLeaseTextureID() {
        outputPool.debugReleaseUnknownLeaseTextureID()
    }
}
