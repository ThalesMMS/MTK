import CoreGraphics
import simd
import XCTest

@testable import MTKCore

final class MetalVolumeRenderingAdapterExtendedTests: XCTestCase {
    private enum PixelReadError: Error {
        case coordinatesOutOfBounds
    }

    /// Rendering math reference test: validates clip bounds without exercising
    /// the production Metal-only adapter.
    func testReferenceRendererClipBoundsMaskingDropsPixelsOutsideBounds() throws {
        let dataset = makeTestDataset()
        var state = ExtendedRenderingState()

        let firstImage = TestCPURenderingHelper.makeReferenceImage(dataset: dataset,
                                                                   window: dataset.intensityRange,
                                                                   state: state)
        let firstPixel = try pixelValue(from: firstImage, x: dataset.dimensions.width - 1, y: 0)
        XCTAssertGreaterThan(firstPixel, 0, "Expected non-zero pixel before clipping")

        state.clipBounds = ClipBoundsSnapshot(xMin: 0, xMax: 0.25, yMin: 0, yMax: 1, zMin: 0, zMax: 1)
        let clippedImage = TestCPURenderingHelper.makeReferenceImage(dataset: dataset,
                                                                     window: dataset.intensityRange,
                                                                     state: state)
        let clippedPixel = try pixelValue(from: clippedImage, x: dataset.dimensions.width - 1, y: 0)
        XCTAssertEqual(clippedPixel, 0, "Clip bounds should zero out the far-right column")
    }

    /// Rendering math reference test: validates channel gains without relying on
    /// the production Metal-only adapter or a CPU runtime fallback.
    func testReferenceRendererChannelIntensityControlsDarkenAndBrightenImage() throws {
        let dataset = makeTestDataset()
        var state = ExtendedRenderingState()

        state.channelIntensities = SIMD4<Float>(0, 0, 0, 0)
        let darkImage = TestCPURenderingHelper.makeReferenceImage(dataset: dataset,
                                                                  window: dataset.intensityRange,
                                                                  state: state)
        let darkPixel = try pixelValue(from: darkImage, x: 0, y: 0)
        XCTAssertEqual(darkPixel, 0, "Zero channel intensity should produce a black pixel")

        state.channelIntensities = SIMD4<Float>(1, 1, 1, 1)
        let brightImage = TestCPURenderingHelper.makeReferenceImage(dataset: dataset,
                                                                    window: dataset.intensityRange,
                                                                    state: state)
        let brightPixel = try pixelValue(from: brightImage, x: 0, y: 0)
        XCTAssertGreaterThan(brightPixel, 0, "Restoring channel gain should brighten the pixel")
    }

    /// Test infrastructure guard: invalid test datasets should fail reference
    /// rendering instead of producing black images that look valid.
    func testReferenceRendererFailsWhenDatasetReaderCannotBeCreated() {
        let dataset = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        let image = TestCPURenderingHelper.makeReferenceImage(dataset: dataset,
                                                              window: 0...1,
                                                              state: ExtendedRenderingState())
        XCTAssertNil(image)
    }

    // MARK: - Helpers

    private func makeTestDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let values: [UInt16] = Array(repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
    }

    private func pixelValue(from image: CGImage?, x: Int, y: Int) throws -> UInt8 {
        let cgImage = try XCTUnwrap(image)
        guard x >= 0, x < cgImage.width, y >= 0, y < cgImage.height else {
            XCTFail("Pixel coordinates (\(x), \(y)) are outside image bounds \(cgImage.width)x\(cgImage.height)")
            throw PixelReadError.coordinatesOutOfBounds
        }
        guard let providerData = cgImage.dataProvider?.data else {
            throw XCTSkip("CGImage data provider missing")
        }
        let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
        let offset = y * cgImage.bytesPerRow + x
        return bytes[offset]
    }
}
