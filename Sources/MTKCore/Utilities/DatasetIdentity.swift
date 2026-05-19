import Foundation

enum DatasetIdentity {
    struct Content: Hashable, Sendable {
        let byteCount: Int
        let dimensions: VolumeDimensions
        let pixelFormat: VolumePixelFormat
        let contentFingerprint: UInt64

        init(dataset: VolumeDataset) {
            self.init(
                byteCount: dataset.data.count,
                dimensions: dataset.dimensions,
                pixelFormat: dataset.pixelFormat,
                contentFingerprint: DatasetContentFingerprint.make(for: dataset.data)
            )
        }

        init(byteCount: Int,
             dimensions: VolumeDimensions,
             pixelFormat: VolumePixelFormat,
             contentFingerprint: UInt64) {
            self.byteCount = byteCount
            self.dimensions = dimensions
            self.pixelFormat = pixelFormat
            self.contentFingerprint = contentFingerprint
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.byteCount == rhs.byteCount
                && lhs.dimensions == rhs.dimensions
                && lhs.pixelFormat == rhs.pixelFormat
                && lhs.contentFingerprint == rhs.contentFingerprint
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(byteCount)
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(pixelFormat.hashKey)
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
