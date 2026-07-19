import Metal

struct TransferTextureLRU<Key: Hashable> {
    let capacity: Int
    private var textures: [Key: any MTLTexture] = [:]
    private var recency: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        textures.count
    }

    mutating func texture(for key: Key) -> (any MTLTexture)? {
        guard let texture = textures[key] else { return nil }
        markRecentlyUsed(key)
        return texture
    }

    mutating func insert(_ texture: any MTLTexture, for key: Key) {
        textures[key] = texture
        markRecentlyUsed(key)
        while textures.count > capacity, let leastRecent = recency.first {
            recency.removeFirst()
            textures.removeValue(forKey: leastRecent)
        }
    }

    mutating func removeAll() {
        textures.removeAll()
        recency.removeAll()
    }

    private mutating func markRecentlyUsed(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}
