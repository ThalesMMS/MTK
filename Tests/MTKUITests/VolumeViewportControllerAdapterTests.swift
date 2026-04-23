import CoreGraphics
import Metal
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
import XCTest
@_spi(Testing) import MTKCore
@_spi(Testing) @testable import MTKUI

@MainActor
final class VolumeViewportControllerAdapterTests: XCTestCase {
    func testDefaultViewportSurfaceUsesMTKViewWhenMetalKitIsAvailable() throws {
#if canImport(MetalKit)
        _ = try requireMetalDevice()
        let viewportSurface = try MetalViewportSurface()

        XCTAssertTrue(viewportSurface.view is MTKView)
#else
        throw XCTSkip("MetalKit not available")
#endif
    }

#if canImport(SwiftUI)
    func testMetalViewportViewHostsControllerSurface() throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let surface: any ViewportPresenting = controller.surface

        _ = MetalViewportView(surface: surface)
    }
#endif

    func testControllerInitializesWithViewportSurface() throws {
        let device = try requireMetalDevice()
        let viewportSurface = try makeSurface(width: 48, height: 40)
        let controller = try VolumeViewportController(device: device, surface: viewportSurface)
        let surface: any ViewportPresenting = controller.surface

        XCTAssertTrue(controller.viewportSurface === viewportSurface)
        XCTAssertTrue(surface.view === viewportSurface.view)
        XCTAssertEqual(controller.viewportSurface.drawablePixelSize.width, 48)
        XCTAssertEqual(controller.viewportSurface.drawablePixelSize.height, 40)
    }

    func testVolumeConfigurationsRenderTexturesForAllMethods() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()
        let snapshotExporter = TextureSnapshotExporter()

        await controller.applyDataset(dataset)
        for method in VolumetricRenderMethod.allCases {
            controller.viewportSurface.clearPresentedTexture()
            await controller.setDisplayConfiguration(.volume(method: method))
            let texture = try await waitForRenderedTexture(controller)
            let image = try await makeSnapshotImage(from: texture, exporter: snapshotExporter)
            XCTAssertEqual(texture.width, 64)
            XCTAssertEqual(texture.height, 64)
            XCTAssertEqual(image.width, texture.width)
            XCTAssertEqual(image.height, texture.height)
            XCTAssertEqual(controller.debugVolumeMethodID, method.methodID)
        }
    }

    func testRenderVolumeSnapshotFrameReturnsProductionFrameForExplicitExport() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()

        await controller.applyDataset(dataset)
        await controller.setDisplayConfiguration(.volume(method: .mip))

        let frame = try await controller.renderVolumeSnapshotFrame()
        XCTAssertEqual(frame.texture.width, 64)
        XCTAssertEqual(frame.texture.height, 64)
        XCTAssertEqual(frame.metadata.compositing, .maximumIntensity)
        XCTAssertEqual(frame.metadata.quality, .production)

        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        XCTAssertEqual(image.width, frame.texture.width)
        XCTAssertEqual(image.height, frame.texture.height)
    }

    func testRenderVolumeSnapshotFrameProducesVisiblePixels() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()

        await controller.applyDataset(dataset)

        let frame = try await controller.renderVolumeSnapshotFrame()
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testRenderVolumeSnapshotFrameReportsMissingDataset() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)

        do {
            _ = try await controller.renderVolumeSnapshotFrame()
            XCTFail("Expected missing dataset error")
        } catch VolumeViewportController.Error.datasetNotLoaded {
            // Expected explicit failure mode.
        } catch {
            XCTFail("Expected datasetNotLoaded, got \(error)")
        }
    }

    func testMPRConfigurationCompletesAndUpdatesWindowedState() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(dataset)
            await controller.setMprHuWindow(min: -500, max: 600)
            controller.viewportSurface.clearPresentedTexture()
            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .mean,
                     slab: VolumeViewportController.SlabConfiguration(thickness: 3, steps: 3))
            )

            try await waitForMetric("metal.mpr.render.success", in: metrics, controller: controller)
        }
        XCTAssertEqual(controller.debugMprBlendID, Int32(VolumetricMPRBlendMode.mean.rawValue))
        XCTAssertEqual(controller.sliceState.axis, .z)
    }

    func testMPRWindowLevelReusesCachedTextureFrame() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(makeSyntheticDataset())
            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .single,
                     slab: nil)
            )
            try await waitForMetric("metal.mpr.render.success", in: metrics, controller: controller)

            let renderCount = metrics.counter(named: "metal.mpr.render.success")
            let cachedFrameID = try XCTUnwrap(controller.debugCachedMPRFrameTextureIdentifier(axis: .z))
            XCTAssertEqual(controller.debugCachedMPRFrameCount, 1)

            await controller.setMprHuWindow(min: -300, max: 300)
            try await Task.sleep(nanoseconds: 100_000_000)

            XCTAssertEqual(metrics.counter(named: "metal.mpr.render.success"), renderCount)
            XCTAssertEqual(controller.debugCachedMPRFrameTextureIdentifier(axis: .z), cachedFrameID)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.debugRenderedTexture) as AnyObject),
                           cachedFrameID)
        }
    }

    func testMPRWindowLevelReusesPreviewCachedTextureFrame() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(makeSyntheticDataset())
            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .single,
                     slab: VolumeViewportController.SlabConfiguration(thickness: 4, steps: 4))
            )
            try await waitForMetric("metal.mpr.render.final.success", in: metrics, controller: controller)

            await controller.setAdaptiveSampling(true)
            await controller.beginAdaptiveSamplingInteraction()
            try await waitForMetric("metal.mpr.render.preview.success", in: metrics, controller: controller)

            let renderCount = metrics.counter(named: "metal.mpr.render.preview.success")
            let cachedFrameID = try XCTUnwrap(controller.debugCachedMPRFrameTextureIdentifier(axis: .z))
            XCTAssertEqual(controller.debugCachedMPRFrameCount, 1)

            await controller.setMprHuWindow(min: -300, max: 300)
            try await Task.sleep(nanoseconds: 100_000_000)

            XCTAssertEqual(metrics.counter(named: "metal.mpr.render.preview.success"), renderCount)
            XCTAssertEqual(controller.debugCachedMPRFrameTextureIdentifier(axis: .z), cachedFrameID)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.debugRenderedTexture) as AnyObject),
                           cachedFrameID)

            await controller.endAdaptiveSamplingInteraction()
        }
    }

    func testMPRSliceChangeInvalidatesCachedTextureFrame() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(makeSyntheticDataset())
            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .single,
                     slab: nil)
            )
            try await waitForMetric("metal.mpr.render.success", in: metrics, controller: controller)

            let renderCount = metrics.counter(named: "metal.mpr.render.success")
            let firstTextureID = try XCTUnwrap(controller.debugCachedMPRFrameTextureIdentifier(axis: .z))

            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 5,
                     blend: .single,
                     slab: nil)
            )
            try await waitForMetric("metal.mpr.render.success",
                                    above: renderCount,
                                    in: metrics,
                                    controller: controller)

            let newTextureID = controller.debugCachedMPRFrameTextureIdentifier(axis: .z)
            XCTAssertNotNil(newTextureID)
            XCTAssertNotEqual(try XCTUnwrap(newTextureID), firstTextureID)
        }
    }

    func testMPRSlabConfigurationChangeInvalidatesCachedTextureFrame() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(makeSyntheticDataset())
            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .single,
                     slab: VolumeViewportController.SlabConfiguration(thickness: 1, steps: 1))
            )
            try await waitForMetric("metal.mpr.render.success", in: metrics, controller: controller)

            let renderCount = metrics.counter(named: "metal.mpr.render.success")
            let firstTextureID = try XCTUnwrap(controller.debugCachedMPRFrameTextureIdentifier(axis: .z))

            await controller.setDisplayConfiguration(
                .mpr(axis: .z,
                     index: 4,
                     blend: .single,
                     slab: VolumeViewportController.SlabConfiguration(thickness: 3, steps: 5))
            )
            try await waitForMetric("metal.mpr.render.success",
                                    above: renderCount,
                                    in: metrics,
                                    controller: controller)

            let newTextureID = controller.debugCachedMPRFrameTextureIdentifier(axis: .z)
            XCTAssertNotNil(newTextureID)
            XCTAssertNotEqual(try XCTUnwrap(newTextureID), firstTextureID)
        }
    }

    func testApplyDatasetLeavesDefaultVolumeTransferFunctionOnSharedGrayscaleFallback() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()

        await controller.applyDataset(dataset)

        XCTAssertNil(controller.debugTransferFunctionShift)
        XCTAssertEqual(controller.debugResolvedVolumeTransferFunction(for: dataset),
                       VolumeTransferFunction.defaultGrayscale(for: dataset))
    }

    func testAdaptiveSamplingChangesEffectiveSampleCountAndRerenders() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        await controller.applyDataset(makeSyntheticDataset())
        await controller.setDisplayConfiguration(.volume(method: .dvr))
        _ = try await waitForRenderedTexture(controller)

        await controller.setSamplingStep(512)
        await controller.setAdaptiveSampling(true)
        XCTAssertEqual(controller.debugSamplingStep, 512)

        await controller.beginAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.debugSamplingStep, 256)
        XCTAssertEqual(controller.renderQualityState, .interacting)
        XCTAssertEqual(controller.statePublisher.qualityState, .interacting)
        controller.viewportSurface.clearPresentedTexture()
        _ = try await waitForRenderedTexture(controller)

        controller.viewportSurface.clearPresentedTexture()
        await controller.endAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.renderQualityState, .settling)
        XCTAssertEqual(controller.statePublisher.qualityState, .settling)
        try await waitForRenderQuality(.settled, controller: controller)
        XCTAssertEqual(controller.debugSamplingStep, 512)
        XCTAssertEqual(controller.statePublisher.qualityState, .settled)
        _ = try await waitForRenderedTexture(controller)
    }

    func testQualityTelemetrySeparatesPreviewAndFinalVolumeRenders() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.applyDataset(makeSyntheticDataset())
            await controller.setDisplayConfiguration(.volume(method: .dvr))
            _ = try await waitForRenderedTexture(controller)

            controller.viewportSurface.clearPresentedTexture()
            await controller.beginAdaptiveSamplingInteraction()
            try await waitForMetric("metal.volume.render.preview.success", in: metrics, controller: controller)

            let finalCount = metrics.counter(named: "metal.volume.render.final.success")
            controller.viewportSurface.clearPresentedTexture()
            await controller.endAdaptiveSamplingInteraction()
            try await waitForRenderQuality(.settled, controller: controller)
            try await waitForMetric("metal.volume.render.final.success",
                                    above: finalCount,
                                    in: metrics,
                                    controller: controller)
            XCTAssertGreaterThan(metrics.timingCount(category: "metal.volume.render.preview"), 0)
            XCTAssertGreaterThan(metrics.timingCount(category: "metal.volume.render.final"), 0)
        }
    }

    func testQualityTelemetrySeparatesPreviewAndFinalMPRRenders() async throws {
        let metrics = TestMetrics()

        await RenderingTelemetry.withMetrics(metrics) {
            RenderingTelemetry.mprRenderCompleted(duration: 0.1,
                                                  blend: .average,
                                                  qualityState: .interacting)
            RenderingTelemetry.mprRenderCompleted(duration: 0.2,
                                                  blend: .single,
                                                  qualityState: .settled)
        }

        XCTAssertEqual(metrics.counter(named: "metal.mpr.render.preview.success"), 1)
        XCTAssertEqual(metrics.counter(named: "metal.mpr.render.final.success"), 1)
        XCTAssertEqual(metrics.timingCount(category: "metal.mpr.render.preview"), 1)
        XCTAssertEqual(metrics.timingCount(category: "metal.mpr.render.final"), 1)
    }

    func testSharedMetricsStoresTimingsByCategory() {
        let category = "test.metrics.\(UUID().uuidString)"

        Metrics.shared.trackTiming(category, interval: 0.12, name: "first")
        Metrics.shared.trackTiming(category, interval: 0.34, name: "second")

        XCTAssertEqual(Metrics.shared.timings(for: category), [
            MetricTiming(name: "first", interval: 0.12),
            MetricTiming(name: "second", interval: 0.34)
        ])
    }

    func testWindowTransferLightingGatesAndCameraUpdateControllerState() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        await controller.applyDataset(makeSyntheticDataset())
        _ = try await waitForRenderedTexture(controller)

        let cameraBefore = controller.cameraState
        let window = VolumetricHUWindowMapping(minHU: -300, maxHU: 900, tfMin: 0.2, tfMax: 0.8)
        controller.viewportSurface.clearPresentedTexture()
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
        _ = try await waitForRenderedTexture(controller)
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

    private func makeController(device: any MTLDevice) throws -> VolumeViewportController {
        try VolumeViewportController(device: device, surface: makeSurface(width: 64, height: 64))
    }

    private func makeSurface(width: CGFloat, height: CGFloat) throws -> MetalViewportSurface {
        let surface = try MetalViewportSurface()
        surface.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        surface.setContentScale(1)
        return surface
    }

    private func makeSyntheticDataset() -> VolumeDataset {
        VolumeRenderRegressionFixture.dataset()
    }

    private func waitForRenderedTexture(_ controller: VolumeViewportController,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async throws -> any MTLTexture {
        for _ in 0..<80 {
            if let texture = controller.debugRenderedTexture {
                return texture
            }
            if let error = controller.lastRenderError {
                XCTFail("Render failed with \(error)", file: file, line: line)
                throw error
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(controller.debugRenderedTexture,
                             "Timed out waiting for adapter render",
                             file: file,
                             line: line)
    }

    private func makeSnapshotImage(from texture: any MTLTexture,
                                   exporter: TextureSnapshotExporter) async throws -> CGImage {
        let metadata = VolumeRenderFrame.Metadata(
            viewportSize: CGSize(width: texture.width, height: texture.height),
            samplingDistance: 1,
            compositing: .frontToBack,
            quality: .interactive,
            pixelFormat: texture.pixelFormat
        )
        let frame = VolumeRenderFrame(texture: texture, metadata: metadata)
        return try await exporter.makeCGImage(from: frame)
    }

    private func imageContainsVisiblePixels(_ image: CGImage) -> Bool {
        VolumeRenderRegressionFixture.imageContainsVisiblePixels(image)
    }

    private func waitForMetric(_ name: String,
                               in metrics: TestMetrics,
                               controller: VolumeViewportController,
                               file: StaticString = #filePath,
                               line: UInt = #line) async throws {
        try await waitForMetric(name,
                                above: 0,
                                in: metrics,
                                controller: controller,
                                file: file,
                                line: line)
    }

    private func waitForMetric(_ name: String,
                               above baseline: Int,
                               in metrics: TestMetrics,
                               controller: VolumeViewportController,
                               file: StaticString = #filePath,
                               line: UInt = #line) async throws {
        for _ in 0..<80 {
            if metrics.counter(named: name) > baseline {
                return
            }
            if let error = controller.lastRenderError {
                XCTFail("Render failed with \(error)", file: file, line: line)
                throw error
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(name)", file: file, line: line)
        throw XCTestError(.timeoutWhileWaiting)
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }
}

private final class TestMetrics: @unchecked Sendable, MetricsProtocol {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var timings: [String: Int] = [:]

    func incrementCounter(_ name: String, by amount: Int) {
        lock.lock()
        counters[name, default: 0] += amount
        lock.unlock()
    }

    func trackTiming(_ category: String, interval: TimeInterval, name: String?) {
        _ = (interval, name)
        lock.lock()
        timings[category, default: 0] += 1
        lock.unlock()
    }

    func counter(named name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counters[name, default: 0]
    }

    func timingCount(category: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return timings[category, default: 0]
    }
}
