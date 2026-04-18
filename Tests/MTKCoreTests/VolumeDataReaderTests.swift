import Foundation
import XCTest

@testable import MTKCore

/// Tests for `VolumeDataReader` initialization, especially the buffer-size
/// validation added in this PR (buffer.count >= expectedByteCount).
final class VolumeDataReaderTests: XCTestCase {

    // MARK: - Initialisation: buffer size validation

    func testInitSucceedsWhenBufferIsExactlyTheExpectedSize() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        // int16Unsigned → 2 bytes/voxel; 2×2×2 = 8 voxels → 16 bytes
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        let values = [UInt16](repeating: 1_000, count: dimensions.voxelCount)
        values.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNotNil(reader, "Reader should be created when buffer is exactly the expected size")
        }
    }

    func testInitSucceedsWhenBufferIsLargerThanExpected() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        // Provide more bytes than needed
        let values = [UInt16](repeating: 500, count: dimensions.voxelCount + 4)
        values.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNotNil(reader, "Reader should be created when buffer is larger than needed")
        }
    }

    func testInitFailsWhenBufferIsEmpty() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        let emptyData = Data()
        emptyData.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNil(reader, "Reader should fail when buffer is empty")
        }
    }

    func testInitFailsWhenBufferIsTooSmallByOneVoxel() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        let expectedBytes = dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
        // One byte short
        let tooSmall = Data(repeating: 0, count: expectedBytes - 1)
        tooSmall.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNil(reader, "Reader should fail when buffer is one byte short of expected size")
        }
    }

    func testInitFailsWhenBufferIsHalfTheRequiredSize() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Signed)
        let expectedBytes = dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
        let halfSize = Data(repeating: 0, count: expectedBytes / 2)
        halfSize.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNil(reader, "Reader should fail when buffer is half the required size")
        }
    }

    func testInitWorksWithSignedInt16Format() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Signed)
        let values = [Int16](repeating: -500, count: dimensions.voxelCount)
        values.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNotNil(reader, "Reader should be created for .int16Signed dataset with adequate buffer")
        }
    }

    func testInitWorksWithUnsignedInt16Format() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        let values = [UInt16](repeating: 2_000, count: dimensions.voxelCount)
        values.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNotNil(reader, "Reader should be created for .int16Unsigned dataset with adequate buffer")
        }
    }

    // MARK: - Dimensions are propagated correctly

    func testReaderDimensionsMatchDataset() {
        let dimensions = VolumeDimensions(width: 3, height: 5, depth: 7)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Signed)
        let values = [Int16](repeating: 0, count: dimensions.voxelCount)
        values.withUnsafeBytes { raw in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: raw) else {
                XCTFail("Expected successful reader initialisation")
                return
            }
            XCTAssertEqual(reader.width, 3)
            XCTAssertEqual(reader.height, 5)
            XCTAssertEqual(reader.depth, 7)
        }
    }

    // MARK: - Intensity reads

    func testIntensityAtCenterVoxelMatchesExpectedValue() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Signed)
        var values = [Int16](repeating: 0, count: dimensions.voxelCount)
        // Set a known value at (2, 2, 2)
        let linearIndex = 2 * 4 * 4 + 2 * 4 + 2
        values[linearIndex] = 1234
        values.withUnsafeBytes { raw in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: raw) else {
                XCTFail("Expected successful reader initialisation")
                return
            }
            XCTAssertEqual(reader.intensity(x: 2, y: 2, z: 2), 1234.0,
                           "Reader should return the correct voxel intensity")
        }
    }

    func testIntensityWithUnsignedFormatReadsCorrectly() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Unsigned)
        var values = [UInt16](repeating: 0, count: dimensions.voxelCount)
        values[0] = 65_000
        values.withUnsafeBytes { raw in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: raw) else {
                XCTFail("Expected successful reader initialisation")
                return
            }
            XCTAssertEqual(reader.intensity(x: 0, y: 0, z: 0), 65_000.0,
                           "Reader should return unsigned voxel value as Float")
        }
    }

    // MARK: - Regression: empty Data with non-zero declared dimensions fails

    func testEmptyDataWithNonZeroDimensionsFails() {
        // Regression: previously only checked for non-nil baseAddress; now also
        // validates buffer.count >= expectedByteCount.
        let dimensions = VolumeDimensions(width: 1, height: 1, depth: 1)
        let dataset = makeDataset(dimensions: dimensions, pixelFormat: .int16Signed)
        let emptyData = Data()
        emptyData.withUnsafeBytes { raw in
            let reader = VolumeDataReader(dataset: dataset, buffer: raw)
            XCTAssertNil(reader, "Empty buffer with non-zero declared dimensions should fail initialisation")
        }
    }

    // MARK: - Helpers

    private func makeDataset(
        dimensions: VolumeDimensions,
        pixelFormat: VolumePixelFormat,
        recommendedWindow: ClosedRange<Int32>? = 0...4095
    ) -> VolumeDataset {
        VolumeDataset(
            data: Data(),          // Placeholder — tests supply their own buffers
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: pixelFormat,
            recommendedWindow: recommendedWindow
        )
    }
}
