import Foundation

@testable import MTKCore

enum TestHelperError: Error {
    case sharedDataAllocationFailed(byteCount: Int)
}

enum VolumeDatasetTestFactory {
    static func makeTestDataset(data overrideData: Data? = nil,
                                dimensions: VolumeDimensions = VolumeDimensions(width: 64, height: 64, depth: 64),
                                spacing: VolumeSpacing = VolumeSpacing(x: 1.0, y: 1.0, z: 1.0),
                                pixelFormat: VolumePixelFormat = .int16Unsigned,
                                orientation: VolumeOrientation = .canonical,
                                seed: Int = 0) -> VolumeDataset {
        let expectedSize = dimensions.voxelCount * pixelFormat.bytesPerVoxel
        let data: Data
        if let overrideData {
            precondition(
                overrideData.count == expectedSize,
                "Override data size mismatch: expected \(expectedSize) bytes, got \(overrideData.count)"
            )
            data = overrideData
        } else {
            switch pixelFormat {
            case .int16Signed:
                let values: [Int16] = (0..<dimensions.voxelCount).map {
                    Int16((($0 + seed) % 2048) - 1024)
                }
                data = values.withUnsafeBytes { Data($0) }
            case .int16Unsigned:
                let values: [UInt16] = (0..<dimensions.voxelCount).map { index in
                    UInt16(normalizedModulo(seed + index, modulus: 4096))
                }
                data = values.withUnsafeBytes { Data($0) }
            }
        }

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            orientation: orientation
        )
    }

    static func makeDataChangedDataset(from dataset: VolumeDataset) -> VolumeDataset {
        var mutatedDataset = dataset
        validateDataSize(
            dataset.data.count,
            expected: dataset.voxelCount * dataset.pixelFormat.bytesPerVoxel,
            context: "Dataset data"
        )

        switch dataset.pixelFormat {
        case .int16Signed:
            var mutatedValues = Array(repeating: Int16.zero, count: dataset.voxelCount)
            _ = mutatedValues.withUnsafeMutableBytes { mutableBytes in
                dataset.data.copyBytes(to: mutableBytes)
            }
            if let firstValue = mutatedValues.first {
                mutatedValues[0] = firstValue &+ 1
            }
            mutatedDataset.data = mutatedValues.withUnsafeBytes { Data($0) }

        case .int16Unsigned:
            var mutatedValues = Array(repeating: UInt16.zero, count: dataset.voxelCount)
            _ = mutatedValues.withUnsafeMutableBytes { mutableBytes in
                dataset.data.copyBytes(to: mutableBytes)
            }
            if let firstValue = mutatedValues.first {
                mutatedValues[0] = firstValue &+ 1
            }
            mutatedDataset.data = mutatedValues.withUnsafeBytes { Data($0) }
        }

        return mutatedDataset
    }

    /// Returns `data` backed by `storage.mutableBytes` with a `.none` deallocator.
    /// Callers must retain the returned `storage` for the full lifetime of `data`.
    static func makeSharedTestData(dimensions: VolumeDimensions = VolumeDimensions(width: 64, height: 64, depth: 64),
                                   pixelFormat: VolumePixelFormat = .int16Unsigned,
                                   seed: Int = 0) throws -> (data: Data, storage: NSMutableData) {
        let byteCount = dimensions.voxelCount * pixelFormat.bytesPerVoxel
        guard let storage = NSMutableData(length: byteCount) else {
            throw TestHelperError.sharedDataAllocationFailed(byteCount: byteCount)
        }

        switch pixelFormat {
        case .int16Signed:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: Int16.self)
            for index in 0..<dimensions.voxelCount {
                pointer[index] = Int16((index + seed) % 2048 - 1024)
            }
        case .int16Unsigned:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: UInt16.self)
            for index in 0..<dimensions.voxelCount {
                pointer[index] = UInt16(normalizedModulo(seed + index, modulus: 4096))
            }
        }

        let data = Data(bytesNoCopy: storage.mutableBytes,
                        count: byteCount,
                        deallocator: .none)
        return (data: data, storage: storage)
    }

    static func mutateSharedTestDataInPlace(_ storage: NSMutableData,
                                            pixelFormat: VolumePixelFormat) {
        switch pixelFormat {
        case .int16Signed:
            guard storage.length >= MemoryLayout<Int16>.stride else {
                return
            }
            let pointer = storage.mutableBytes.assumingMemoryBound(to: Int16.self)
            pointer[0] = pointer[0] &+ 1
        case .int16Unsigned:
            guard storage.length >= MemoryLayout<UInt16>.stride else {
                return
            }
            let pointer = storage.mutableBytes.assumingMemoryBound(to: UInt16.self)
            pointer[0] = pointer[0] &+ 1
        }
    }

    private static func normalizedModulo(_ value: Int,
                                         modulus: Int) -> Int {
        let raw = value % modulus
        return (raw + modulus) % modulus
    }

    private static func validateDataSize(_ actualSize: Int,
                                         expected expectedSize: Int,
                                         context: String) {
        precondition(
            actualSize == expectedSize,
            "\(context) size mismatch: expected \(expectedSize) bytes, got \(actualSize)"
        )
    }
}
