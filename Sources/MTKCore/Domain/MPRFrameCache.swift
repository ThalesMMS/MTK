//
//  MPRFrameCache.swift
//  MTKCore
//
//  Shared bookkeeping for MPR frame reuse across engine and UI callers.
//

import Foundation

@MainActor
public final class MPRFrameCache<Key: Hashable>: @unchecked Sendable {
    private struct Entry {
        var frame: MPRTextureFrame
        var signature: MPRFrameSignature
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    public var entryCount: Int {
        entries.count
    }

    public func cachedFrame(for key: Key,
                            matching signature: MPRFrameSignature) -> MPRTextureFrame? {
        guard let entry = entries[key],
              entry.signature == signature else {
            return nil
        }
        return entry.frame
    }

    @discardableResult
    public func store(_ frame: MPRTextureFrame,
                      for key: Key,
                      signature: MPRFrameSignature) -> MPRTextureFrame {
        releaseStoredFrame(for: key, replacing: frame)
        var retainedFrame = frame
        retainedFrame.outputTextureLeaseRetainedByCache = retainedFrame.outputTextureLease != nil
        entries[key] = Entry(frame: retainedFrame, signature: signature)
        return retainedFrame
    }

    public func invalidate(_ key: Key) {
        entries[key]?.frame.releaseOutputTextureLeaseAfterPresentationCompletes()
        entries[key] = nil
    }

    public func invalidateAll() {
        for entry in entries.values {
            entry.frame.releaseOutputTextureLeaseAfterPresentationCompletes()
        }
        entries.removeAll()
    }

    public func storedFrame(for key: Key) -> MPRTextureFrame? {
        entries[key]?.frame
    }

    func storedSignature(for key: Key) -> MPRFrameSignature? {
        entries[key]?.signature
    }

    private func releaseStoredFrame(for key: Key, replacing frame: MPRTextureFrame) {
        guard let currentLease = entries[key]?.frame.outputTextureLease else {
            return
        }
        if let replacementLease = frame.outputTextureLease,
           currentLease === replacementLease {
            return
        }
        currentLease.releaseAfterPresentationCompletes()
    }
}
