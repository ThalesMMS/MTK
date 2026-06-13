//
//  OutputTextureLease.swift
//  MTK
//
//  Explicit ownership token for pooled output textures.
//

import Foundation
@preconcurrency import Metal

package final class OutputTextureLease: @unchecked Sendable {
    private enum ReleaseOrigin {
        case explicit
        case deinitSafetyNet
    }

    package let texture: any MTLTexture

    package let ownerPoolIdentifier: UUID
    package let textureIdentifier: ObjectIdentifier
    package let leaseIdentifier: UUID

    private let lock = NSLock()
    private let onPresented: @Sendable (OutputTextureLease) -> Void
    private let onRelease: @Sendable (OutputTextureLease) -> Void
    package let debugSlotID: Int?
    private var debugFrameIndexStorage: UInt64?
    private var debugPresentationTokenStorage: String?
    private var presented = false
    private var released = false
    private var releaseAfterPresentation = false

    init(texture: any MTLTexture,
         ownerPoolIdentifier: UUID,
         leaseIdentifier: UUID = UUID(),
         debugSlotID: Int? = nil,
         onPresented: @escaping @Sendable (OutputTextureLease) -> Void = { _ in },
         onRelease: @escaping @Sendable (OutputTextureLease) -> Void) {
        self.texture = texture
        self.ownerPoolIdentifier = ownerPoolIdentifier
        self.textureIdentifier = ObjectIdentifier(texture as AnyObject)
        self.leaseIdentifier = leaseIdentifier
        self.debugSlotID = debugSlotID
        self.onPresented = onPresented
        self.onRelease = onRelease
    }

    package var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    package var isPresented: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presented
    }

    package var debugFrameIndex: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return debugFrameIndexStorage
    }

    package var debugPresentationToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return debugPresentationTokenStorage
    }

    package func updateDebugContext(frameIndex: UInt64? = nil,
                                    presentationToken: String? = nil) {
        lock.lock()
        if let frameIndex {
            debugFrameIndexStorage = frameIndex
        }
        if let presentationToken {
            debugPresentationTokenStorage = presentationToken
        }
        lock.unlock()
    }

    package func markPresented() {
        let shouldNotify: Bool
        let shouldRelease: Bool

        lock.lock()
        if released || presented {
            shouldNotify = false
            shouldRelease = false
        } else {
            presented = true
            shouldNotify = true
            if releaseAfterPresentation {
                released = true
                shouldRelease = true
            } else {
                shouldRelease = false
            }
        }
        lock.unlock()

        if shouldNotify {
            onPresented(self)
        }
        if shouldRelease {
            onRelease(self)
        }
    }

    package func release() {
        release(origin: .explicit)
    }

    package func releaseAfterPresentationCompletes() {
        let shouldRelease: Bool

        lock.lock()
        if released {
            shouldRelease = false
        } else if presented {
            released = true
            shouldRelease = true
        } else {
            releaseAfterPresentation = true
            shouldRelease = false
        }
        lock.unlock()

        if shouldRelease {
            onRelease(self)
        }
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
