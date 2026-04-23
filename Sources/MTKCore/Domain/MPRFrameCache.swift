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

    public func store(_ frame: MPRTextureFrame,
                      for key: Key,
                      signature: MPRFrameSignature) {
        entries[key] = Entry(frame: frame, signature: signature)
    }

    public func invalidate(_ key: Key) {
        entries[key] = nil
    }

    public func invalidateAll() {
        entries.removeAll()
    }

    public func storedFrame(for key: Key) -> MPRTextureFrame? {
        entries[key]?.frame
    }

    func storedSignature(for key: Key) -> MPRFrameSignature? {
        entries[key]?.signature
    }
}
