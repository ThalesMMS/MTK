import Foundation

enum DatasetIdentity {
    /// Revalidates cached datasets by content so allocator address reuse cannot produce false hits.
    struct CachedContent: Sendable {
        let content: Content
        private let data: Data
        private let storage: Storage

        init(dataset: VolumeDataset) {
            self.content = Content(dataset: dataset)
            self.data = dataset.data
            self.storage = Storage(dataset: dataset)
        }

        func matches(dataset: VolumeDataset) -> Bool {
            guard Content(dataset: dataset) == content else { return false }
            let candidateStorage = Storage(dataset: dataset)
            if candidateStorage == storage {
                return true
            }
            return dataset.data == data
        }
    }

    struct Content: Hashable, Sendable {
        let byteCount: Int
        let dimensions: VolumeDimensions
        let pixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>
        let contentFingerprint: UInt64

        init(dataset: VolumeDataset) {
            self.init(
                byteCount: dataset.data.count,
                dimensions: dataset.dimensions,
                pixelFormat: dataset.pixelFormat,
                intensityRange: dataset.intensityRange,
                contentFingerprint: DatasetContentFingerprint.make(for: dataset.data)
            )
        }

        init(byteCount: Int,
             dimensions: VolumeDimensions,
             pixelFormat: VolumePixelFormat,
             intensityRange: ClosedRange<Int32>,
             contentFingerprint: UInt64) {
            self.byteCount = byteCount
            self.dimensions = dimensions
            self.pixelFormat = pixelFormat
            self.intensityRange = intensityRange
            self.contentFingerprint = contentFingerprint
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.byteCount == rhs.byteCount
                && lhs.dimensions == rhs.dimensions
                && lhs.pixelFormat == rhs.pixelFormat
                && lhs.intensityRange == rhs.intensityRange
                && lhs.contentFingerprint == rhs.contentFingerprint
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(byteCount)
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(pixelFormat.hashKey)
            hasher.combine(intensityRange.lowerBound)
            hasher.combine(intensityRange.upperBound)
            hasher.combine(contentFingerprint)
        }
    }

    struct Storage: Hashable, Sendable {
        let byteCount: Int
        let dimensions: VolumeDimensions
        let pixelFormat: VolumePixelFormat
        let baseAddress: UInt

        init(dataset: VolumeDataset) {
            self.byteCount = dataset.data.count
            self.dimensions = dataset.dimensions
            self.pixelFormat = dataset.pixelFormat
            self.baseAddress = dataset.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return UInt(bitPattern: baseAddress)
            }
        }

        static func == (lhs: Storage, rhs: Storage) -> Bool {
            lhs.byteCount == rhs.byteCount
                && lhs.dimensions == rhs.dimensions
                && lhs.pixelFormat == rhs.pixelFormat
                && lhs.baseAddress == rhs.baseAddress
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(byteCount)
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(pixelFormat.hashKey)
            hasher.combine(baseAddress)
        }
    }
}
