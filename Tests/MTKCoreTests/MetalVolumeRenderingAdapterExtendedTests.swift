import CoreGraphics
import simd
import XCTest

@testable import MTKCore

final class MetalVolumeRenderingAdapterExtendedTests: XCTestCase {
    private enum PixelReadError: Error {
        case coordinatesOutOfBounds
    }

    func testChannelControlSnapshotReportsEverySupportedChannel() async throws {
        let adapter = try makeTestAdapter()

        try await adapter.setToneCurvePresetKey("auto.bone", forChannel: 2)
        try await adapter.setToneCurveGain(1.5, forChannel: 2)
        try await adapter.setToneCurveControlPoints([
            SIMD2<Float>(255, 1),
            SIMD2<Float>(0, 0)
        ], forChannel: 2)

        let snapshots = try await adapter.getChannelControlSnapshot()

        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(snapshots.map(\.channel), [0, 1, 2, 3])
        XCTAssertEqual(snapshots[0].presetKey, "default")
        XCTAssertEqual(snapshots[2].presetKey, "auto.bone")
        XCTAssertEqual(snapshots[2].gain, 1.5, accuracy: 1e-6)
        XCTAssertEqual(snapshots[2].controlPoints, [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 1)
        ])
    }

    func testToneCurveControlsRejectUnsupportedChannels() async throws {
        let adapter = try makeTestAdapter()

        await XCTAssertThrowsAsync(
            try await adapter.setToneCurveGain(1, forChannel: 4),
            expecting: MetalVolumeRenderingAdapter.AdapterError.invalidToneCurveChannel(4)
        )
        await XCTAssertThrowsAsync(
            try await adapter.setToneCurveControlPoints([], forChannel: -1),
            expecting: MetalVolumeRenderingAdapter.AdapterError.invalidToneCurveChannel(-1)
        )
        await XCTAssertThrowsAsync(
            try await adapter.setToneCurvePresetKey("auto.lung", forChannel: 9),
            expecting: MetalVolumeRenderingAdapter.AdapterError.invalidToneCurveChannel(9)
        )
    }

    func testGetVolumeMetadataReturnsNilBeforeRender() async throws {
        let adapter = try makeTestAdapter()

        let metadata = try await adapter.getVolumeMetadata()

        XCTAssertNil(metadata)
    }

    func testGetVolumeMetadataReturnsDatasetGeometryAfterRender() async throws {
        let adapter = try makeTestAdapter()
        let dataset = makeGeometryMetadataDataset()

        _ = try await adapter.renderFrame(using: makeMetadataRequest(dataset: dataset))
        let metadataOptional = try await adapter.getVolumeMetadata()
        let metadata = try XCTUnwrap(metadataOptional)

        XCTAssertEqual(metadata.dimensions, SIMD3<Int32>(4, 5, 6))
        XCTAssertEqual(metadata.spacing.x, 0.7, accuracy: 1e-6)
        XCTAssertEqual(metadata.spacing.y, 1.3, accuracy: 1e-6)
        XCTAssertEqual(metadata.spacing.z, 2.5, accuracy: 1e-6)
        XCTAssertEqual(metadata.origin, SIMD3<Float>(12, -8, 30))
        assertMatrix(metadata.orientation, dataset.imageData.direction)
        XCTAssertEqual(metadata.intensityRange, -200...800)
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

    private func makeGeometryMetadataDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 5, depth: 6)
        let values: [Int16] = Array(repeating: 200, count: dimensions.voxelCount)
        let orientation = VolumeOrientation(row: SIMD3<Float>(0, 1, 0),
                                            column: SIMD3<Float>(-1, 0, 0),
                                            origin: SIMD3<Float>(12, -8, 30))
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.7, y: 1.3, z: 2.5),
            pixelFormat: .int16Signed,
            intensityRange: -200...800,
            orientation: orientation,
            recommendedWindow: -200...800
        )
    }

    private func makeMetadataRequest(dataset: VolumeDataset) -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction.defaultGrayscale(for: dataset),
            viewportSize: CGSize(width: 32, height: 32),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0.5, 0.5, 3),
                target: SIMD3<Float>(repeating: 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1.0 / 64.0,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    private func assertMatrix(_ actual: simd_float3x3,
                              _ expected: simd_float3x3,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        for column in 0..<3 {
            XCTAssertEqual(actual[column].x, expected[column].x, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(actual[column].y, expected[column].y, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(actual[column].z, expected[column].z, accuracy: 1e-6, file: file, line: line)
        }
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
