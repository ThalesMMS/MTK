import CoreGraphics
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class MetalVolumeRenderingAdapterAccelerationTests: XCTestCase {
    func test_frontToBackRender_matchesPreAccelerationGolden() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let adapter = try MetalVolumeRenderingAdapter(device: device)

        let frame = try await adapter.renderFrame(using: VolumeRenderRegressionFixture.request())
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let energy = try XCTUnwrap(rgbEnergy(in: image))

        XCTAssertEqual(Double(energy),
                       236_796,
                       accuracy: 236_796 * 0.02,
                       "DVR readback drifted from the pre-acceleration adapter golden")
    }

    func test_frontToBackRender_buildsAndReusesAccelerationForDataset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        guard await adapter.debugAccelerationAvailable else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }
        let request = VolumeRenderRegressionFixture.request()

        _ = try await adapter.renderFrame(using: request)
        let firstTextureOptional = await adapter.debugAccelerationCacheTexture
        let firstTexture = try XCTUnwrap(firstTextureOptional)
        let firstBuildCount = await adapter.debugAccelerationBuildCount
        let firstOptionValue = await adapter.debugLastRequestedOptionValue
        XCTAssertEqual(firstBuildCount, 1)
        XCTAssertNotEqual(firstOptionValue & VolumeRenderOptionBits.acceleration, 0)

        _ = try await adapter.renderFrame(using: request)
        let secondTextureOptional = await adapter.debugAccelerationCacheTexture
        let secondTexture = try XCTUnwrap(secondTextureOptional)
        let secondBuildCount = await adapter.debugAccelerationBuildCount
        XCTAssertEqual(secondBuildCount, 1)
        XCTAssertEqual(ObjectIdentifier(firstTexture as AnyObject),
                       ObjectIdentifier(secondTexture as AnyObject))
    }

    func test_frontToBackRender_rebuildsAccelerationAfterDatasetChanges() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        guard await adapter.debugAccelerationAvailable else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }

        _ = try await adapter.renderFrame(using: VolumeRenderRegressionFixture.request())
        let firstTextureOptional = await adapter.debugAccelerationCacheTexture
        let firstTexture = try XCTUnwrap(firstTextureOptional)

        let dataset = replacementDataset()
        let replacementRequest = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeRenderRegressionFixture.volumeTransferFunction(for: dataset),
            viewportSize: VolumeRenderRegressionFixture.viewportSize,
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
            compositing: .frontToBack,
            quality: .interactive
        )
        _ = try await adapter.renderFrame(using: replacementRequest)
        let secondTextureOptional = await adapter.debugAccelerationCacheTexture
        let secondTexture = try XCTUnwrap(secondTextureOptional)
        let buildCount = await adapter.debugAccelerationBuildCount

        XCTAssertEqual(buildCount, 2)
        XCTAssertNotEqual(ObjectIdentifier(firstTexture as AnyObject),
                          ObjectIdentifier(secondTexture as AnyObject))
    }

    func test_frontToBackLayerStack_reusesAccelerationForEveryDataset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        guard await adapter.debugAccelerationAvailable else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }
        var request = VolumeRenderRegressionFixture.request()
        let overlay = replacementDataset()
        request.layers = [
            VolumeLayer(
                id: VolumeRenderRequest.primaryVolumeLayerID,
                dataset: request.dataset,
                transferFunction: request.transferFunction
            ),
            VolumeLayer(
                id: "overlay",
                dataset: overlay,
                transferFunction: .defaultGrayscale(for: overlay)
            )
        ]

        _ = try await adapter.renderFrame(using: request)
        let firstBuildCount = await adapter.debugAccelerationBuildCount
        XCTAssertEqual(firstBuildCount, 2)

        _ = try await adapter.renderFrame(using: request)
        let secondBuildCount = await adapter.debugAccelerationBuildCount
        XCTAssertEqual(secondBuildCount, 2)
    }

    func test_projectionRender_doesNotBuildOrRequestAcceleration() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let adapter = try MetalVolumeRenderingAdapter(device: device)

        _ = try await adapter.renderFrame(
            using: VolumeRenderRegressionFixture.request(compositing: .maximumIntensity)
        )

        let buildCount = await adapter.debugAccelerationBuildCount
        let accelerationTexture = await adapter.debugAccelerationCacheTexture
        let optionValue = await adapter.debugLastRequestedOptionValue
        XCTAssertEqual(buildCount, 0)
        XCTAssertNil(accelerationTexture)
        XCTAssertEqual(optionValue & VolumeRenderOptionBits.acceleration, 0)
    }

    private func rgbEnergy(in image: CGImage) -> Int? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var energy = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            energy += Int(pixels[index])
            energy += Int(pixels[index + 1])
            energy += Int(pixels[index + 2])
        }
        return energy
    }

    private func replacementDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        var voxels = [Int16](repeating: -1_000, count: dimensions.voxelCount)
        voxels[dimensions.voxelCount / 2] = 680
        return VolumeDataset(
            data: voxels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: -1_000...680,
            recommendedWindow: -1_000...680
        )
    }
}
