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

    func testSurfaceRenderSchedulingDebouncesToLatestStableSize() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        controller.debugSetSurfaceRenderDebounceDelayNanoseconds(1_000_000)
        try await Task.sleep(nanoseconds: 90_000_000)
        let baseline = controller.debugStableSurfaceRenderScheduleCount

        controller.debugScheduleRenderAfterSurfaceSettles(size: CGSize(width: 32, height: 32),
                                                          reason: "test")
        controller.debugScheduleRenderAfterSurfaceSettles(size: CGSize(width: 64, height: 64),
                                                          reason: "test")
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.debugStableSurfaceRenderScheduleCount, baseline + 1)
        XCTAssertEqual(controller.debugLastStableSurfaceRenderSize, CGSize(width: 64, height: 64))
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

    func testControllerInitializesWhenVolumeRendererFactoryFails() throws {
        let device = try requireMetalDevice()
        let counter = VolumeRendererFactoryCounter()
        let controller = try makeController(device: device,
                                            failingVolumeRenderer: counter)

        XCTAssertNotNil(controller.surface)
        XCTAssertEqual(counter.value, 0)
    }

    func testMPRFlowDoesNotResolveUnavailableVolumeRenderer() async throws {
        let device = try requireMetalDevice()
        let counter = VolumeRendererFactoryCounter()
        let controller = try makeController(device: device,
                                            failingVolumeRenderer: counter)

        await controller.setDisplayConfiguration(
            .mpr(axis: .z,
                 index: 4,
                 blend: .single,
                 slab: nil)
        )
        await controller.applyDataset(makeSyntheticDataset())

        let texture = try await waitForRenderedTexture(controller)
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 64)
        XCTAssertEqual(counter.value, 0)
    }

    func testRenderVolumeSnapshotFrameReportsUnavailableVolumeRendererOnce() async throws {
        let device = try requireMetalDevice()
        let counter = VolumeRendererFactoryCounter()
        let controller = try makeController(device: device,
                                            failingVolumeRenderer: counter)

        await controller.setRenderMode(.paused)
        await controller.applyDataset(makeSyntheticDataset())

        try await assertControllerVolumeRendererUnavailable {
            _ = try await controller.renderVolumeSnapshotFrame()
        }
        try await assertControllerVolumeRendererUnavailable {
            _ = try await controller.renderVolumeSnapshotFrame()
        }
        XCTAssertEqual(counter.value, 1)
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

    func testVolumeDrawableUnavailableWhileSurfacePendingDefersWithoutFailureTelemetry() async throws {
#if os(iOS)
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let metrics = TestMetrics()

        await controller.setRenderMode(.paused)
        await controller.applyDataset(makeSyntheticDataset())
        await controller.setDisplayConfiguration(.volume(method: .mip))
        controller.debugSetSurfaceRenderDebounceDelayNanoseconds(1_000_000)
        XCTAssertFalse(controller.viewportSurface.isPresentationSurfaceReady)

        controller.renderMode = .active
        controller.renderPending = false
        controller.renderGeneration &+= 1
        let generation = controller.renderGeneration

        try await RenderingTelemetry.withMetrics(metrics) {
            await controller.render(generation: generation)
        }

        XCTAssertNil(controller.lastRenderError)
        XCTAssertTrue(controller.renderPending)
        XCTAssertEqual(metrics.counter(named: "metal.volume.render.failure"), 0)

        let baselineScheduleCount = controller.debugStableSurfaceRenderScheduleCount
        controller.viewportSurface.onPresentationSurfaceReady?(controller.viewportSurface.drawablePixelSize)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertGreaterThan(controller.debugStableSurfaceRenderScheduleCount, baselineScheduleCount)
#else
        throw XCTSkip("Surface-pending drawable deferral is iOS-only")
#endif
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

    func testVolumeLayerControlsUpdateControllerStateAndScheduleRender() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()
        await controller.applyDataset(dataset)
        let layer = try makeLabelmapLayer(for: dataset)
        let beforeSet = controller.renderGeneration

        await controller.setVolumeLayers([layer])

        XCTAssertEqual(controller.volumeLayers, [layer])
        XCTAssertGreaterThan(controller.renderGeneration, beforeSet)

        await controller.setVolumeLayerVisibility(id: layer.id, isVisible: false)
        XCTAssertEqual(controller.volumeLayers.first?.isVisible, false)

        await controller.setVolumeLayerOpacity(id: layer.id, opacity: 0.2)
        XCTAssertEqual(controller.volumeLayers.first?.opacity, 0.2)
    }

    func testSurfaceMeshLayerControlsUpdateControllerStateAndScheduleRender() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        await controller.applyDataset(makeSyntheticDataset())
        let layer = makeSurfaceMeshLayer()
        let beforeSet = controller.renderGeneration

        await controller.setSurfaceMeshLayers([layer])

        XCTAssertEqual(controller.surfaceMeshLayers, [layer])
        XCTAssertGreaterThan(controller.renderGeneration, beforeSet)

        await controller.setSurfaceMeshLayerVisibility(id: layer.id, isVisible: false)
        XCTAssertEqual(controller.surfaceMeshLayers.first?.isVisible, false)

        await controller.setSurfaceMeshLayerOpacity(id: layer.id, opacity: 0.2)
        XCTAssertEqual(controller.surfaceMeshLayers.first?.opacity, 0.2)
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
            XCTAssertEqual(controller.debugCachedMPRFrameCount, 1)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.debugRenderedTexture) as AnyObject),
                           try XCTUnwrap(newTextureID))
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
            XCTAssertEqual(controller.debugCachedMPRFrameCount, 1)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.debugRenderedTexture) as AnyObject),
                           try XCTUnwrap(newTextureID))
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

    func testVolumeRenderQualitySettingsDrivePreviewAndFinalSampleCounts() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let settings = VolumeRenderQualitySettings(renderResolution: .high,
                                                   interactingResolution: .low,
                                                   depthResolution: .medium,
                                                   iterations: .medium,
                                                   shadowMode: .soft)

        await controller.setVolumeRenderQualitySettings(settings)
        XCTAssertEqual(controller.debugVolumeRenderQualitySettings, settings.sanitized)
        XCTAssertEqual(controller.debugSamplingStep, 768)

        await controller.beginAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.renderQualityState, .interacting)
        XCTAssertEqual(controller.debugSamplingStep, 256)

        let updated = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                  interactingResolution: .medium,
                                                  depthResolution: .fantastic,
                                                  iterations: .medium,
                                                  shadowMode: .hard)
        await controller.setVolumeRenderQualitySettings(updated)

        XCTAssertEqual(controller.renderQualityState, .interacting)
        XCTAssertEqual(controller.debugSamplingStep, 512)
    }

    func testVolumeRenderRequestCarriesQualitySettings() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()
        let settings = VolumeRenderQualitySettings(renderResolution: .medium,
                                                   interactingResolution: .low,
                                                   depthResolution: .low,
                                                   iterations: .high,
                                                   shadowMode: .off)

        await controller.setVolumeRenderQualitySettings(settings)
        let request = controller.makeVolumeRenderRequest(dataset: dataset, method: .dvr)

        XCTAssertEqual(request.renderQualitySettings, settings.sanitized)
    }

    func testVolumeRenderQualitySettingsDoNotDisableLightingWhenShadowsAreOff() async throws {
        let device = try requireMetalDevice()
        let controller = try makeController(device: device)
        let dataset = makeSyntheticDataset()
        let settings = VolumeRenderQualitySettings(shadowMode: .off)

        await controller.applyDataset(dataset)
        await controller.setDisplayConfiguration(.volume(method: .dvr))
        await controller.setVolumeRenderQualitySettings(settings)
        _ = try await waitForRenderedTexture(controller)

        XCTAssertTrue(controller.debugLightingEnabled)
        let renderState = try await controller.volumeRendererProvider.renderer().getRenderStateSnapshot()
        XCTAssertTrue(renderState.lightingEnabled)
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

        let renderState = try await controller.volumeRendererProvider.renderer().getRenderStateSnapshot()
        XCTAssertEqual(renderState.huWindow, -300...900)
        XCTAssertFalse(renderState.lightingEnabled)
        XCTAssertEqual(renderState.huGate, -200...500)
        XCTAssertNil(renderState.densityGate)
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

    private func makeController(device: any MTLDevice,
                                failingVolumeRenderer counter: VolumeRendererFactoryCounter) throws -> VolumeViewportController {
        try VolumeViewportController(device: device,
                                     surface: makeSurface(width: 64, height: 64),
                                     mprVolumeTextureCache: nil,
                                     volumeRendererFactory: counter.makeRenderer)
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

    private func makeLabelmapLayer(for base: VolumeDataset) throws -> VolumeLayer {
        let values = [UInt16](repeating: 1, count: base.dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: base.dimensions,
            spacing: base.spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1,
            orientation: base.orientation
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))]
        )
        return VolumeLayer(id: "volume-controller-layer",
                           labelmap: labelmap,
                           opacity: 0.5)
    }

    private func makeSurfaceMeshLayer() -> SurfaceMeshLayer {
        let mesh = SurfaceMesh(
            id: "volume-controller-surface-mesh",
            vertices: [
                SIMD3<Float>(0.2, 0.2, 0.5),
                SIMD3<Float>(0.8, 0.2, 0.5),
                SIMD3<Float>(0.5, 0.8, 0.5)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1)
            ],
            indices: [0, 1, 2],
            coordinateSpace: .textureNormalized
        )
        return SurfaceMeshLayer(id: "volume-controller-surface-layer",
                                mesh: mesh,
                                material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1)),
                                opacity: 0.5)
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

    private func assertControllerVolumeRendererUnavailable(
        _ expression: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await expression()
            XCTFail("Expected volumeRendererUnavailable", file: file, line: line)
        } catch VolumeViewportController.Error.volumeRendererUnavailable(let reason) {
            XCTAssertTrue(reason.contains("pipeline"), file: file, line: line)
        } catch {
            XCTFail("Expected volumeRendererUnavailable, got \(error)", file: file, line: line)
        }
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }
}

private final class VolumeRendererFactoryCounter {
    private(set) var value = 0

    func makeRenderer(device: any MTLDevice,
                      commandQueue: any MTLCommandQueue) throws -> MetalVolumeRenderingAdapter {
        _ = (device, commandQueue)
        value += 1
        throw MetalVolumeRenderingAdapter.InitializationError.pipelineCreationFailed
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
