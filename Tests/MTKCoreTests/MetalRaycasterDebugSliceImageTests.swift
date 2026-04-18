//
//  MetalRaycasterDebugSliceImageTests.swift
//  MTK
//
//  Unit tests for MetalRaycaster+DebugSliceImage.swift.
//  Covers makeDebugSliceImage(dataset:slice:) — the CPU-based axial-slice
//  extraction and grayscale-mapping utility.
//

import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import MTKCore

// MARK: - MetalRaycasterDebugSliceImageTests

final class MetalRaycasterDebugSliceImageTests: XCTestCase {

    private var raycaster: MetalRaycaster!

    override func setUpWithError() throws {
        try super.setUpWithError()
        raycaster = try makeRaycaster()
    }

    // MARK: - Happy-path: image is created

    func testReturnsNonNilCGImageForUnsignedInt16Dataset() {
        let dataset = makeDataset(pixelFormat: .int16Unsigned)
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertNotNil(image, "Expected a CGImage for a valid int16Unsigned dataset")
    }

    func testReturnsNonNilCGImageForSignedInt16Dataset() {
        let dataset = makeDataset(pixelFormat: .int16Signed)
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertNotNil(image, "Expected a CGImage for a valid int16Signed dataset")
    }

    // MARK: - Image dimensions

    func testImageWidthMatchesDatasetWidth() {
        let dimensions = VolumeDimensions(width: 8, height: 12, depth: 4)
        let dataset = makeDataset(dimensions: dimensions)
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertEqual(image?.width, 8, "Image width should match dataset width")
    }

    func testImageHeightMatchesDatasetHeight() {
        let dimensions = VolumeDimensions(width: 8, height: 12, depth: 4)
        let dataset = makeDataset(dimensions: dimensions)
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertEqual(image?.height, 12, "Image height should match dataset height")
    }

    func testImageDimensionsMatchNonSquareDataset() {
        let dimensions = VolumeDimensions(width: 16, height: 32, depth: 8)
        let dataset = makeDataset(dimensions: dimensions)
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertEqual(image?.width, 16)
        XCTAssertEqual(image?.height, 32)
    }

    // MARK: - Slice index selection

    func testDefaultNilIndexUsesMiddleSlice() {
        // Build a 4×4×4 dataset where each Z slice has a distinct uniform value.
        // Slice depth/2 = 2 should have value 200 (mapped near white).
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            // Slice 0→100, 1→200, 2→300 (middle), 3→400
            sliceValues: [100, 200, 300, 400]
        )
        let defaultImage = raycaster.makeDebugSliceImage(dataset: dataset)
        let explicitMiddleImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 2)

        // Both should be identical — default nil uses depth/2 = 2
        guard let defaultImage,
              let explicitMiddleImage else {
            XCTFail("Expected default and explicit middle slice images")
            return
        }
        guard let pixels1 = extractGrayscalePixels(from: defaultImage),
              let pixels2 = extractGrayscalePixels(from: explicitMiddleImage) else {
            XCTFail("Failed to extract pixels from default or explicit middle slice image")
            return
        }
        XCTAssertEqual(pixels1, pixels2,
                       "nil slice index should produce the same result as explicit depth/2 index")
    }

    func testExplicitSliceZeroSelectsFirstSlice() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            sliceValues: [0, 1000, 2000, 3000]
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        // Slice 0 has all voxels = 0 (the minimum of intensityRange), should map to black (0)
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 },
                      "Slice 0 (all voxels = 0) should produce all-black pixels")
    }

    func testExplicitSliceLastIndexSelectsLastSlice() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        // Make last slice (index 3) have max value (4095 for unsigned)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            sliceValues: [0, 1000, 2000, 4095]
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 3),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        // Slice 3 has all voxels = 4095 = intensityRange.upperBound → should be white (255)
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 },
                      "Slice 3 (all voxels = intensityRange.upperBound) should produce all-white pixels")
    }

    // MARK: - Index clamping

    func testNegativeSliceIndexClampsToFirstSlice() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            sliceValues: [0, 1000, 2000, 3000]
        )
        let clampedImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: -1)
        let zeroImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0)

        guard let clampedImage,
              let zeroImage else {
            XCTFail("Expected clamped and zero-index slice images")
            return
        }
        guard let p1 = extractGrayscalePixels(from: clampedImage),
              let p2 = extractGrayscalePixels(from: zeroImage) else {
            XCTFail("Failed to extract pixels from clamped or zero-index slice image")
            return
        }
        XCTAssertEqual(p1, p2,
                       "Negative index (-1) should clamp to slice 0")
    }

    func testLargeSliceIndexClampsToLastSlice() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            sliceValues: [0, 1000, 2000, 3000]
        )
        let clampedImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 999)
        let lastImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 3)

        guard let clampedImage,
              let lastImage else {
            XCTFail("Expected clamped and last slice images")
            return
        }
        guard let p1 = extractGrayscalePixels(from: clampedImage),
              let p2 = extractGrayscalePixels(from: lastImage) else {
            XCTFail("Failed to extract pixels from clamped or last slice image")
            return
        }
        XCTAssertEqual(p1, p2,
                       "Out-of-bounds index (999) should clamp to last slice (depth-1)")
    }

    func testIndexEqualToDepthClampsToLastSlice() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dimensions,
            sliceValues: [0, 1000, 2000, 3000]
        )
        let clampedImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 4) // depth == 4
        let lastImage = raycaster.makeDebugSliceImage(dataset: dataset, slice: 3)

        guard let clampedImage,
              let lastImage else {
            XCTFail("Expected clamped and last slice images")
            return
        }
        guard let p1 = extractGrayscalePixels(from: clampedImage),
              let p2 = extractGrayscalePixels(from: lastImage) else {
            XCTFail("Failed to extract pixels from clamped or last slice image")
            return
        }
        XCTAssertEqual(p1, p2,
                       "Index equal to depth should clamp to depth-1")
    }

    // MARK: - Intensity normalisation

    func testUnsignedInt16VoxelAtMinIntensityMapsToBlack() {
        // Create a uniform dataset with all voxels = intensityRange.lowerBound
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 0...4095
        // All voxels = 0 (= range.lowerBound)
        let values: [UInt16] = Array(repeating: 0, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 },
                      "Voxels at intensityRange.lowerBound should map to pixel value 0 (black)")
    }

    func testUnsignedInt16VoxelAtMaxIntensityMapsToWhite() {
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 0...4095
        // All voxels = 4095 (= range.upperBound)
        let values: [UInt16] = Array(repeating: 4095, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 },
                      "Voxels at intensityRange.upperBound should map to pixel value 255 (white)")
    }

    func testSignedInt16VoxelAtMinIntensityMapsToBlack() {
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = -1024...3071
        // All voxels = -1024 (= range.lowerBound for signed)
        let values: [Int16] = Array(repeating: -1024, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 },
                      "Signed int16 voxels at intensityRange.lowerBound should map to 0 (black)")
    }

    func testSignedInt16VoxelAtMaxIntensityMapsToWhite() {
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = -1024...3071
        // All voxels = 3071 (= range.upperBound for signed)
        let values: [Int16] = Array(repeating: 3071, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 },
                      "Signed int16 voxels at intensityRange.upperBound should map to 255 (white)")
    }

    func testMidpointIntensityMapsToApproximatelyGray() {
        // A value at the middle of the range should produce ~127-128.
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 0...510  // midpoint = 255
        let midValue: UInt16 = 255
        let values: [UInt16] = Array(repeating: midValue, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        // 255/510 * 255 ≈ 127.5 → 127
        XCTAssertTrue(pixels.allSatisfy { $0 >= 126 && $0 <= 129 },
                      "Midpoint intensity should map near the mid grayscale value")
    }

    // MARK: - Edge cases

    func testSingleVoxelDataset() {
        let dims = VolumeDimensions(width: 1, height: 1, depth: 1)
        let values: [UInt16] = [2048]
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
        let image = raycaster.makeDebugSliceImage(dataset: dataset)
        XCTAssertNotNil(image, "1×1×1 dataset should produce a valid CGImage")
        XCTAssertEqual(image?.width, 1)
        XCTAssertEqual(image?.height, 1)
    }

    func testIntensityRangeCollapse_doesNotCrash() {
        // When min == max, span = max(0, 1) = 1 — should not divide by zero.
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 1000...1000  // span = 0, protected by max(..., 1)
        let values: [UInt16] = Array(repeating: 1000, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        // Must not crash and should return a valid image
        let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0)
        XCTAssertNotNil(image, "Collapsed intensity range (min==max) should still produce a CGImage")
    }

    func testMismatchedVoxelBufferReturnsNil() {
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let values: [UInt16] = [1000]
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...4095
        )

        let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0)
        XCTAssertNil(image, "Mismatched voxel buffers should fail before typed buffer indexing")
    }

    func testDifferentSlicesProduceDifferentPixelData() {
        // Two distinct slices in the same dataset should yield different images.
        let dims = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeDatasetWithDistinctSlices(
            dimensions: dims,
            sliceValues: [0, 1000, 2000, 4095]
        )
        guard let imageA = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let imageB = raycaster.makeDebugSliceImage(dataset: dataset, slice: 3),
              let pixelsA = extractGrayscalePixels(from: imageA),
              let pixelsB = extractGrayscalePixels(from: imageB) else {
            XCTFail("Failed to generate or extract images")
            return
        }
        XCTAssertNotEqual(pixelsA, pixelsB,
                          "Different slices (0 vs 3) should produce different pixel data")
    }

    func testVoxelsBelowIntensityMinClampToBlack() {
        // Voxels below intensityRange.lowerBound should be clamped to 0 via simd_clamp.
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 1000...2000
        // All voxels = 500, which is below the range minimum → normalized < 0 → clamped to 0
        let values: [UInt16] = Array(repeating: 500, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 },
                      "Voxels below intensityRange.lowerBound should clamp to 0 (black)")
    }

    func testVoxelsAboveIntensityMaxClampToWhite() {
        // Voxels above intensityRange.upperBound should be clamped to 255 via simd_clamp.
        let dims = VolumeDimensions(width: 4, height: 4, depth: 2)
        let range: ClosedRange<Int32> = 0...1000
        // All voxels = 2000, which is above range.upperBound → normalized > 1 → clamped to 1 → 255
        let values: [UInt16] = Array(repeating: 2000, count: dims.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: range
        )
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset, slice: 0),
              let pixels = extractGrayscalePixels(from: image) else {
            XCTFail("Failed to generate or extract image")
            return
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 },
                      "Voxels above intensityRange.upperBound should clamp to 255 (white)")
    }

    func testImageIs8BitGrayscale() {
        let dataset = makeDataset()
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset) else {
            XCTFail("Expected a CGImage")
            return
        }
        XCTAssertEqual(image.bitsPerComponent, 8, "Image should be 8-bit per channel")
        XCTAssertEqual(image.bitsPerPixel, 8, "Image should be 8 bits per pixel (grayscale)")
        XCTAssertEqual(image.bytesPerRow, image.width, "Grayscale bytesPerRow should equal width")
    }

    func testImageColorSpaceIsDeviceGray() {
        let dataset = makeDataset()
        guard let image = raycaster.makeDebugSliceImage(dataset: dataset) else {
            XCTFail("Expected a CGImage")
            return
        }
        let model = image.colorSpace?.model
        XCTAssertEqual(model, .monochrome, "Image color space should be monochrome (device gray)")
    }
}

// MARK: - Private helpers

extension MetalRaycasterDebugSliceImageTests {

    private func makeRaycaster() throws -> MetalRaycaster {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        do {
            return try MetalRaycaster(device: device)
        } catch let error as MetalRaycaster.Error {
            throw XCTSkip("MetalRaycaster unavailable: \(error)")
        }
    }

    /// Creates a basic test dataset with uniform voxels and sensible defaults.
    private func makeDataset(
        dimensions: VolumeDimensions = VolumeDimensions(width: 8, height: 8, depth: 8),
        pixelFormat: VolumePixelFormat = .int16Unsigned
    ) -> VolumeDataset {
        let data: Data
        switch pixelFormat {
        case .int16Unsigned:
            data = Array(repeating: UInt16(2048), count: dimensions.voxelCount).withUnsafeBytes { Data($0) }
        case .int16Signed:
            data = Array(repeating: Int16(0), count: dimensions.voxelCount).withUnsafeBytes { Data($0) }
        }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: pixelFormat
        )
    }

    /// Creates a dataset where each Z slice has a uniform, distinct voxel value.
    ///
    /// Uses `int16Unsigned` format. The dataset's intensity range is set to `0...max(sliceValues)`.
    ///
    /// - Parameters:
    ///   - dimensions: Volume dimensions. `sliceValues.count` must equal `dimensions.depth`.
    ///   - sliceValues: One UInt16 value per slice; used as the uniform intensity for that slice.
    private func makeDatasetWithDistinctSlices(
        dimensions: VolumeDimensions,
        sliceValues: [UInt16]
    ) -> VolumeDataset {
        precondition(sliceValues.count == dimensions.depth)
        let voxelsPerSlice = dimensions.width * dimensions.height
        var values: [UInt16] = Array(repeating: 0, count: dimensions.voxelCount)
        for (sliceIdx, sliceValue) in sliceValues.enumerated() {
            let start = sliceIdx * voxelsPerSlice
            values.replaceSubrange(start..<(start + voxelsPerSlice), with: repeatElement(sliceValue, count: voxelsPerSlice))
        }
        let data = values.withUnsafeBytes { Data($0) }
        let maxValue = Int32(sliceValues.max() ?? 0)
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...maxValue
        )
    }

    /// Extracts the raw 8-bit grayscale pixel values from a CGImage by drawing
    /// it into a known-format CGContext.
    private func extractGrayscalePixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return pixels
    }
}
