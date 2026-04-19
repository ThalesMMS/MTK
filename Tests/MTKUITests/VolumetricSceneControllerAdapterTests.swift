import CoreGraphics
import Metal
import XCTest
import MTKCore
@_spi(Testing) @testable import MTKUI

@MainActor
final class VolumetricSceneControllerAdapterTests: XCTestCase {
    func testControllerInitializesWithImageSurface() throws {
        let device = try requireMetalDevice()
        let imageSurface = makeSurface(width: 48, height: 40)
        let controller = try VolumetricSceneController(device: device, surface: imageSurface)

        XCTAssertTrue(controller.imageSurface === imageSurface)
        XCTAssertTrue(controller.surface.view === imageSurface.view)
        XCTAssertEqual(controller.imageSurface.drawablePixelSize.width, 48)
        XCTAssertEqual(controller.imageSurface.drawablePixelSize.height, 40)
    }

    func testVolumeConfigurationsRenderImagesForAllMethods() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()

        await controller.applyDataset(dataset)
        for method in VolumetricRenderMethod.allCases {
            controller.imageSurface.clear()
            await controller.setDisplayConfiguration(.volume(method: method))
            let image = try await waitForRenderedImage(controller)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            XCTAssertEqual(controller.debugVolumeMethodID, method.methodID)
        }
    }

    func testMPRConfigurationRendersWindowedImage() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()

        await controller.applyDataset(dataset)
        await controller.setMprHuWindow(min: -500, max: 600)
        controller.imageSurface.clear()
        await controller.setDisplayConfiguration(
            .mpr(axis: .z,
                 index: 4,
                 blend: .mean,
                 slab: VolumetricSceneController.SlabConfiguration(thickness: 3, steps: 3))
        )

        let image = try await waitForRenderedImage(controller)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertEqual(controller.debugMprBlendID, Int32(VolumetricMPRBlendMode.mean.rawValue))
        XCTAssertEqual(controller.sliceState.axis, .z)
    }

    func testAdaptiveSamplingChangesEffectiveSampleCountAndRerenders() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        await controller.applyDataset(makeSyntheticDataset())
        await controller.setDisplayConfiguration(.volume(method: .dvr))
        _ = try await waitForRenderedImage(controller)

        await controller.setSamplingStep(512)
        await controller.setAdaptiveSampling(true)
        XCTAssertEqual(controller.debugSamplingStep, 512)

        await controller.beginAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.debugSamplingStep, 256)
        controller.imageSurface.clear()
        _ = try await waitForRenderedImage(controller)

        await controller.endAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.debugSamplingStep, 512)
        controller.imageSurface.clear()
        _ = try await waitForRenderedImage(controller)
    }

    func testWindowTransferLightingGatesAndCameraUpdateControllerState() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        await controller.applyDataset(makeSyntheticDataset())
        _ = try await waitForRenderedImage(controller)

        let cameraBefore = controller.cameraState
        let window = VolumetricHUWindowMapping(minHU: -300, maxHU: 900, tfMin: 0.2, tfMax: 0.8)
        controller.imageSurface.clear()
        await controller.setHuWindow(window)
        await controller.setPreset(.ctBone)
        await controller.setShift(25)
        await controller.setLighting(enabled: false)
        await controller.setProjectionDensityGate(floor: 0.1, ceil: 0.7)
        await controller.setProjectionHuGate(enabled: true, min: -200, max: 500)
        await controller.rotateCamera(screenDelta: SIMD2<Float>(12, -8))

        XCTAssertEqual(controller.windowLevelState.window, 1200)
        XCTAssertEqual(controller.windowLevelState.level, 300)
        XCTAssertEqual(controller.debugHuWindow, window)
        XCTAssertEqual(controller.debugTransferFunctionShift, 25)
        XCTAssertFalse(controller.debugLightingEnabled)
        XCTAssertEqual(controller.debugProjectionDensityGate?.lowerBound ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(controller.debugProjectionDensityGate?.upperBound ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertTrue(controller.debugProjectionHuGate.enabled)
        XCTAssertEqual(controller.debugProjectionHuGate.min, -200)
        XCTAssertEqual(controller.debugProjectionHuGate.max, 500)
        XCTAssertNotEqual(controller.cameraState.position, cameraBefore.position)
        _ = try await waitForRenderedImage(controller)
    }

    func testHUWindowMappingClampsToDatasetRange() {
        let mapping = VolumetricHUWindowMapping.makeHuWindowMapping(
            minHU: -2_000,
            maxHU: 5_000,
            datasetRange: -1_024...3_071,
            transferDomain: -1_024...3_071
        )

        XCTAssertEqual(mapping.minHU, -1_024)
        XCTAssertEqual(mapping.maxHU, 3_071)
        XCTAssertEqual(mapping.tfMin, 0)
        XCTAssertEqual(mapping.tfMax, 1)
    }

    private func makeController(device: any MTLDevice) throws -> VolumetricSceneController {
        try VolumetricSceneController(device: device, surface: makeSurface(width: 64, height: 64))
    }

    private func makeSurface(width: CGFloat, height: CGFloat) -> ImageSurface {
        let surface = ImageSurface()
        surface.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        surface.setContentScale(1)
        return surface
    }

    private func makeSyntheticDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        var voxels = [Int16]()
        voxels.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let value = Int16(-1_000 + (x * 80) + (y * 60) + (z * 100))
                    voxels.append(value)
                }
            }
        }
        let data = voxels.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: -1_000...680,
            recommendedWindow: -1_000...680
        )
    }

    private func waitForRenderedImage(_ controller: VolumetricSceneController,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async throws -> CGImage {
        for _ in 0..<80 {
            if let image = controller.debugRenderedImage {
                return image
            }
            if let error = controller.lastRenderError {
                XCTFail("Render failed with \(error)", file: file, line: line)
                throw error
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(controller.debugRenderedImage,
                             "Timed out waiting for adapter render",
                             file: file,
                             line: line)
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }
}
