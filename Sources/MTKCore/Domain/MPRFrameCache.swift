//
//  MPRFrameCache.swift
//  MTKCore
//
//  Shared bookkeeping for MPR frame reuse across engine and UI callers.
//

import Foundation

public final class MPRFrameCache<Key: Hashable>: @unchecked Sendable {
    private struct Entry {
        var frame: MPRTextureFrame
        var signature: MPRFrameSignature
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init() {}

    public var entryCount: Int {
        withLock { entries.count }
    }

    public func cachedFrame(for key: Key,
                            matching signature: MPRFrameSignature) -> MPRTextureFrame? {
        withLock {
            guard let entry = entries[key],
                  entry.signature == signature else {
                return nil
            }
            return entry.frame
        }
    }

    @discardableResult
    public func store(_ frame: MPRTextureFrame,
                      for key: Key,
                      signature: MPRFrameSignature) -> MPRTextureFrame {
        var retainedFrame = frame
        retainedFrame.outputTextureLeaseRetainedByCache = retainedFrame.outputTextureLease != nil
        let replacedLease = withLock {
            let replacedLease = outputTextureLeaseToRelease(for: key, replacing: retainedFrame)
            entries[key] = Entry(frame: retainedFrame, signature: signature)
            return replacedLease
        }
        replacedLease?.releaseAfterPresentationCompletes()
        return retainedFrame
    }

    public func invalidate(_ key: Key) {
        let removedFrame = withLock { entries.removeValue(forKey: key)?.frame }
        removedFrame?.releaseOutputTextureLeaseAfterPresentationCompletes()
    }

    public func invalidateAll() {
        let removedFrames = withLock {
            let frames = entries.values.map(\.frame)
            entries.removeAll()
            return frames
        }
        for frame in removedFrames {
            frame.releaseOutputTextureLeaseAfterPresentationCompletes()
        }
    }

    public func storedFrame(for key: Key) -> MPRTextureFrame? {
        withLock { entries[key]?.frame }
    }

    func storedSignature(for key: Key) -> MPRFrameSignature? {
        withLock { entries[key]?.signature }
    }

    private func outputTextureLeaseToRelease(for key: Key,
                                             replacing frame: MPRTextureFrame) -> OutputTextureLease? {
        guard let currentLease = entries[key]?.frame.outputTextureLease else {
            return nil
        }
        if let replacementLease = frame.outputTextureLease,
           currentLease === replacementLease {
            return nil
        }
        return currentLease
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
