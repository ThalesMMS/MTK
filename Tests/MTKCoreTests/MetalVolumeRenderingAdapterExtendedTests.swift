import CoreGraphics
import simd
import XCTest

@testable import MTKCore

final class MetalVolumeRenderingAdapterExtendedTests: XCTestCase {

    func testClipBoundsMaskingDropsPixelsOutsideBounds() async throws {
        let adapter = MetalVolumeRenderingAdapter()
        let request = try makeRequest()

        let firstResult = try await adapter.renderImage(using: request)
        let firstPixel = try pixelValue(from: firstResult.cgImage, x: request.dataset.dimensions.width - 1, y: 0)
        XCTAssertGreaterThan(firstPixel, 0, "Expected non-zero pixel before clipping")

        try await adapter.updateClipBounds(xMin: 0, xMax: 0.25, yMin: 0, yMax: 1, zMin: 0, zMax: 1)
        let clippedResult = try await adapter.renderImage(using: request)
        let clippedPixel = try pixelValue(from: clippedResult.cgImage, x: request.dataset.dimensions.width - 1, y: 0)
        XCTAssertEqual(clippedPixel, 0, "Clip bounds should zero out the far-right column")
    }

    func testChannelIntensityControlsDarkenAndBrightenFallbackImage() async throws {
        let adapter = MetalVolumeRenderingAdapter()
        let request = try makeRequest()

        try await adapter.updateChannelIntensities([0, 0, 0, 0])
        let darkResult = try await adapter.renderImage(using: request)
        let darkPixel = try pixelValue(from: darkResult.cgImage, x: 0, y: 0)
        XCTAssertEqual(darkPixel, 0, "Zero channel intensity should produce a black pixel")

        try await adapter.updateChannelIntensities([1, 1, 1, 1])
        let brightResult = try await adapter.renderImage(using: request)
        let brightPixel = try pixelValue(from: brightResult.cgImage, x: 0, y: 0)
        XCTAssertGreaterThan(brightPixel, 0, "Restoring channel gain should brighten the pixel")
    }

    // MARK: - Helpers

    private func makeRequest() throws -> VolumeRenderRequest {
        let dataset = makeTestDataset()
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
                colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(1, 1, 1, 1))]
            ),
            viewportSize: CGSize(width: dataset.dimensions.width, height: dataset.dimensions.height),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: Float(45)
            ),
            samplingDistance: 1 / 512,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

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
        XCTAssertGreaterThan(x, -1)
        XCTAssertGreaterThan(y, -1)
        XCTAssertLessThan(x, cgImage.width)
        XCTAssertLessThan(y, cgImage.height)
        guard let providerData = cgImage.dataProvider?.data else {
            throw XCTSkip("CGImage data provider missing")
        }
        let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
        let offset = y * cgImage.bytesPerRow + x
        return bytes[offset]
    }
}
