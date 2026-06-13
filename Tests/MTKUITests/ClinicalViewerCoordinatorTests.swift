import CoreGraphics
import Foundation
import MTKCore
@testable import MTKUI
import Metal
import XCTest

@MainActor
final class ClinicalViewerCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsMPRViewerPreferencesStore.defaultKey)
        UserDefaults.standard.removeObject(forKey: UserDefaultsVolume3DViewerPreferencesStore.defaultKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsMPRViewerPreferencesStore.defaultKey)
        UserDefaults.standard.removeObject(forKey: UserDefaultsVolume3DViewerPreferencesStore.defaultKey)
        super.tearDown()
    }

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
        XCTAssertEqual(coordinator.mprSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.mprSlabThickness, 3)
        XCTAssertEqual(coordinator.selectedMPRScreenLayout, .defaultLayout)
        XCTAssertTrue(coordinator.isMPRAnnotationsVisible)
        XCTAssertTrue(coordinator.isMPRCrosshairVisible)
        XCTAssertNil(coordinator.stack2DViewport)
        XCTAssertEqual(coordinator.twoDAxis, .axial)
        XCTAssertEqual(coordinator.twoDTool, .scroll)
        XCTAssertEqual(coordinator.twoDWindowLevelState, .default)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 400, level: 40))
        XCTAssertEqual(coordinator.twoDWindowPreset, .default)
        XCTAssertEqual(coordinator.twoDCLUTPreset, .grayscale)
        XCTAssertFalse(coordinator.isTwoDWindowInverted)
        XCTAssertEqual(coordinator.twoDTransform, .identity)
        XCTAssertEqual(coordinator.twoDSliceIndex, 0)
        XCTAssertEqual(coordinator.twoDSliceCount, 0)
        XCTAssertEqual(coordinator.twoDROIKind, .distance)
        XCTAssertTrue(coordinator.twoDROIAnnotations.isEmpty)
        XCTAssertEqual(coordinator.twoDSyncState, .default)
        XCTAssertFalse(coordinator.isTwoDSyncEnabled)
        XCTAssertEqual(coordinator.twoDScrollSettings, .default)
        XCTAssertEqual(coordinator.twoDHUDSettings, .default)
        XCTAssertEqual(coordinator.twoDMetadataOverlaySettings, .default)
        XCTAssertEqual(coordinator.twoDResliceAxis, .axial)
        XCTAssertEqual(coordinator.twoDSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.twoDSlabThickness, 1)
        XCTAssertEqual(coordinator.twoDScreenLayout, .singleWindow)
        XCTAssertTrue(coordinator.isTwoDImageAnnotationsVisible)
        XCTAssertFalse(coordinator.canUseTwoDReferenceLines)
        XCTAssertFalse(coordinator.isTwoDReferenceLinesVisible)
        XCTAssertFalse(coordinator.canUseTwoDThickSlab)
        XCTAssertEqual(coordinator.twoDThickSlabDisabledMessage, "Thick Slab requires a stack with adjacent slices.")
        XCTAssertFalse(coordinator.canUseTwoDReslice)
        XCTAssertEqual(coordinator.twoDResliceDisabledMessage, "No dataset loaded.")
        XCTAssertFalse(coordinator.showDebugOverlay)
        XCTAssertFalse(coordinator.canCaptureSnapshot)
        XCTAssertEqual(coordinator.volumeRenderQualitySettings, .default)
    }

    func testClinicalViewerModeAnd2DToolContractsExposeStableLabels() {
        XCTAssertEqual(ClinicalViewerMode.single3D.displayName, "3D")
        XCTAssertEqual(ClinicalViewerMode.clinical.displayName, "MPR")
        XCTAssertEqual(ClinicalViewerMode.stack2D.displayName, "2D")
        XCTAssertEqual(Set(ClinicalViewerMode.allCases.map(\.displayName)), Set(["2D", "MPR", "3D"]))
        XCTAssertEqual(Clinical2DTool.allCases.map(\.title), [
            "Scroll",
            "WW/WL",
            "Rotation",
            "ROI",
            "Sync",
            "Reslice",
            "Thick Slab"
        ])
        XCTAssertEqual(Clinical2DTool.allCases.compactMap { Clinical2DTool(viewerToolID: $0.viewerToolID) },
                       Clinical2DTool.allCases)
        XCTAssertEqual(TwoDScreenLayout.allCases.map(\.title), [
            "Single Window",
            "Dual (2x1)",
            "Triple (3x1)",
            "Quadruple (2x2)"
        ])
        XCTAssertEqual(ThickSlabThicknessFormatter.label(thickness: 5, spacingMillimeters: 0.5), "2.50 mm")
        XCTAssertEqual(ThickSlabThicknessFormatter.label(thickness: 5, spacingMillimeters: nil), "5 slices")
    }

    func testVolume3DInteractionModesExposeTiltForToolbarRouting() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.set3DInteractionMode(.tilt)

        XCTAssertEqual(coordinator.interactionMode, .tilt)
        XCTAssertEqual(NativeVolume3DInteractionMode.tilt.displayName, "Tilt")
    }

    func test2DToolFacadeMutatesCoordinatorStateWithoutViewport() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.applyTwoDWindowPreset(.brain)
        XCTAssertEqual(coordinator.twoDTool, .windowLevel)
        XCTAssertEqual(coordinator.twoDWindowPreset, .brain)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 80, level: 40))

        coordinator.applyTwoDWindowPreset(.endoscopy)
        XCTAssertEqual(coordinator.twoDWindowPreset, .endoscopy)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 80, level: 40))

        coordinator.setTwoDWindowLevel(window: 0, level: 30)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 80, level: 40))

        coordinator.setTwoDWindowLevel(window: 120, level: 30)
        XCTAssertEqual(coordinator.twoDWindowPreset, .other)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 120, level: 30))

        coordinator.applyTwoDCLUTPreset(.invertedGrayscale)
        XCTAssertEqual(coordinator.twoDCLUTPreset, .invertedGrayscale)
        XCTAssertTrue(coordinator.twoDWindowLevelState.effectivePresentationInversion)

        coordinator.toggleTwoDWindowInverted()
        XCTAssertTrue(coordinator.isTwoDWindowInverted)
        XCTAssertEqual(coordinator.twoDTool, .windowLevel)
        XCTAssertFalse(coordinator.twoDWindowLevelState.effectivePresentationInversion)

        coordinator.rotateTwoD(byDegrees: 90)
        XCTAssertEqual(coordinator.twoDTool, .rotation)
        XCTAssertEqual(coordinator.twoDTransform.rotationRadians, .pi / 2, accuracy: 0.0001)

        coordinator.rotateTwoD(byRadians: .pi / 4)
        XCTAssertEqual(coordinator.twoDTool, .rotation)
        XCTAssertEqual(coordinator.twoDTransform.rotationRadians, .pi * 0.75, accuracy: 0.0001)

        coordinator.rotate2DClockwise90()
        XCTAssertEqual(coordinator.twoDTransform.rotationRadians, .pi * 1.25, accuracy: 0.0001)

        coordinator.rotate2DCounterClockwise90()
        XCTAssertEqual(coordinator.twoDTransform.rotationRadians, .pi * 0.75, accuracy: 0.0001)

        coordinator.flip2DHorizontal()
        XCTAssertTrue(coordinator.twoDTransform.isFlippedHorizontally)

        coordinator.flip2DVertical()
        XCTAssertTrue(coordinator.twoDTransform.isFlippedVertically)

        coordinator.reset2DTransform()
        XCTAssertEqual(coordinator.twoDTransform, .identity)

        coordinator.panTwoD(deltaNormalized: SIMD2<Double>(0.2, -0.1))
        XCTAssertEqual(coordinator.twoDTransform.pan, SIMD2<Double>(0.2, -0.1))

        coordinator.zoomTwoD(factor: 1.5)
        XCTAssertEqual(coordinator.twoDTransform.zoom, 1.5, accuracy: 0.0001)

        coordinator.setTwoDROIKind(.arrow)
        XCTAssertEqual(coordinator.twoDTool, .roi)
        XCTAssertEqual(coordinator.twoDROIKind, .arrow)

        coordinator.handleTwoDROIInteraction(
            Clinical2DROIInteraction(kind: .arrow,
                                     axis: .axial,
                                     sliceIndex: 0,
                                     startImagePoint: CGPoint(x: 0.2, y: 0.2),
                                     endImagePoint: CGPoint(x: 0.4, y: 0.4))
        )
        XCTAssertEqual(coordinator.twoDTool, .roi)
        XCTAssertEqual(coordinator.twoDROIAnnotations.count, 1)
        XCTAssertEqual(coordinator.twoDROIAnnotations.first?.kind, .arrow)

        coordinator.setTwoDSyncEnabled(true)
        XCTAssertTrue(coordinator.isTwoDSyncEnabled)
        XCTAssertTrue(coordinator.twoDSyncState.syncTransforms)
        XCTAssertTrue(coordinator.twoDSyncState.syncWindowLevel)

        coordinator.setTwoDSyncOption(.transforms, enabled: false)
        XCTAssertFalse(coordinator.twoDSyncState.syncTransforms)
        XCTAssertTrue(coordinator.twoDSyncState.syncWindowLevel)

        let metadataSettings = ClinicalViewportMetadataOverlaySettings(isVisible: false)
        coordinator.set2DMetadataOverlaySettings(metadataSettings)
        XCTAssertEqual(coordinator.twoDMetadataOverlaySettings, metadataSettings)

        coordinator.setTwoDAxis(.coronal)
        XCTAssertEqual(coordinator.twoDAxis, .axial)
        XCTAssertEqual(coordinator.twoDResliceAxis, .axial)
        XCTAssertEqual(coordinator.twoDTool, .sync)
        XCTAssertEqual(coordinator.errorMessage, "No dataset loaded.")
    }

    func testZoomTwoDKeepsImagePointUnderNonCenterAnchor() {
        let coordinator = ClinicalViewerCoordinator()
        let router = Clinical2DInteractionRouter()
        let viewportSize = CGSize(width: 1_000, height: 1_000)
        let anchor = CGPoint(x: 0.25, y: 0.75)
        let anchorLocation = CGPoint(x: anchor.x * viewportSize.width,
                                     y: anchor.y * viewportSize.height)
        let before = router.normalizedImagePoint(viewportLocation: anchorLocation,
                                                 viewportSize: viewportSize,
                                                 transform: coordinator.twoDTransform)

        coordinator.zoomTwoD(factor: 2,
                             anchor: SIMD2<Double>(Double(anchor.x), Double(anchor.y)))

        XCTAssertEqual(coordinator.twoDTransform.zoom, 2, accuracy: 0.0001)
        XCTAssertNotEqual(coordinator.twoDTransform.pan, .zero)
        let after = router.normalizedImagePoint(viewportLocation: anchorLocation,
                                                viewportSize: viewportSize,
                                                transform: coordinator.twoDTransform)
        XCTAssertEqual(after?.x ?? .nan, before?.x ?? .nan, accuracy: 0.0001)
        XCTAssertEqual(after?.y ?? .nan, before?.y ?? .nan, accuracy: 0.0001)
    }

    func test2DSyncRestoresLocationPreferenceWhenReEnabled() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        try await coordinator.applyDataset(makeDataset())
        XCTAssertTrue(coordinator.canSyncTwoDLocation)

        coordinator.setTwoDSyncEnabled(true)
        coordinator.setTwoDSyncOption(.location, enabled: true)
        XCTAssertTrue(coordinator.twoDSyncState.syncLocation)

        coordinator.setTwoDSyncEnabled(false)
        XCTAssertFalse(coordinator.twoDSyncState.syncTransforms)
        XCTAssertFalse(coordinator.twoDSyncState.syncWindowLevel)
        XCTAssertFalse(coordinator.twoDSyncState.syncLocation)

        coordinator.setTwoDSyncEnabled(true)
        XCTAssertTrue(coordinator.twoDSyncState.syncTransforms)
        XCTAssertTrue(coordinator.twoDSyncState.syncWindowLevel)
        XCTAssertTrue(coordinator.twoDSyncState.syncLocation)
    }

    func test2DLocationSyncRequiresLocationCapability() {
        let coordinator = ClinicalViewerCoordinator()

        XCTAssertFalse(coordinator.canSyncTwoDLocation)

        coordinator.setTwoDSyncOption(.location, enabled: true)

        XCTAssertFalse(coordinator.twoDSyncState.syncLocation)
        XCTAssertEqual(coordinator.twoDTool, .sync)
    }

    func test2DResliceReportsUnavailableWithoutDataset() {
        let coordinator = ClinicalViewerCoordinator()

        XCTAssertFalse(coordinator.canUseTwoDReslice)
        XCTAssertEqual(coordinator.twoDResliceDisabledMessage, "No dataset loaded.")
        coordinator.set2DResliceAxis(.coronal)
        XCTAssertEqual(coordinator.twoDAxis, .axial)
        XCTAssertEqual(coordinator.errorMessage, "No dataset loaded.")
    }

    func test2DThickSlabReportsUnavailableWithoutAdjacentSlices() {
        let coordinator = ClinicalViewerCoordinator()
        let message = "Thick Slab requires a stack with adjacent slices."

        XCTAssertFalse(coordinator.canUseTwoDThickSlab)
        XCTAssertEqual(coordinator.twoDThickSlabDisabledMessage, message)

        coordinator.setTwoDSlabThickness(5)
        XCTAssertEqual(coordinator.twoDSlabThickness, 1)
        XCTAssertEqual(coordinator.twoDTool, .scroll)
        XCTAssertEqual(coordinator.errorMessage, message)

        coordinator.setTwoDSlabBlendMode(.mip)
        XCTAssertEqual(coordinator.twoDSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.twoDTool, .scroll)
        XCTAssertEqual(coordinator.errorMessage, message)
    }

    func test2DOptionsToggleAnnotationsAndReferenceLines() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setTwoDImageAnnotationsVisible(false)

        XCTAssertFalse(coordinator.isTwoDImageAnnotationsVisible)
        XCTAssertFalse(coordinator.twoDHUDSettings.showsTechnicalText)
        XCTAssertFalse(coordinator.twoDHUDSettings.showsSubjectName)
        XCTAssertFalse(coordinator.twoDHUDSettings.showsSeriesTitle)
        XCTAssertFalse(coordinator.twoDMetadataOverlaySettings.isVisible)

        coordinator.toggleTwoDImageAnnotations()

        XCTAssertTrue(coordinator.isTwoDImageAnnotationsVisible)
        XCTAssertTrue(coordinator.twoDHUDSettings.showsTechnicalText)
        XCTAssertTrue(coordinator.twoDMetadataOverlaySettings.isVisible)

        coordinator.setTwoDScreenLayout(.singleWindow)
        XCTAssertEqual(coordinator.twoDScreenLayout, .singleWindow)

        coordinator.setTwoDReferenceLinesVisible(true)
        XCTAssertFalse(coordinator.isTwoDReferenceLinesVisible)
        XCTAssertEqual(coordinator.errorMessage, "Reference lines require multiple 2D viewports.")
    }

    func test2DScreenLayoutsAreAllEnabledAndApply() {
        let coordinator = ClinicalViewerCoordinator()

        XCTAssertEqual(coordinator.enabledTwoDScreenLayouts, Set(TwoDScreenLayout.allCases))

        for layout in TwoDScreenLayout.allCases {
            coordinator.setTwoDScreenLayout(layout)
            XCTAssertEqual(coordinator.twoDScreenLayout, layout)
            XCTAssertNil(coordinator.errorMessage)
        }
    }

    func testApplySyncedTwoDWindowLevelStateDoesNotChangeActiveTool() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setTwoDTool(.scroll)
        let synced = TwoDWindowLevelState(window: 1200,
                                          level: 600,
                                          presetID: Volume3DWindowPreset.bone.rawValue)

        coordinator.applySyncedTwoDWindowLevelState(synced)

        XCTAssertEqual(coordinator.twoDWindowLevelState, synced)
        XCTAssertEqual(coordinator.twoDTool, .scroll)
    }

    func test2DROIsAreScopedToAxisSliceAndDeleteActions() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setTwoDROIKind(.distance)
        coordinator.setTwoDSliceIndex(1)
        coordinator.handleTwoDROIInteraction(
            Clinical2DROIInteraction(kind: .distance,
                                     axis: .axial,
                                     sliceIndex: 1,
                                     startImagePoint: CGPoint(x: 0.1, y: 0.1),
                                     endImagePoint: CGPoint(x: 0.5, y: 0.5))
        )
        XCTAssertEqual(coordinator.twoDROIAnnotations.count, 1)

        coordinator.setTwoDSliceIndex(2)
        XCTAssertTrue(coordinator.twoDROIAnnotations.isEmpty)

        coordinator.handleTwoDROIInteraction(
            Clinical2DROIInteraction(kind: .point,
                                     axis: .axial,
                                     sliceIndex: 2,
                                     startImagePoint: CGPoint(x: 0.2, y: 0.2),
                                     endImagePoint: CGPoint(x: 0.3, y: 0.3))
        )
        XCTAssertEqual(coordinator.twoDROIAnnotations.count, 1)

        coordinator.deleteTwoDROIsInView()
        XCTAssertTrue(coordinator.twoDROIAnnotations.isEmpty)

        coordinator.setTwoDSliceIndex(1)
        XCTAssertEqual(coordinator.twoDROIAnnotations.count, 1)

        coordinator.deleteAllTwoDROIs()
        XCTAssertTrue(coordinator.twoDROIAnnotations.isEmpty)
    }

    func test2DVolumeROIKindIsIgnoredUntilDrawnVolumeMeasurementExists() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setTwoDROIKind(.distance)
        coordinator.setTwoDROIKind(.volume)
        XCTAssertEqual(coordinator.twoDROIKind, .distance)

        coordinator.handleTwoDROIInteraction(
            Clinical2DROIInteraction(kind: .volume,
                                     axis: .axial,
                                     sliceIndex: 0,
                                     startImagePoint: CGPoint(x: 0.1, y: 0.1),
                                     endImagePoint: CGPoint(x: 0.5, y: 0.5))
        )

        XCTAssertTrue(coordinator.twoDROIAnnotations.isEmpty)
    }

    func test2DWindowLevelDefaultsAndPresentationApplyToStackViewport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(intensityRange: -1_000...1_000,
                                  recommendedWindow: -900...(-500))

        try await coordinator.applyDataset(dataset)
        coordinator.setMode(.stack2D)

        try await waitUntil("2D stack viewport received recommended window") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        XCTAssertEqual(coordinator.twoDWindowPreset, .default)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(range: -900...(-500)))

        coordinator.applyTwoDCLUTPreset(.invertedGrayscale)
        XCTAssertEqual(coordinator.stack2DViewport?.windowPresentation.clut, .invertedGrayscale)
        XCTAssertEqual(coordinator.stack2DViewport?.windowPresentation.effectiveInversion, true)

        coordinator.toggleTwoDWindowInverted()
        XCTAssertEqual(coordinator.stack2DViewport?.windowPresentation.isInverted, true)
        XCTAssertEqual(coordinator.stack2DViewport?.windowPresentation.effectiveInversion, false)

        let mprTransformsBefore2DRotation = coordinator.mprViewportTransforms
        coordinator.rotate2DClockwise90()
        coordinator.flip2DHorizontal()
        XCTAssertEqual(coordinator.stack2DViewport?.viewportTransform.rotationRadians ?? .nan, .pi / 2, accuracy: 0.0001)
        XCTAssertTrue(coordinator.stack2DViewport?.viewportTransform.isFlippedHorizontally == true)
        XCTAssertEqual(coordinator.interactionMode, .orbit)
        XCTAssertEqual(coordinator.mprInteractionTool, .crosshair)
        XCTAssertEqual(coordinator.mprViewportTransforms, mprTransformsBefore2DRotation)
    }

    func testStack2DSnapshotFrameExportsThroughCoordinator() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeStackSnapshotDataset(dimensions: VolumeDimensions(width: 8, height: 8, depth: 4))

        coordinator.setMode(.stack2D)
        try await coordinator.applyDataset(dataset)
        try await waitUntil("2D stack viewport received dataset") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        let viewport = try XCTUnwrap(coordinator.stack2DViewport)
        setSurfaceSize(viewport.metalSurface, size: CGSize(width: 64, height: 64))
        XCTAssertTrue(coordinator.canCaptureSnapshot)

        coordinator.setTwoDSliceIndex(2)
        coordinator.setTwoDWindowLevel(window: 600, level: -700)
        try await waitUntil("2D stack viewport applied snapshot window") {
            viewport.sliceIndex == 2
                && viewport.state.windowLevel.window == 600
                && viewport.state.windowLevel.level == -700
        }

        coordinator.applyTwoDCLUTPreset(.invertedGrayscale)
        coordinator.setTwoDTransform(
            Viewer2DTransform(zoom: 1.2,
                              pan: SIMD2<Double>(0.05, -0.05),
                              rotationRadians: .pi / 2,
                              isFlippedHorizontally: true)
        )
        try await waitUntil("2D stack viewport applied snapshot presentation") {
            viewport.windowPresentation.clut == .invertedGrayscale
                && abs(viewport.viewportTransform.rotationRadians - .pi / 2) < 0.0001
        }

        let frame = try await coordinator.renderSnapshotFrame()
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertEqual(frame.metadata.viewportID, viewport.id)
        XCTAssertEqual(frame.metadata.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(frame.texture.width, 64)
        XCTAssertEqual(frame.texture.height, 64)
        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testStack2DSnapshotFrameReportsMissingDataset() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setMode(.stack2D)
        try await waitUntil("2D stack viewport created") {
            coordinator.stack2DViewport != nil
        }

        do {
            _ = try await coordinator.renderSnapshotFrame()
            XCTFail("Expected missing dataset error")
        } catch VolumeViewportController.Error.datasetNotLoaded {
            // Expected explicit failure mode.
        } catch {
            XCTFail("Expected datasetNotLoaded, got \(error)")
        }
    }

    func test2DResliceAxisRecreatesStackViewportAndPreservesPresentation() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(intensityRange: -1_000...1_000,
                                  dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let transform = Viewer2DTransform(zoom: 1.6,
                                          pan: SIMD2<Double>(0.2, -0.15),
                                          rotationRadians: .pi / 3,
                                          isFlippedHorizontally: true)

        try await coordinator.applyDataset(dataset)
        coordinator.setMode(.stack2D)
        try await waitUntil("2D stack viewport received dataset") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        coordinator.setTwoDWindowLevel(window: 120, level: 30)
        coordinator.setTwoDTransform(transform)
        coordinator.setTwoDSliceIndex(4)

        coordinator.set2DResliceAxis(.coronal)

        try await waitUntil("2D stack viewport switched to coronal") {
            coordinator.stack2DViewport?.axis == .coronal
                && coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        let viewport = try XCTUnwrap(coordinator.stack2DViewport)
        XCTAssertEqual(coordinator.twoDAxis, .coronal)
        XCTAssertEqual(coordinator.twoDResliceAxis, .coronal)
        XCTAssertEqual(coordinator.twoDTool, .reslice)
        XCTAssertEqual(viewport.sliceCount, dataset.dimensions.height)
        XCTAssertEqual(coordinator.twoDSliceIndex, 3)
        XCTAssertEqual(coordinator.twoDWindowLevel, WindowLevelShift(window: 120, level: 30))
        XCTAssertEqual(viewport.viewportTransform, transform)
    }

    func test2DThickSlabAppliesToActiveStackViewport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))

        coordinator.setMode(.stack2D)
        try await coordinator.applyDataset(dataset)
        try await waitUntil("2D stack viewport received dataset") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        let viewport = try XCTUnwrap(coordinator.stack2DViewport)

        XCTAssertTrue(coordinator.canUseTwoDThickSlab)
        XCTAssertNil(coordinator.twoDThickSlabDisabledMessage)

        coordinator.setTwoDSlabBlendMode(.mip)
        coordinator.setTwoDSlabThickness(4)

        try await waitUntil("2D slab projection applied to stack viewport") {
            viewport.slabBlendMode == .mip && viewport.slab?.thickness == 5
        }
        XCTAssertEqual(coordinator.twoDTool, .thickSlab)
        XCTAssertEqual(coordinator.twoDSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.twoDSlabThickness, 5)
        XCTAssertEqual(coordinator.twoDSlabThicknessMillimeters, 5)
    }

    func test2DResliceReportsUnavailableForPlanarDataset() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 1))

        try await coordinator.applyDataset(dataset)

        XCTAssertFalse(coordinator.canUseTwoDReslice)
        XCTAssertEqual(coordinator.twoDResliceDisabledMessage, "2D reslice requires a volumetric dataset.")
        coordinator.set2DResliceAxis(.coronal)
        XCTAssertEqual(coordinator.twoDAxis, .axial)
        XCTAssertEqual(coordinator.errorMessage, "2D reslice requires a volumetric dataset.")
    }

    func test2DThickSlabReportsUnavailableForSingleSliceAxis() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 1))

        try await coordinator.applyDataset(dataset)

        XCTAssertFalse(coordinator.canUseTwoDThickSlab)
        XCTAssertEqual(coordinator.twoDThickSlabDisabledMessage, "Thick Slab requires a stack with adjacent slices.")

        coordinator.setTwoDSlabBlendMode(.minIP)

        XCTAssertEqual(coordinator.twoDSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.errorMessage, "Thick Slab requires a stack with adjacent slices.")
    }

    func testMPROptionsStateMutatesIndependentlyFrom3DMode() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setMPRScreenLayout(.vSplit3x1)
        coordinator.setMPRAnnotationsVisible(false)
        coordinator.setMPRCrosshairVisible(false)

        XCTAssertEqual(coordinator.mode, .single3D)
        XCTAssertEqual(coordinator.selectedMPRScreenLayout, .vSplit3x1)
        XCTAssertFalse(coordinator.isMPRAnnotationsVisible)
        XCTAssertFalse(coordinator.isMPRCrosshairVisible)
        XCTAssertEqual(coordinator.interactionMode, .orbit)
    }

    func testMPRToolFacadeMutatesCoordinatorStateWithoutViewport() {
        let coordinator = ClinicalViewerCoordinator()

        coordinator.setMPRInteractionTool(.slice)
        coordinator.setActiveMPRAxis(.sagittal)
        coordinator.setMPRSlicePosition(axis: .sagittal, normalizedPosition: 0.85)
        coordinator.setMPRWindowLevel(window: 240, level: 80)
        coordinator.setMPRSlabThickness(12)
        coordinator.setMPRSlabBlendMode(.mip)
        coordinator.setMPRROIKind(.arrow)
        coordinator.setMPRScreenLayout(.hSplit1x2)

        XCTAssertEqual(coordinator.activeMPRAxis, .sagittal)
        XCTAssertEqual(coordinator.mprSlicePositions[.sagittal], 0.85)
        XCTAssertEqual(coordinator.mprWindowPreset, .other)
        XCTAssertEqual(coordinator.mprWindow, 240)
        XCTAssertEqual(coordinator.mprLevel, 80)
        XCTAssertEqual(coordinator.mprSlabThickness, 12)
        XCTAssertEqual(coordinator.mprSlabBlendMode, .mip)
        XCTAssertEqual(coordinator.mprInteractionTool, .roi)
        XCTAssertEqual(coordinator.mprROIKind, .arrow)
        XCTAssertEqual(coordinator.selectedMPRScreenLayout, .hSplit1x2)
    }

    func testVolumeRenderQualitySettingsPersistAndRestoreThroughStore() {
        let store = InMemoryVolumeRenderQualitySettingsStore()
        let coordinator = ClinicalViewerCoordinator(volumeRenderQualitySettingsStore: store)
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .low,
                                                   depthResolution: .medium,
                                                   iterations: .high,
                                                   shadowMode: .soft,
                                                   disableShadowsWhenInteracting: true,
                                                   directionalLightIntensity: 1.25,
                                                   ambientLightIntensity: 0.45)

        coordinator.setVolumeRenderQualitySettings(settings)
        let restored = ClinicalViewerCoordinator(volumeRenderQualitySettingsStore: store)

        XCTAssertEqual(store.storedSettings, settings.sanitized)
        XCTAssertEqual(restored.volumeRenderQualitySettings, settings.sanitized)
    }

    func testResetVolumeRenderQualitySettingsRestoresAndPersistsDefault() {
        let store = InMemoryVolumeRenderQualitySettingsStore()
        let coordinator = ClinicalViewerCoordinator(volumeRenderQualitySettingsStore: store)
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .low,
                                                   depthResolution: .medium,
                                                   iterations: .high,
                                                   shadowMode: .soft,
                                                   disableShadowsWhenInteracting: true,
                                                   directionalLightIntensity: 1.25,
                                                   ambientLightIntensity: 0.45)

        coordinator.setVolumeRenderQualitySettings(settings)
        coordinator.resetVolumeRenderQualitySettings()

        XCTAssertEqual(coordinator.volumeRenderQualitySettings, .default)
        XCTAssertEqual(store.storedSettings, .default)
    }

    func testMPROptionsPreferencesPersistAndRestoreThroughStore() {
        let store = InMemoryMPRViewerPreferencesStore()
        let coordinator = ClinicalViewerCoordinator(mprViewerPreferencesStore: store)

        coordinator.setMPRScreenLayout(.vSplit3x1)
        coordinator.setMPRAnnotationsVisible(false)
        coordinator.setMPRCrosshairVisible(false)

        let restored = ClinicalViewerCoordinator(mprViewerPreferencesStore: store)

        XCTAssertEqual(store.storedPreferences?.screenLayout, .vSplit3x1)
        XCTAssertEqual(store.storedPreferences?.isAnnotationsVisible, false)
        XCTAssertEqual(store.storedPreferences?.isCrosshairVisible, false)
        XCTAssertEqual(restored.selectedMPRScreenLayout, .vSplit3x1)
        XCTAssertFalse(restored.isMPRAnnotationsVisible)
        XCTAssertFalse(restored.isMPRCrosshairVisible)
    }

    func testVolume3DImageAnnotationsPreferencePersistsAndRestoresThroughStore() {
        let store = InMemoryVolume3DViewerPreferencesStore()
        let coordinator = ClinicalViewerCoordinator(volume3DViewerPreferencesStore: store)

        coordinator.setVolume3DImageAnnotationsVisible(false)
        let restored = ClinicalViewerCoordinator(volume3DViewerPreferencesStore: store)

        XCTAssertEqual(store.storedPreferences?.isImageAnnotationsVisible, false)
        XCTAssertFalse(restored.isVolume3DImageAnnotationsVisible)
    }

    func testVolume3DViewerPreferencesStoreUsesReverseDNSDefaultKey() {
        XCTAssertEqual(
            UserDefaultsVolume3DViewerPreferencesStore.defaultKey,
            "com.mtk.volume3DViewerPreferences"
        )
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

    func testClinicalOpacityScaleReappliesScaledTransferFunctionToExistingSession() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setMode(.clinical)
        try await coordinator.applyDataset(makeDataset())
        let session = try XCTUnwrap(coordinator.clinicalViewportSession)

        coordinator.setVolumeOpacityScale(0.5)
        let expected = try coordinator.transferFunction(for: coordinator.transferPreset)

        try await waitUntil("clinical transfer function uses opacity scale") {
            session.activeTransferFunction?.alphaPoints == expected.alphaPoints
        }
        assertTransferFunction(session.activeTransferFunction, matches: expected)
    }

    func testPreferencesApplyToFutureClinicalSession() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setVolumeOpacityScale(0.5)
        coordinator.setAdaptiveSamplingEnabled(false)
        coordinator.setMode(.clinical)
        try await coordinator.applyDataset(makeDataset())

        let session = try XCTUnwrap(coordinator.clinicalViewportSession)
        let expected = try coordinator.transferFunction(for: coordinator.transferPreset)

        XCTAssertFalse(session.adaptiveSamplingEnabled)
        assertTransferFunction(session.activeTransferFunction, matches: expected)
    }

    func testSlabBlendPreferenceAppliesToFutureClinicalSession() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setMPRSlabBlendMode(.minIP)
        coordinator.setMPRSlabThickness(9)
        coordinator.setMode(.clinical)
        try await coordinator.applyDataset(makeDataset())

        let session = try XCTUnwrap(coordinator.clinicalViewportSession)
        let axialSlab = await session.debugSlabConfiguration(for: .axial)
        let coronalSlab = await session.debugSlabConfiguration(for: .coronal)
        let sagittalSlab = await session.debugSlabConfiguration(for: .sagittal)
        XCTAssertEqual(session.mprSlabBlendMode, .minIP)
        XCTAssertEqual(session.slabThickness, 9)
        XCTAssertEqual(axialSlab?.blend, .minimum)
        XCTAssertEqual(coronalSlab?.blend, .minimum)
        XCTAssertEqual(sagittalSlab?.blend, .minimum)
    }

    func testAdaptiveSamplingPreferenceAppliesToFutureSingle3DViewport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setAdaptiveSamplingEnabled(false)
        coordinator.ensureActiveViewport()
        try await waitUntil("single 3D viewport disabled adaptive sampling") {
            coordinator.volumeViewport3D?.adaptiveSamplingEnabled == false
        }
        XCTAssertFalse(try XCTUnwrap(coordinator.volumeViewport3D).adaptiveSamplingEnabled)

        coordinator.shutdownActiveViewports()
        coordinator.setAdaptiveSamplingEnabled(true)
        coordinator.ensureActiveViewport()
        try await waitUntil("single 3D viewport enabled adaptive sampling") {
            coordinator.volumeViewport3D?.adaptiveSamplingEnabled == true
        }
        XCTAssertTrue(try XCTUnwrap(coordinator.volumeViewport3D).adaptiveSamplingEnabled)
    }

    func testVolumeRenderQualityPreferenceAppliesToFutureSingle3DViewport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator(volumeRenderQualitySettingsStore: InMemoryVolumeRenderQualitySettingsStore())
        defer { coordinator.shutdownActiveViewports() }
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .medium,
                                                   depthResolution: .fantastic,
                                                   iterations: .medium,
                                                   shadowMode: .soft)

        coordinator.setVolumeRenderQualitySettings(settings)
        coordinator.ensureActiveViewport()

        try await waitUntil("single 3D viewport applied quality settings") {
            coordinator.volumeViewport3D?.volumeRenderQualitySettings == settings.sanitized
        }
        XCTAssertEqual(try XCTUnwrap(coordinator.volumeViewport3D).volumeRenderQualitySettings,
                       settings.sanitized)
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

    func testApplyDatasetClearsCropClipState() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setCropEnabled(true)
        coordinator.updateCropBound(axis: .y, isMin: true, value: 0.2)
        coordinator.updateCropBound(axis: .y, isMin: false, value: 0.8)
        coordinator.setClipEnabled(true)
        coordinator.updateClipPlaneOffset(0.25)
        coordinator.setVolumeBrushEnabled(true)
        coordinator.setVolumeBrushSizeMM(75)
        coordinator.setVolumeBrushMode(.restore)

        try await coordinator.applyDataset(makeDataset())

        XCTAssertFalse(coordinator.cropEnabled)
        XCTAssertEqual(coordinator.cropYMin, 0)
        XCTAssertEqual(coordinator.cropYMax, 1)
        XCTAssertFalse(coordinator.clipEnabled)
        XCTAssertEqual(coordinator.clipPlaneOffset, 0)
        XCTAssertEqual(try coordinator.currentVolumeClippingState(), .disabled)
        XCTAssertEqual(coordinator.volumeViewport3D?.state.clipping, .disabled)
        XCTAssertFalse(coordinator.volumeBrushState.isEnabled)
        XCTAssertEqual(coordinator.volumeBrushState.brushSizeMM, VolumeBrushState.defaultBrushSizeMM)
        XCTAssertEqual(coordinator.volumeBrushState.mode, .erase)
        XCTAssertFalse(coordinator.volumeBrushMaskHasEdits)
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

    func testLayerControlsUpdateActiveStackViewport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        let layer = try makeLabelmapLayer(id: "stack-seg", dimensions: dataset.dimensions)

        coordinator.setMode(.stack2D)
        try await coordinator.applyDataset(dataset)
        try await waitUntil("stack viewport ready") {
            coordinator.stack2DViewport != nil
        }
        await coordinator.setVolumeLayers([layer])
        await coordinator.setVolumeLayerVisibility(id: layer.id, isVisible: false)
        await coordinator.setVolumeLayerOpacity(id: layer.id, opacity: 0.25)
        await coordinator.setVolumeLayerBlendMode(id: layer.id, blendMode: .additive)

        let stackLayers = try XCTUnwrap(coordinator.stack2DViewport?.volumeLayers)
        XCTAssertEqual(stackLayers.count, 1)
        XCTAssertEqual(stackLayers.first?.id, "stack-seg")
        XCTAssertEqual(stackLayers.first?.labelmap?.dataset.dimensions, dataset.dimensions)
        XCTAssertEqual(stackLayers.first?.isVisible, false)
        XCTAssertEqual(stackLayers.first?.opacity, 0.25)
        XCTAssertEqual(stackLayers.first?.blendMode, .additive)
        XCTAssertEqual(coordinator.volumeLayers.first?.isVisible, false)
        XCTAssertEqual(coordinator.volumeLayers.first?.opacity, 0.25)
        XCTAssertEqual(coordinator.volumeLayers.first?.blendMode, .additive)
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

    func testStack2DModeCreatesAxialViewportBeforeDataset() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setMode(.stack2D)

        try await waitUntil("2D stack viewport created") {
            coordinator.stack2DViewport != nil
        }
        let viewport = try XCTUnwrap(coordinator.stack2DViewport)
        XCTAssertEqual(coordinator.mode, .stack2D)
        XCTAssertEqual(viewport.axis, .axial)
        XCTAssertEqual(coordinator.twoDAxis, .axial)
        XCTAssertEqual(coordinator.twoDTool, .scroll)
        XCTAssertEqual(coordinator.twoDSliceIndex, 0)
        XCTAssertEqual(coordinator.twoDSliceCount, 0)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testStack2DModeReappliesDatasetAndKeepsToolStateIsolated() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset()

        coordinator.set3DInteractionMode(.brush)
        coordinator.setMPRInteractionTool(.roi)
        try await coordinator.applyDataset(dataset)
        coordinator.setTwoDTool(.windowLevel)
        coordinator.setMode(.stack2D)

        try await waitUntil("2D stack viewport received dataset") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }
        let viewport = try XCTUnwrap(coordinator.stack2DViewport)
        XCTAssertEqual(viewport.state.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(viewport.sliceCount, dataset.dimensions.depth)
        XCTAssertEqual(coordinator.twoDSliceCount, dataset.dimensions.depth)
        XCTAssertEqual(coordinator.twoDSliceIndex, 0)
        XCTAssertEqual(coordinator.twoDTool, .windowLevel)
        XCTAssertEqual(coordinator.interactionMode, .brush)
        XCTAssertEqual(coordinator.mprInteractionTool, .roi)
        XCTAssertNotNil(coordinator.volumeViewport3D)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testDatasetSurvives3D2DMPR2DModeSwitch() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 5, height: 6, depth: 7))

        try await coordinator.applyDataset(dataset)
        coordinator.setMode(.stack2D)
        try await waitUntil("2D stack received dataset before MPR switch") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }

        coordinator.setMode(.clinical)
        try await waitUntil("MPR session retained dataset") {
            coordinator.clinicalViewportSession?.datasetApplied == true
                && coordinator.dataset?.dimensions == dataset.dimensions
        }

        coordinator.setMode(.stack2D)
        try await waitUntil("2D stack received dataset after MPR switch") {
            coordinator.stack2DViewport?.state.dataset?.dimensions == dataset.dimensions
        }

        XCTAssertEqual(coordinator.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(coordinator.stack2DViewport?.state.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(coordinator.twoDSliceCount, dataset.dimensions.depth)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testStack2DScrollSettingsClampWrapAndStayModeIsolated() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }
        let dataset = makeDataset()

        coordinator.set3DInteractionMode(.brush)
        coordinator.setMPRInteractionTool(.roi)
        try await coordinator.applyDataset(dataset)
        coordinator.setMode(.stack2D)

        try await waitUntil("2D stack viewport received slices") {
            coordinator.twoDSliceCount == dataset.dimensions.depth
        }
        coordinator.scroll2D(by: 10)
        XCTAssertEqual(coordinator.twoDSliceIndex, dataset.dimensions.depth - 1)
        coordinator.scroll2D(by: -10)
        XCTAssertEqual(coordinator.twoDSliceIndex, 0)

        coordinator.set2DLoopThroughImages(true)
        XCTAssertTrue(coordinator.twoDScrollSettings.loopThroughImages)
        coordinator.scroll2D(by: -1)
        XCTAssertEqual(coordinator.twoDSliceIndex, dataset.dimensions.depth - 1)
        coordinator.scroll2D(by: 1)
        XCTAssertEqual(coordinator.twoDSliceIndex, 0)

        coordinator.set2DScrollSpeed(2)
        coordinator.set2DImageSortMode(.acquisitionTime)
        coordinator.set2DOnScreenControls(true)

        XCTAssertEqual(coordinator.twoDTool, .scroll)
        XCTAssertEqual(coordinator.twoDScrollSettings.speed, 2)
        XCTAssertEqual(coordinator.twoDScrollSettings.sortMode, .acquisitionTime)
        XCTAssertTrue(coordinator.twoDScrollSettings.showsOnScreenControls)
        XCTAssertEqual(coordinator.interactionMode, .brush)
        XCTAssertEqual(coordinator.mprInteractionTool, .roi)
    }

    func testModeSwitchCachesClinicalSession() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }
        let coordinator = ClinicalViewerCoordinator()
        defer { coordinator.shutdownActiveViewports() }

        coordinator.setMode(.clinical)
        try await coordinator.applyDataset(makeDataset())

        let session1 = try XCTUnwrap(coordinator.clinicalViewportSession)

        coordinator.setMode(.single3D)

        let session2 = try XCTUnwrap(coordinator.clinicalViewportSession)
        XCTAssertTrue(session1 === session2, "Clinical session should be cached when switching to single3D")

        coordinator.setMode(.clinical)

        let session3 = try XCTUnwrap(coordinator.clinicalViewportSession)
        XCTAssertTrue(session1 === session3, "Clinical session should remain the same when switching back to clinical")
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

private enum ClinicalViewerCoordinatorTestError: Error {
    case timeout(String)
}

private final class InMemoryVolumeRenderQualitySettingsStore: VolumeRenderQualitySettingsStoring {
    var storedSettings: VolumeRenderQualitySettings?

    func loadVolumeRenderQualitySettings() -> VolumeRenderQualitySettings? {
        storedSettings
    }

    func saveVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) {
        storedSettings = settings
    }
}

private final class InMemoryMPRViewerPreferencesStore: MPRViewerPreferencesStoring {
    var storedPreferences: MPRViewerPreferences?

    func loadMPRViewerPreferences() -> MPRViewerPreferences? {
        storedPreferences
    }

    func saveMPRViewerPreferences(_ preferences: MPRViewerPreferences) {
        storedPreferences = preferences
    }
}

private final class InMemoryVolume3DViewerPreferencesStore: Volume3DViewerPreferencesStoring {
    var storedPreferences: Volume3DViewerPreferences?

    func loadVolume3DViewerPreferences() -> Volume3DViewerPreferences? {
        storedPreferences
    }

    func saveVolume3DViewerPreferences(_ preferences: Volume3DViewerPreferences) {
        storedPreferences = preferences
    }
}

@MainActor
private func waitUntil(_ label: String,
                       attempts: Int = 100,
                       pollNanoseconds: UInt64 = 20_000_000,
                       condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<attempts {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    throw ClinicalViewerCoordinatorTestError.timeout(label)
}

private func assertTransferFunction(_ actual: TransferFunction?,
                                    matches expected: TransferFunction,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
    guard let actual else {
        XCTFail("Expected transfer function", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.alphaPoints, expected.alphaPoints, file: file, line: line)
    XCTAssertEqual(actual.renderingIntent, expected.renderingIntent, file: file, line: line)
}

private func imageContainsVisiblePixels(_ image: CGImage) -> Bool {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    guard let context = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return stride(from: 0, to: pixels.count, by: bytesPerPixel).contains { index in
        pixels[index] > 0 || pixels[index + 1] > 0 || pixels[index + 2] > 0
    }
}

@MainActor
private func setSurfaceSize(_ surface: MetalViewportSurface, size: CGSize) {
    surface.view.frame = CGRect(origin: .zero, size: size)
    surface.setContentScale(1)
}

private func makeDataset(intensityRange: ClosedRange<Int32> = 0...1,
                         recommendedWindow: ClosedRange<Int32>? = nil,
                         dimensions: VolumeDimensions = VolumeDimensions(width: 2,
                                                                          height: 2,
                                                                          depth: 2)) -> VolumeDataset {
    let voxelCount = dimensions.width * dimensions.height * dimensions.depth
    let values = [Int16](repeating: 1, count: voxelCount)
    return VolumeDataset(
        data: values.withUnsafeBytes { Data($0) },
        dimensions: dimensions,
        spacing: VolumeSpacing(x: 1, y: 1, z: 1),
        pixelFormat: .int16Signed,
        intensityRange: intensityRange,
        recommendedWindow: recommendedWindow
    )
}

private func makeStackSnapshotDataset(dimensions: VolumeDimensions) -> VolumeDataset {
    var values = [Int16]()
    values.reserveCapacity(dimensions.voxelCount)
    for z in 0..<dimensions.depth {
        for y in 0..<dimensions.height {
            for x in 0..<dimensions.width {
                values.append(Int16(-1_000 + x + y * 10 + z * 100))
            }
        }
    }
    return VolumeDataset(
        data: values.withUnsafeBytes { Data($0) },
        dimensions: dimensions,
        spacing: VolumeSpacing(x: 1, y: 1, z: 2),
        pixelFormat: .int16Signed,
        intensityRange: -1_000...(-400),
        recommendedWindow: -900...(-500)
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

private func makeLabelmapLayer(id: String,
                               dimensions: VolumeDimensions) throws -> VolumeLayer {
    var values = [UInt16](repeating: 0, count: dimensions.voxelCount)
    if !values.isEmpty {
        values[values.count / 2] = 1
    }
    let dataset = VolumeDataset(
        data: values.withUnsafeBytes { Data($0) },
        dimensions: dimensions,
        spacing: VolumeSpacing(x: 1, y: 1, z: 1),
        pixelFormat: .int16Unsigned,
        intensityRange: 0...1
    )
    let labelmap = try LabelmapVolume(
        dataset: dataset,
        segments: [LabelmapSegment(label: 1, name: "Mask", color: SIMD4<Float>(1, 0, 0, 1))]
    )
    return VolumeLayer(id: id,
                       labelmap: labelmap,
                       opacity: 0.6)
}
