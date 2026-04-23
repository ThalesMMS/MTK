//
//  OutputTextureLease.swift
//  MTK
//
//  Explicit ownership token for pooled output textures.
//

import Foundation
@preconcurrency import Metal

public final class OutputTextureLease: @unchecked Sendable {
    private enum ReleaseOrigin {
        case explicit
        case deinitSafetyNet
    }

    public let texture: any MTLTexture

    let ownerPoolIdentifier: UUID
    let textureIdentifier: ObjectIdentifier
    let leaseIdentifier: UUID

    private let lock = NSLock()
    private let onPresented: @Sendable (OutputTextureLease) -> Void
    private let onRelease: @Sendable (OutputTextureLease) -> Void
    private var presented = false
    private var released = false

    init(texture: any MTLTexture,
         ownerPoolIdentifier: UUID,
         leaseIdentifier: UUID = UUID(),
         onPresented: @escaping @Sendable (OutputTextureLease) -> Void = { _ in },
         onRelease: @escaping @Sendable (OutputTextureLease) -> Void) {
        self.texture = texture
        self.ownerPoolIdentifier = ownerPoolIdentifier
        self.textureIdentifier = ObjectIdentifier(texture as AnyObject)
        self.leaseIdentifier = leaseIdentifier
        self.onPresented = onPresented
        self.onRelease = onRelease
    }

    public var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    @_spi(Testing)
    public var isPresented: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presented
    }

    public func markPresented() {
        let shouldNotify: Bool

        lock.lock()
        if released || presented {
            shouldNotify = false
        } else {
            presented = true
            shouldNotify = true
        }
        lock.unlock()

        if shouldNotify {
            onPresented(self)
        }
    }

    public func release() {
        release(origin: .explicit)
    }

    private func release(origin: ReleaseOrigin) {
        let shouldRelease: Bool

        lock.lock()
        if released {
            shouldRelease = false
        } else {
            released = true
            shouldRelease = true
        }
        lock.unlock()

        if shouldRelease {
            onRelease(self)
        }
    }

    deinit {
        guard !isReleased else {
            return
        }

        Logger.warning(
            "OutputTextureLease deinitialized without explicit release leaseID=\(leaseIdentifier.uuidString) textureID=\(String(describing: textureIdentifier))",
            category: "OutputTextureLease"
        )
        release(origin: .deinitSafetyNet)
    }
}
