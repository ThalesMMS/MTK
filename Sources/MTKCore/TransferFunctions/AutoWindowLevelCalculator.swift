import Foundation

public struct AutoWindowLevelResult: Equatable, Sendable {
    public let window: Double
    public let level: Double
    public let lowerBound: Int32
    public let upperBound: Int32

    public init(window: Double, level: Double, lowerBound: Int32, upperBound: Int32) {
        self.window = window
        self.level = level
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public enum AutoWindowLevelCalculator {
    public static func calculate(
        dataset: VolumeDataset,
        sliceIndex: Int? = nil,
        axis: Axis = .axial,
        lowerPercentile: Double = 0.02,
        upperPercentile: Double = 0.98,
        maximumSampleCount: Int = 1_000_000
    ) -> AutoWindowLevelResult? {
        let voxelCount = dataset.dimensions.voxelCount
        guard voxelCount > 0,
              dataset.data.count == voxelCount * dataset.pixelFormat.bytesPerVoxel else {
            return nil
        }

        let selectedSliceIndices: [Int]?
        if let sliceIndex {
            guard let resolvedSliceIndices = sliceIndices(
                dimensions: dataset.dimensions,
                axis: axis,
                sliceIndex: sliceIndex
            ) else {
                return nil
            }
            selectedSliceIndices = resolvedSliceIndices
        } else {
            selectedSliceIndices = nil
        }

        let upperSampleLimit = max(maximumSampleCount, 1)
        let candidateCount = sliceIndex == nil
            ? voxelCount
            : sliceVoxelCount(dimensions: dataset.dimensions, axis: axis)
        let samplingStride = max(1, Int(ceil(Double(candidateCount) / Double(upperSampleLimit))))
        var samples = [Int32]()
        samples.reserveCapacity(min(candidateCount, upperSampleLimit))

        dataset.data.withUnsafeBytes { rawBuffer in
            let storedValues = rawBuffer.bindMemory(to: UInt16.self)
            func appendSample(at voxelIndex: Int) {
                let storedValue = UInt16(littleEndian: storedValues[voxelIndex])
                switch dataset.pixelFormat {
                case .int16Signed:
                    let value = Int16(bitPattern: storedValue)
                    guard value != .min else { return }
                    samples.append(Int32(value))
                case .int16Unsigned:
                    guard storedValue != .max else { return }
                    samples.append(Int32(storedValue))
                }
            }

            if let selectedSliceIndices {
                for offset in stride(from: 0, to: selectedSliceIndices.count, by: samplingStride) {
                    appendSample(at: selectedSliceIndices[offset])
                }
            } else {
                for voxelIndex in stride(from: 0, to: voxelCount, by: samplingStride) {
                    appendSample(at: voxelIndex)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        let lowIndex = percentileIndex(count: samples.count, probability: lowerPercentile)
        let highIndex = percentileIndex(count: samples.count, probability: upperPercentile)
        let low = quickSelect(&samples, index: lowIndex)
        let high = quickSelect(&samples, index: highIndex)
        let width = max(Double(high - low), 1)
        return AutoWindowLevelResult(
            window: width,
            level: Double(low) + width / 2,
            lowerBound: low,
            upperBound: high
        )
    }

    private static func sliceIndices(
        dimensions: VolumeDimensions,
        axis: Axis,
        sliceIndex: Int
    ) -> [Int]? {
        let width = dimensions.width
        let height = dimensions.height
        let depth = dimensions.depth
        guard width > 0, height > 0, depth > 0 else { return nil }

        switch axis {
        case .axial:
            guard (0..<depth).contains(sliceIndex) else { return nil }
            let start = sliceIndex * width * height
            return Array(start..<(start + width * height))
        case .coronal:
            guard (0..<height).contains(sliceIndex) else { return nil }
            return (0..<depth).flatMap { z in
                (0..<width).map { x in (z * height + sliceIndex) * width + x }
            }
        case .sagittal:
            guard (0..<width).contains(sliceIndex) else { return nil }
            return (0..<depth).flatMap { z in
                (0..<height).map { y in (z * height + y) * width + sliceIndex }
            }
        }
    }

    private static func sliceVoxelCount(dimensions: VolumeDimensions, axis: Axis) -> Int {
        switch axis {
        case .axial:
            dimensions.width * dimensions.height
        case .coronal:
            dimensions.width * dimensions.depth
        case .sagittal:
            dimensions.height * dimensions.depth
        }
    }

    private static func percentileIndex(count: Int, probability: Double) -> Int {
        guard count > 1 else { return 0 }
        let clampedProbability = min(max(probability, 0), 1)
        return min(max(Int((Double(count - 1) * clampedProbability).rounded(.down)), 0), count - 1)
    }

    private static func quickSelect(_ values: inout [Int32], index: Int) -> Int32 {
        var low = 0
        var high = values.count - 1
        while low < high {
            let equalRange = partition(&values, low: low, high: high, pivot: values[(low + high) / 2])
            if index < equalRange.lowerBound {
                high = equalRange.lowerBound - 1
            } else if index > equalRange.upperBound {
                low = equalRange.upperBound + 1
            } else {
                return values[index]
            }
        }
        return values[low]
    }

    private static func partition(
        _ values: inout [Int32],
        low: Int,
        high: Int,
        pivot: Int32
    ) -> ClosedRange<Int> {
        var lessThan = low
        var current = low
        var greaterThan = high
        while current <= greaterThan {
            if values[current] < pivot {
                values.swapAt(lessThan, current)
                lessThan += 1
                current += 1
            } else if values[current] > pivot {
                values.swapAt(current, greaterThan)
                greaterThan -= 1
            } else {
                current += 1
            }
        }
        return lessThan...greaterThan
    }
}
