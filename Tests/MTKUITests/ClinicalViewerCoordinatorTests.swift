import MTKCore
@testable import MTKUI
import Metal
import XCTest

@MainActor
final class ClinicalViewerCoordinatorTests: XCTestCase {
    func testDefaultsMatchDemoClinicalViewerState() {
        let coordinator = ClinicalViewerCoordinator()

        XCTAssertEqual(coordinator.mode, .single3D)
        XCTAssertEqual(coordinator.interactionMode, .orbit)
        XCTAssertEqual(coordinator.renderMethod, .dvr)
        XCTAssertEqual(coordinator.transferPreset, .ctSoftTissue)
        XCTAssertEqual(coordinator.volumeOpacityScale, 1.0)
        XCTAssertEqual(coordinator.mprInteractionTool, .crosshair)
        XCTAssertEqual(coordinator.activeMPRAxis, .axial)
        XCTAssertEqual(coordinator.mprSlicePositions[.axial], 0.5)
        XCTAssertFalse(coordinator.showDebugOverlay)
        XCTAssertFalse(coordinator.canCaptureSnapshot)
    }

    func testRenderMethodMappingsArePublicAndStable() {
        XCTAssertEqual(VolumetricRenderMethod.dvr.displayName, "DVR")
        XCTAssertEqual(VolumetricRenderMethod.mip.clinicalViewportMode, .mip)
        XCTAssertEqual(VolumetricRenderMethod.minip.clinicalViewportMode, .minip)
        XCTAssertEqual(VolumetricRenderMethod.avg.clinicalViewportMode, .aip)
        XCTAssertEqual(ClinicalVolumeViewportMode.aip.volumetricRenderMethod, .avg)
        XCTAssertEqual(ClinicalVolumeViewportMode.dvr.displayName, "3D")
    }

    func testQuickPresetMappingsUseMTKCatalogs() {
        XCTAssertEqual(ClinicalViewerTransferQuickPreset.allCases, [.softTissue, .bone, .lung, .brain, .abdomen, .vascular, .vrBone])
        XCTAssertEqual(ClinicalViewerTransferQuickPreset.softTissue.preset, .ctSoftTissue)
        XCTAssertEqual(ClinicalViewerTransferQuickPreset.bone.preset, .ctBone)
        XCTAssertEqual(ClinicalViewerTransferQuickPreset.vrBone.preset, .ctVRBone)

        XCTAssertEqual(ClinicalViewerWindowQuickPreset.allCases, [.softTissue, .brain, .lung, .bone, .abdomen])
        XCTAssertEqual(ClinicalViewerWindowQuickPreset.softTissue.windowLevelPreset.id, WindowLevelPresetLibrary.softTissue.id)
        XCTAssertEqual(ClinicalViewerWindowQuickPreset.abdomen.windowLevelPreset.id, "weasis.ct-abdomen")
    }

    func testOpacityScaleUsesTransferFunctionHelper() throws {
        let coordinator = ClinicalViewerCoordinator()
        let base = try ClinicalTransferFunctionPreset.ctBone.loadTransferFunction()

        coordinator.setVolumeOpacityScale(0.5)
        let scaled = try coordinator.transferFunction(for: .ctBone)

        XCTAssertEqual(scaled.alphaPoints.count, base.alphaPoints.count)
        for (source, output) in zip(base.alphaPoints, scaled.alphaPoints) {
            XCTAssertEqual(output.dataValue, source.dataValue)
            XCTAssertEqual(output.alphaValue,
                           min(max(source.alphaValue * 0.5, 0), 1),
                           accuracy: 0.0001)
        }
    }

    func testCropAndClipStateBuildsPublicClippingContract() throws {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setCropEnabled(true)
        coordinator.updateCropBound(axis: .x, isMin: true, value: 0.25)
        coordinator.updateCropBound(axis: .z, isMin: false, value: 0.75)
        let clipping = try coordinator.currentVolumeClippingState()

        XCTAssertEqual(clipping.cropBox?.textureMin, SIMD3<Float>(0.25, 0, 0))
        XCTAssertEqual(clipping.cropBox?.textureMax, SIMD3<Float>(1, 1, 0.75))
        XCTAssertTrue(clipping.clipPlanes.isEmpty)
    }

    func testLayerControlsUpdateCoordinatorStateWithoutViewport() async {
        let coordinator = ClinicalViewerCoordinator()
        let layer = VolumeLayer(id: "pet",
                                dataset: makeDataset(),
                                transferFunction: makeTransferFunction(),
                                opacity: 0.5,
                                blendMode: .additive,
                                isVisible: true)

        await coordinator.setVolumeLayers([layer])
        await coordinator.setVolumeLayerVisibility(id: "pet", isVisible: false)
        await coordinator.setVolumeLayerOpacity(id: "pet", opacity: 0.25)
        await coordinator.setVolumeLayerBlendMode(id: "pet", blendMode: .sourceOver)

        XCTAssertEqual(coordinator.volumeLayers.first?.id, "pet")
        XCTAssertFalse(coordinator.volumeLayers.first?.isVisible ?? true)
        XCTAssertEqual(coordinator.volumeLayers.first?.opacity, 0.25)
        XCTAssertEqual(coordinator.volumeLayers.first?.blendMode, .sourceOver)
    }

    func testModeSwitchCreatesSingleViewportWhenMetalIsAvailable() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.ensureActiveViewport()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(coordinator.volumeViewport3D)
        XCTAssertNil(coordinator.clinicalViewportSession)
    }

    func testDebugOverlayAndHUDConstructAsViews() {
#if canImport(SwiftUI)
        let coordinator = ClinicalViewerCoordinator()
        _ = ClinicalViewerSurface(coordinator: coordinator)
        _ = ClinicalProfilingHUD(coordinator: coordinator)
        _ = ClinicalViewportDebugOverlay(snapshot: ClinicalViewportDebugSnapshot(viewportID: ViewportID(),
                                                                                viewportName: "Volume",
                                                                                viewportType: "volume3D",
                                                                                renderMode: "DVR"))
#endif
    }
}

private func makeDataset() -> VolumeDataset {
    let values = [Int16](repeating: 1, count: 8)
    return VolumeDataset(
        data: values.withUnsafeBytes { Data($0) },
        dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
        spacing: VolumeSpacing(x: 1, y: 1, z: 1),
        pixelFormat: .int16Signed,
        intensityRange: 0...1
    )
}

private func makeTransferFunction() -> VolumeTransferFunction {
    VolumeTransferFunction(
        opacityPoints: [
            .init(intensity: 0, opacity: 0),
            .init(intensity: 1, opacity: 1)
        ],
        colourPoints: [
            .init(intensity: 0, colour: SIMD4<Float>(0, 0, 0, 0)),
            .init(intensity: 1, colour: SIMD4<Float>(1, 1, 1, 1))
        ]
    )
}
