import CoreGraphics
import Metal
import simd
import XCTest
import SwiftUI
@_spi(Testing) import MTKCore
@_spi(Testing) @testable import MTKUI

@MainActor
final class ClinicalViewportGridControllerTests: XCTestCase {
    func testControllerCreatesFourMetalNativeViewports() async throws {
        let controller = try await makeController()

        let axial = await controller.engine.debugDescriptor(for: controller.axialViewportID)
        let coronal = await controller.engine.debugDescriptor(for: controller.coronalViewportID)
        let sagittal = await controller.engine.debugDescriptor(for: controller.sagittalViewportID)
        let volume = await controller.engine.debugDescriptor(for: controller.volumeViewportID)

        XCTAssertEqual(axial?.type, .mpr(axis: .axial))
        XCTAssertEqual(coronal?.type, .mpr(axis: .coronal))
        XCTAssertEqual(sagittal?.type, .mpr(axis: .sagittal))
        XCTAssertEqual(volume?.type, .volume3D)
        let viewportCount = await controller.engine.debugViewportCount
        XCTAssertEqual(viewportCount, 4)
    }

    func testInitialDebugSnapshotsDescribeAllFourViewports() async throws {
        let controller = try await makeController()

        let snapshots = [
            controller.debugSnapshot(for: controller.axialViewportID),
            controller.debugSnapshot(for: controller.coronalViewportID),
            controller.debugSnapshot(for: controller.sagittalViewportID),
            controller.debugSnapshot(for: controller.volumeViewportID)
        ]

        XCTAssertEqual(Set(snapshots.map(\.viewportName)), Set(["Axial", "Coronal", "Sagittal", "Volume"]))
        XCTAssertEqual(snapshots.first(where: { $0.viewportID == controller.volumeViewportID })?.viewportType, "volume3D")
    }

    func testDisplayContractsKeepOverlayLabelsAlignedWithPresentationFlips() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let axial = controller.displayTransform(for: .axial)
        let coronal = controller.displayTransform(for: .coronal)
        let sagittal = controller.displayTransform(for: .sagittal)

        XCTAssertEqual(axial.leadingLabel, .right)
        XCTAssertEqual(axial.topLabel, .anterior)
        XCTAssertEqual(axial.orientation, .standard)
        XCTAssertFalse(axial.flipHorizontal)
        XCTAssertFalse(axial.flipVertical)

        XCTAssertEqual(coronal.leadingLabel, .right)
        XCTAssertEqual(coronal.topLabel, .superior)
        XCTAssertEqual(coronal.orientation, .rotated180)
        XCTAssertFalse(coronal.flipHorizontal)

        XCTAssertEqual(sagittal.leadingLabel, .anterior)
        XCTAssertEqual(sagittal.topLabel, .superior)
        XCTAssertEqual(sagittal.orientation, .standard)
        XCTAssertFalse(sagittal.flipHorizontal)
        XCTAssertTrue(sagittal.flipVertical)
    }

    @available(*, deprecated)
    func testDeprecatedDisplayContractUsesPresentationFlips() {
        let contract = ClinicalMPRDisplayContract(MPRDisplayTransform(
            orientation: .rotated180,
            flipHorizontal: false,
            flipVertical: false,
            leadingLabel: .right,
            trailingLabel: .left,
            topLabel: .superior,
            bottomLabel: .inferior
        ))

        XCTAssertTrue(contract.flipHorizontal)
        XCTAssertTrue(contract.flipVertical)
        XCTAssertEqual(contract.labels.leading, "R")
        XCTAssertEqual(contract.labels.top, "S")
    }

    func testSceneControllerCurrentDisplayTransformUsesDatasetGeometry() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal unavailable")
        let controller = try VolumeViewportController()
        let dimensions = VolumeDimensions(width: 5, height: 6, depth: 7)
        let dataset = VolumeDataset(
            data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            orientation: VolumeOrientation(
                row: SIMD3<Float>(0, 1, 0),
                column: SIMD3<Float>(-1, 0, 0),
                origin: .zero
            ),
            recommendedWindow: (-100)...300
        )

        await controller.applyDataset(dataset)

        let transform = controller.currentDisplayTransform(for: .z)

        XCTAssertNotEqual(transform.orientation, .standard)
        XCTAssertEqual(transform.leadingLabel, .right)
        XCTAssertEqual(transform.trailingLabel, .left)
        XCTAssertEqual(transform.topLabel, .anterior)
        XCTAssertEqual(transform.bottomLabel, .posterior)
    }

    func testApplyDatasetUsesOneSharedResourceHandleForAllViewports() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal unavailable")
        let controller = try await makeController()
        let dataset = makeDataset()

        try await controller.applyDataset(dataset)

        let handles = await [
            controller.engine.debugResourceHandle(for: controller.axialViewportID),
            controller.engine.debugResourceHandle(for: controller.coronalViewportID),
            controller.engine.debugResourceHandle(for: controller.sagittalViewportID),
            controller.engine.debugResourceHandle(for: controller.volumeViewportID)
        ].compactMap { $0 }
        let textureIDs = await [
            controller.engine.debugTextureObjectIdentifier(for: controller.axialViewportID),
            controller.engine.debugTextureObjectIdentifier(for: controller.coronalViewportID),
            controller.engine.debugTextureObjectIdentifier(for: controller.sagittalViewportID),
            controller.engine.debugTextureObjectIdentifier(for: controller.volumeViewportID)
        ].compactMap { $0 }

        XCTAssertEqual(handles.count, 4)
        XCTAssertEqual(Set(handles).count, 1)
        XCTAssertEqual(controller.sharedResourceHandle, handles.first)
        XCTAssertEqual(Set(textureIDs).count, 1)
        let textureCount = await controller.engine.debugResourceTextureCount
        let referenceCount = await controller.engine.debugResourceReferenceCount
        XCTAssertEqual(textureCount, 1)
        XCTAssertEqual(referenceCount, 4)

        #if DEBUG
        let counts = await controller.engine.debugVolumeUploadCounts
        XCTAssertEqual(counts.textureCreates, 1)
        XCTAssertGreaterThanOrEqual(counts.cacheHits, 0)
        #endif
    }

    func testApplyDatasetSchedulesOnlyDisplayedMPRViewports() async throws {
        let controller = try await makeController()

        try await controller.applyDataset(makeDataset())

        for viewport in controller.mprViewportIDs {
            XCTAssertGreaterThan(controller.debugRenderGeneration(for: viewport), 0)
        }
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.volumeViewportID), 0)
    }

    func testWindowLevelSyncsMPRViewportsOnly() async throws {
        let controller = try await makeController()
        let dataset = makeDataset()
        try await controller.applyDataset(dataset)

        await controller.setMPRWindowLevel(window: 120, level: 40)

        let expected: ClosedRange<Int32> = (-20)...100
        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        XCTAssertEqual(axialWindow, expected)
        XCTAssertEqual(coronalWindow, expected)
        XCTAssertEqual(sagittalWindow, expected)

        // Ensure shared state drives the value: setting same WL again should not schedule any new renders.
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)

        await controller.setMPRWindowLevel(window: 120, level: 40)

        let mprAfter = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeAfter = controller.debugRenderGeneration(for: controller.volumeViewportID)
        XCTAssertEqual(mprAfter, mprBefore)
        XCTAssertEqual(volumeAfter, volumeBefore)
    }

    func testMPRWindowPresetAppliesAllAxesAndDefaultRestoresDatasetWindow() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.applyMPRWindowPreset(.bone)

        XCTAssertEqual(controller.mprWindowPreset, .bone)
        let bonePreset = WindowLevelPresetLibrary.bone
        let expectedBoneWindow = WindowLevelShift(window: bonePreset.window,
                                                  level: bonePreset.level).range
        try await assertMPRWindows(controller: controller,
                                   expected: expectedBoneWindow)

        let positionsAfterPreset = controller.normalizedPositions
        let slabAfterPreset = controller.slabThickness

        await controller.applyMPRWindowPreset(.default)

        XCTAssertEqual(controller.mprWindowPreset, .default)
        try await assertMPRWindows(controller: controller, expected: (-100)...300)
        XCTAssertEqual(controller.normalizedPositions, positionsAfterPreset)
        XCTAssertEqual(controller.slabThickness, slabAfterPreset, accuracy: 0.0001)
    }

    func testMPRCLUTAndInvertDoNotMutateNavigationState() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let clut = try XCTUnwrap(Volume3DCLUTPreset.allPresets.first { $0.id == "system-clut" })

        let initialPositions = controller.normalizedPositions
        let initialWindow = controller.windowLevel
        let initialSlab = controller.slabThickness

        controller.setMPRCLUTPreset(clut)
        controller.setMPRWindowInverted(true)

        XCTAssertEqual(controller.mprCLUTPreset, clut)
        XCTAssertTrue(controller.isMPRWindowInverted)
        XCTAssertNotNil(controller.mprColormapTexture)
        XCTAssertEqual(controller.normalizedPositions, initialPositions)
        XCTAssertEqual(controller.windowLevel, initialWindow)
        XCTAssertEqual(controller.slabThickness, initialSlab, accuracy: 0.0001)
    }

    func testApplyMPRPresentationStateUpdatesWindowShutterAndAnnotations() async throws {
        let controller = try await makeController()
        let presentationState = MPRPresentationState(
            id: "pr-1",
            window: 0...100,
            invert: true,
            viewportTransform: MPRViewportTransform(rotationRadians: .pi / 2),
            flipHorizontal: true,
            shutter: .rectangular(min: SIMD2<Float>(0.25, 0.25),
                                  max: SIMD2<Float>(0.75, 0.75)),
            graphicAnnotations: [
                MPRPresentationGraphicAnnotation(
                    id: "annotation-1",
                    kind: .polyline,
                    axis: .axial,
                    normalizedImagePoints: [SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.8, 0.7)],
                    layerName: "AI"
                )
            ]
        )

        await controller.applyMPRPresentationState(presentationState, to: .axial)

        XCTAssertEqual(controller.windowLevel.range, 0...100)
        XCTAssertTrue(controller.isMPRWindowInverted)
        XCTAssertEqual(controller.viewportTransform(for: .axial).rotationRadians, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(controller.mprPresentationStates[.axial]?.shutter, presentationState.shutter)
        XCTAssertEqual(controller.mprROIAnnotations(for: .axial).count, 1)
        XCTAssertEqual(controller.mprROIAnnotations(for: .axial).first?.seriesIdentifier, "pr-1")
    }

    func testRTStructureContourOverlaysAppearInMPRAnnotationsWithConfigurableTolerance() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let overlay = RTStructureContourOverlay(
            id: "rt-overlay",
            contours: [
                RTStructureContour(
                    roiNumber: 3,
                    label: "Target",
                    geometricType: "CLOSED_PLANAR",
                    patientPoints: [
                        SIMD3<Double>(1, 1, 2),
                        SIMD3<Double>(3, 1, 2),
                        SIMD3<Double>(3, 3, 2),
                        SIMD3<Double>(1, 3, 2)
                    ]
                )
            ]
        )

        controller.setRTStructureContourOverlays([overlay])
        controller.setRTStructureContourSliceTolerance(0.1)
        await controller.setMPRSlicePosition(axis: .axial, normalizedPosition: 2.0 / 3.0)

        var annotations = controller.mprROIAnnotations(for: .axial)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].kind, .closedPath)
        XCTAssertEqual(annotations[0].text, "Target")

        await controller.setMPRSlicePosition(axis: .axial, normalizedPosition: 1)
        XCTAssertTrue(controller.mprROIAnnotations(for: .axial).isEmpty)

        controller.setRTStructureContourSliceTolerance(1.1)
        annotations = controller.mprROIAnnotations(for: .axial)
        XCTAssertEqual(annotations.count, 1)
    }

    func testMPRAdvancedROIAnnotationsUseNativeMeasurementContract() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let angle = try XCTUnwrap(controller.addMPRROIAnnotation(
            kind: .angle,
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 1, y: 0),
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0, y: 1)
            ]
        ))
        let ellipse = try XCTUnwrap(controller.addMPRROIAnnotation(
            kind: .ellipse,
            axis: .axial,
            normalizedImagePoints: ViewerROIPointFactory.points(
                kind: .ellipse,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 1, y: 1)
            )
        ))
        let freehand = try XCTUnwrap(controller.addMPRROIAnnotation(
            kind: .scribble,
            axis: .axial,
            normalizedImagePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        ))

        XCTAssertEqual(angle.measurementModel, .angle)
        XCTAssertEqual(angle.measurementUnit, .degrees)
        XCTAssertEqual(try XCTUnwrap(angle.measurement?.primaryValue), 90, accuracy: 0.001)
        XCTAssertEqual(ellipse.measurementModel, .ellipse)
        XCTAssertEqual(ellipse.measurementUnit, .squareMillimeters)
        XCTAssertEqual(try XCTUnwrap(ellipse.measurement?.primaryValue), Double.pi * 2.25, accuracy: 0.001)
        XCTAssertEqual(freehand.measurementModel, .freehand)
        XCTAssertEqual(freehand.measurementUnit, .millimeters)
        XCTAssertEqual(try XCTUnwrap(freehand.measurement?.primaryValue), 3, accuracy: 0.001)

        await controller.setVolumeLayers([try makeLabelmapLayer()])
        let volume = try controller.labelmapVolumeSummary(layerID: "ui-grid-layer", label: 1)

        XCTAssertEqual(volume.voxelCount, 64)
        XCTAssertEqual(volume.measurement.unit, .cubicMillimeters)
        XCTAssertEqual(volume.volumeCubicMillimeters, 64, accuracy: 0.001)
    }

    func testMPRVolumeROIAnnotationIsDisabledUntilDrawnVolumeMeasurementExists() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let annotation = controller.addMPRROIAnnotation(
            kind: .volume,
            axis: .axial,
            normalizedImagePoints: [
                CGPoint(x: 0.1, y: 0.1),
                CGPoint(x: 0.8, y: 0.8)
            ]
        )

        XCTAssertNil(annotation)
        XCTAssertTrue(controller.mprROIAnnotations(for: .axial).isEmpty)
    }

#if DEBUG
    func testWindowLevelCommitIgnoresHiddenVolumeWindowFailure() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let expected: ClosedRange<Int32> = (-20)...100
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)
        let volumeWindowBefore = await controller.engine.debugWindow(for: controller.volumeViewportID)

        controller.debugWindowConfigurationFailureViewports = [controller.volumeViewportID]
        await controller.setMPRWindowLevel(window: 120, level: 40)

        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        let volumeWindowAfter = await controller.engine.debugWindow(for: controller.volumeViewportID)
        XCTAssertEqual(axialWindow, expected)
        XCTAssertEqual(coronalWindow, expected)
        XCTAssertEqual(sagittalWindow, expected)
        XCTAssertEqual(volumeWindowAfter, volumeWindowBefore)
        XCTAssertEqual(controller.windowLevel.range, expected)
        XCTAssertEqual(controller.committedMPRWindowRange, expected)
        XCTAssertTrue(zip(controller.mprViewportIDs, mprBefore).allSatisfy { pair in
            controller.debugRenderGeneration(for: pair.0) > pair.1
        })
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.volumeViewportID), volumeBefore)
    }
#endif

    func testWindowLevelUpdatesDoNotCreateCrosshairFeedbackLoop() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        // Move crosshair (which triggers perpendicular slice updates).
        await controller.setCrosshair(in: .axial, normalizedPoint: CGPoint(x: 0.2, y: 0.8))

        let beforePositions = controller.normalizedPositions
        let beforeOffsets = controller.crosshairOffsets

        // Changing WL should not mutate crosshair shared state.
        await controller.setMPRWindowLevel(window: 200, level: 20)

        XCTAssertEqual(controller.normalizedPositions, beforePositions)
        XCTAssertEqual(controller.crosshairOffsets, beforeOffsets)
    }

    func testVolumeLayerControlsSyncToEngineAndScheduleOnlyMPRViewports() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let layer = try makeLabelmapLayer()
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)

        await controller.setVolumeLayers([layer])

        let axialLayers = await controller.engine.debugVolumeLayers(for: controller.axialViewportID)
        XCTAssertEqual(axialLayers, [layer])
        XCTAssertEqual(controller.volumeLayers, [layer])
        XCTAssertTrue(zip(controller.mprViewportIDs, mprBefore).allSatisfy { pair in
            controller.debugRenderGeneration(for: pair.0) > pair.1
        })
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.volumeViewportID), volumeBefore)

        await controller.setVolumeLayerVisibility(id: layer.id, isVisible: false)
        XCTAssertEqual(controller.volumeLayers.first?.isVisible, false)
        await controller.setVolumeLayerOpacity(id: layer.id, opacity: 0.25)
        XCTAssertEqual(controller.volumeLayers.first?.opacity, 0.25)
    }

    func testSurfaceMeshLayerControlsSyncToVolumeViewportWithoutSchedulingHiddenRender() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let layer = makeSurfaceMeshLayer()
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)

        await controller.setSurfaceMeshLayers([layer])

        let volumeLayers = await controller.engine.debugSurfaceMeshLayers(for: controller.volumeViewportID)
        XCTAssertEqual(volumeLayers, [layer])
        XCTAssertEqual(controller.surfaceMeshLayers, [layer])
        for viewportID in controller.mprViewportIDs {
            let mprSurfaceLayers = await controller.engine.debugSurfaceMeshLayers(for: viewportID)
            XCTAssertEqual(mprSurfaceLayers, [])
        }
        XCTAssertTrue(zip(controller.mprViewportIDs, mprBefore).allSatisfy { pair in
            controller.debugRenderGeneration(for: pair.0) == pair.1
        })
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.volumeViewportID), volumeBefore)

        await controller.setSurfaceMeshLayerVisibility(id: layer.id, isVisible: false)
        XCTAssertEqual(controller.surfaceMeshLayers.first?.isVisible, false)
        await controller.setSurfaceMeshLayerOpacity(id: layer.id, opacity: 0.25)
        XCTAssertEqual(controller.surfaceMeshLayers.first?.opacity, 0.25)
    }

    func testCrosshairPointUpdateIsDeterministicAndDoesNotFeedback() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        // Apply the same crosshair point twice.
        await controller.setCrosshair(in: .axial, normalizedPoint: CGPoint(x: 0.33, y: 0.66))
        let afterFirstPositions = controller.normalizedPositions
        let afterFirstOffsets = controller.crosshairOffsets
        let mprBefore = renderGenerationsByViewport(for: controller.mprViewportIDs, in: controller)

        await controller.setCrosshair(in: .axial, normalizedPoint: CGPoint(x: 0.33, y: 0.66))

        // No drift in stored state implies no feedback accumulation.
        XCTAssertEqual(controller.normalizedPositions, afterFirstPositions)
        XCTAssertEqual(controller.crosshairOffsets, afterFirstOffsets)

        // Also assert we didn't schedule additional renders for the unchanged second application.
        // Note: we allow the originating axis to re-render due to "responsive UI" offset updates,
        // but perpendicular axes should not keep scheduling.
        let mprAfter = renderGenerationsByViewport(for: controller.mprViewportIDs, in: controller)
        XCTAssertEqual(mprAfter[controller.coronalViewportID], mprBefore[controller.coronalViewportID])
        XCTAssertEqual(mprAfter[controller.sagittalViewportID], mprBefore[controller.sagittalViewportID])
    }

    func testCrosshairPointUpdatesPerpendicularMPRSlicePositions() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.setCrosshair(in: .axial, normalizedPoint: CGPoint(x: 0.25, y: 0.75))

        let sagittalSliceValue = await controller.engine.debugSlicePosition(for: controller.sagittalViewportID)
        let coronalSliceValue = await controller.engine.debugSlicePosition(for: controller.coronalViewportID)
        let axialSliceValue = await controller.engine.debugSlicePosition(for: controller.axialViewportID)
        let sagittalSlice = try XCTUnwrap(sagittalSliceValue)
        let coronalSlice = try XCTUnwrap(coronalSliceValue)
        let axialSlice = try XCTUnwrap(axialSliceValue)
        XCTAssertEqual(sagittalSlice, 0.25, accuracy: 0.0001)
        XCTAssertEqual(coronalSlice, 0.75, accuracy: 0.0001)
        XCTAssertEqual(axialSlice, 0.5, accuracy: 0.0001)

        // The axis being dragged should also update its offset for responsive UI.
        let axialOffset = try XCTUnwrap(controller.crosshairOffsets[.axial])
        XCTAssertNotEqual(axialOffset, .zero)
    }

    func testCrosshairPointUsesPickingVoxelCoordinatesForSliceUpdates() async throws {
        let controller = try await makeController()
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 5, height: 7, depth: 9))
        try await controller.applyDataset(dataset)

        let target = SIMD3<Float>(1, 4, 4)
        let plane = try XCTUnwrap(controller.currentMPRPlane(for: .axial))
        let viewportSize = controller.drawableSize(for: .axial)
        let screenPoint = try VolumePicking.screenPoint(
            forWorldPoint: VolumePicking.worldPoint(forVoxelIndex: target, in: dataset),
            dataset: dataset,
            plane: plane,
            displayTransform: controller.displayTransform(for: .axial),
            outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
            viewportSize: viewportSize
        ).screenPoint
        await controller.setCrosshair(in: .axial,
                                      normalizedPoint: CGPoint(x: screenPoint.x / viewportSize.width,
                                                               y: screenPoint.y / viewportSize.height))

        let sagittalSliceValue = await controller.engine.debugSlicePosition(for: controller.sagittalViewportID)
        let coronalSliceValue = await controller.engine.debugSlicePosition(for: controller.coronalViewportID)
        let sagittalSlice = try XCTUnwrap(sagittalSliceValue)
        let coronalSlice = try XCTUnwrap(coronalSliceValue)
        XCTAssertEqual(sagittalSlice, 1.0 / 4.0, accuracy: 0.0001)
        XCTAssertEqual(coronalSlice, 4.0 / 6.0, accuracy: 0.0001)
    }

    func testCrosshairDragFromAnyMPRPaneUpdatesOneGlobalCursor() async throws {
        let controller = try await makeController()
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 5, height: 7, depth: 9))
        let target = SIMD3<Float>(1, 4, 6)
        try await controller.applyDataset(dataset)

        for axis in MTKCore.Axis.allCases {
            await controller.setSlicePosition(axis: axis,
                                              normalizedPosition: normalizedPosition(for: axis,
                                                                                     target: SIMD3<Int32>(1, 4, 6),
                                                                                     dimensions: dataset.dimensions))
            let plane = try XCTUnwrap(controller.currentMPRPlane(for: axis))
            let screen = try VolumePicking.screenPoint(
                forWorldPoint: VolumePicking.worldPoint(forVoxelIndex: target, in: dataset),
                dataset: dataset,
                plane: plane,
                displayTransform: controller.displayTransform(for: axis),
                outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
                viewportSize: CGSize(width: 1, height: 1)
            )

            await controller.setCrosshair(in: axis, normalizedPoint: screen.screenPoint)

            assertVector(controller.mprCursorVoxel, target, accuracy: 0.0001, "axis \(axis)")
            assertVector(try XCTUnwrap(controller.mprCursorWorldPoint),
                         VolumePicking.worldPoint(forVoxelIndex: target, in: dataset),
                         accuracy: 0.0001,
                         "axis \(axis)")
        }
    }

    /// Internal-invariance check: projecting the cursor with the same math
    /// used for picking always yields the same voxel. This is intentionally
    /// circular — both sides of the round trip share `screenPoint`/`pickMPR`.
    /// It does **not** detect aspect-fit drift between the overlay and the
    /// presented pixels; see
    /// `testCrosshairOverlayMatchesPresentationLayoutPixelOnAnisotropicPanes`
    /// for that.
    func testProjectedCrosshairCentersPickTheSameGlobalCursorVoxel() async throws {
        let controller = try await makeController()
        setMPRSurfaceSizes(controller, size: CGSize(width: 120, height: 120))
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 5, height: 7, depth: 9))
        try await controller.applyDataset(dataset)

        await controller.setCrosshair(in: .axial, normalizedPoint: CGPoint(x: 0.25, y: 4.0 / 6.0))
        controller.rebuildAllCrosshairOffsets()

        for axis in MTKCore.Axis.allCases {
            let offset = try XCTUnwrap(controller.crosshairOffsets[axis])
            let screenPoint = CGPoint(x: 60 + offset.x, y: 60 + offset.y)
            let pick = try controller.pick(in: axis, screenPoint: screenPoint)
            assertVector(pick.voxel.continuousIndex,
                         controller.mprCursorVoxel,
                         accuracy: 0.0001,
                         "axis \(axis)")
        }
    }

    /// Regression for the MPR aspect-fit letterbox bug: the crosshair overlay
    /// pixel must match the pixel where `MPRPresentationPass` (the GPU shader)
    /// renders the voxel center, including the aspect-fit layout. We compute
    /// the GPU-side pixel independently using the public
    /// `MPRPresentationLayout.aspectFit`, the same routine the shader uses,
    /// and compare it against the controller's overlay offset.
    func testCrosshairOverlayMatchesPresentationLayoutPixelOnAnisotropicPanes() async throws {
        let controller = try await makeController()
        let drawable = CGSize(width: 200, height: 200)
        setMPRSurfaceSizes(controller, size: drawable)
        // Spacing (0.8, 1.2, 2.4) makes coronal & sagittal panes letterbox
        // when shown in a square drawable (physicalAspectRatio ≈ 1/6 and
        // 0.375 respectively).
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 5, height: 7, depth: 9))
        try await controller.applyDataset(dataset)

        // Off-center voxel: with the bug, coronal/sagittal overlays drift
        // away from the rendered voxel pixel. With the fix they coincide.
        let targetVoxel = SIMD3<Float>(1, 4, 6)
        controller.setMPRCursorVoxel(targetVoxel, in: dataset)
        controller.rebuildAllCrosshairOffsets()

        let world = VolumePicking.worldPoint(forVoxelIndex: targetVoxel, in: dataset)
        for axis in MTKCore.Axis.allCases {
            let plane = try XCTUnwrap(controller.currentMPRPlane(for: axis))

            // Step 1: image-screen [0,1] coords WITHOUT layout. This is what
            // the GPU shader receives as `imageUV` after sampling the slab.
            let imageScreenPoint = try VolumePicking.screenPoint(
                forWorldPoint: world,
                dataset: dataset,
                plane: plane,
                displayTransform: controller.displayTransform(for: axis),
                outputAspect: .fill,
                viewportSize: CGSize(width: 1, height: 1)
            ).normalizedPoint

            // Step 2: apply the same aspect-fit layout the shader applies.
            let layout = MPRPresentationLayout.aspectFit(
                contentAspectRatio: plane.physicalAspectRatio,
                destinationWidth: Int(drawable.width),
                destinationHeight: Int(drawable.height)
            )
            let viewportNormalized = layout.viewportPoint(fromImagePoint: imageScreenPoint)
            let expectedPixel = CGPoint(
                x: CGFloat(viewportNormalized.x) * drawable.width,
                y: CGFloat(viewportNormalized.y) * drawable.height
            )

            // Step 3: actual overlay pixel (drawable center + crosshairOffset).
            let offset = try XCTUnwrap(controller.crosshairOffsets[axis])
            let actualPixel = CGPoint(
                x: drawable.width * 0.5 + offset.x,
                y: drawable.height * 0.5 + offset.y
            )

            XCTAssertEqual(actualPixel.x, expectedPixel.x, accuracy: 1.0, "axis \(axis) X mismatch")
            XCTAssertEqual(actualPixel.y, expectedPixel.y, accuracy: 1.0, "axis \(axis) Y mismatch")
        }
    }

    func testCrosshairDragInAspectFitLetterboxBandIsIgnored() async throws {
        let controller = try await makeController()
        let drawable = CGSize(width: 200, height: 200)
        setMPRSurfaceSizes(controller, size: drawable)
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 5, height: 7, depth: 9))
        try await controller.applyDataset(dataset)

        let initialVoxel = SIMD3<Float>(2, 3, 4)
        controller.setMPRCursorVoxel(initialVoxel, in: dataset)
        controller.rebuildAllCrosshairOffsets()
        let positionsBefore = controller.normalizedPositions
        let offsetsBefore = controller.crosshairOffsets
        let worldBefore = try XCTUnwrap(controller.mprCursorWorldPoint)

        let coronalPlane = try XCTUnwrap(controller.currentMPRPlane(for: .coronal))
        let layout = MPROutputAspect
            .aspectFit(physicalAspectRatio: coronalPlane.physicalAspectRatio)
            .layout(destinationSize: drawable)
        XCTAssertGreaterThan(layout.origin.x, 0)
        let letterboxPoint = CGPoint(x: CGFloat(layout.origin.x * 0.5), y: 0.5)

        await controller.setCrosshair(in: .coronal, normalizedPoint: letterboxPoint)

        assertVector(controller.mprCursorVoxel, initialVoxel, accuracy: 0.0001)
        assertVector(try XCTUnwrap(controller.mprCursorWorldPoint), worldBefore, accuracy: 0.0001)
        XCTAssertEqual(controller.normalizedPositions, positionsBefore)
        XCTAssertEqual(controller.crosshairOffsets, offsetsBefore)
    }

    func testClinicalSessionPickReturnsIntensityAndLabelForMPRViewport() async throws {
        let controller = try await makeController()
        setSurfaceSize(controller.axialSurface, size: CGSize(width: 100, height: 100))
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        try await controller.applyDataset(dataset)
        await controller.setSlicePosition(axis: .axial, normalizedPosition: 2.0 / 3.0)
        await controller.setVolumeLayers([try makeTargetLabelmapLayer(label: 9,
                                                                       target: SIMD3<Int32>(1, 2, 2),
                                                                       baseDataset: dataset)])

        let session = ClinicalViewportSession(controller: controller)
        let targetUV = SIMD2<Float>(1.0 / 3.0, 2.0 / 3.0)
        let screenPoint = session.displayTransform(for: .axial).screenCoordinates(forTexture: targetUV)
        let viewportSize = session.drawableSize(for: .axial)
        let pick = try session.pick(
            in: session.axialViewportID,
            screenPoint: CGPoint(x: CGFloat(screenPoint.x) * viewportSize.width,
                                 y: CGFloat(screenPoint.y) * viewportSize.height)
        )

        XCTAssertEqual(pick.hitKind, .mprPlane(.z))
        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(1, 2, 2))
        XCTAssertEqual(pick.intensity.storedScalar, 221)
        XCTAssertEqual(pick.label?.label, 9)
    }

    func testClinicalSessionPickAndROIStatisticsExposeQuantitativeScalarValues() async throws {
        let controller = try await makeController()
        setSurfaceSize(controller.axialSurface, size: CGSize(width: 100, height: 100))
        let dataset = makePickingDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        let target = SIMD3<Int32>(1, 2, 2)
        try await controller.applyDataset(dataset)
        await controller.setSlicePosition(axis: .axial, normalizedPosition: 2.0 / 3.0)
        await controller.setVolumeLayers([
            makeQuantitativeScalarLayer(id: "pet-suv", baseDataset: dataset),
            try makeTargetLabelmapLayer(label: 9, target: target, baseDataset: dataset)
        ])

        let session = ClinicalViewportSession(controller: controller)
        let targetUV = SIMD2<Float>(1.0 / 3.0, 2.0 / 3.0)
        let screenPoint = session.displayTransform(for: .axial).screenCoordinates(forTexture: targetUV)
        let viewportSize = session.drawableSize(for: .axial)
        let pick = try session.pick(
            in: session.axialViewportID,
            screenPoint: CGPoint(x: CGFloat(screenPoint.x) * viewportSize.width,
                                 y: CGFloat(screenPoint.y) * viewportSize.height)
        )

        let scalarSample = try XCTUnwrap(pick.scalarSamples.first { $0.layerID == "pet-suv" })
        XCTAssertEqual(try XCTUnwrap(scalarSample.quantitativeValue).value, 22.1, accuracy: 1e-6)

        let statistics = try session.quantitativeScalarStatistics(layerID: "pet-suv",
                                                                  roiLayerID: "target-label",
                                                                  label: 9)
        XCTAssertEqual(statistics.sampleCount, 1)
        XCTAssertEqual(statistics.meanValue, 22.1, accuracy: 1e-6)
        XCTAssertEqual(statistics.unitsLabel, "SUV body weight")
        XCTAssertEqual(statistics.legendTitle, "SUV")
    }

    func testDicomGeometryCrosshairClicksSynchronizePerpendicularMPRAxes() async throws {
        let controller = try await makeController()
        let dataset = makeDicomPickingDataset()
        let target = dicomPickingTarget
        try await controller.applyDataset(dataset)

        for axis in MTKCore.Axis.allCases {
            await controller.setSlicePosition(axis: axis,
                                              normalizedPosition: normalizedPosition(for: axis,
                                                                                     target: target,
                                                                                     dimensions: dataset.dimensions))
            let screenPoint = try mprScreenPoint(for: target,
                                                 axis: axis,
                                                 dataset: dataset,
                                                 controller: controller,
                                                 viewportSize: CGSize(width: 1, height: 1))

            await controller.setCrosshair(in: axis, normalizedPoint: screenPoint)

            for affectedAxis in controller.perpendicularAxes(to: axis) {
                let actual = try XCTUnwrap(controller.normalizedPositions[affectedAxis])
                XCTAssertEqual(actual,
                               normalizedPosition(for: affectedAxis,
                                                  target: target,
                                                  dimensions: dataset.dimensions),
                               accuracy: 0.0001,
                               "\(axis) click should update \(affectedAxis)")
            }
        }
    }

    func testClinicalSessionPickUsesDicomGeometryAfterResizeWindowAndTransferChanges() async throws {
        let controller = try await makeController()
        setMPRSurfaceSizes(controller, size: CGSize(width: 100, height: 100))
        let dataset = makeDicomPickingDataset()
        let target = dicomPickingTarget
        try await controller.applyDataset(dataset)
        await controller.setVolumeLayers([try makeTargetLabelmapLayer(label: 13,
                                                                       target: target,
                                                                       baseDataset: dataset)])
        let session = ClinicalViewportSession(controller: controller)

        let before = try await pickDicomTarget(axis: .axial,
                                               target: target,
                                               dataset: dataset,
                                               controller: controller,
                                               session: session)

        await controller.setMPRWindowLevel(window: 80, level: 40)
        try await controller.setTransferFunction(TransferFunction())
        setMPRSurfaceSizes(controller, size: CGSize(width: 180, height: 120))

        for axis in MTKCore.Axis.allCases {
            let pick = try await pickDicomTarget(axis: axis,
                                                 target: target,
                                                 dataset: dataset,
                                                 controller: controller,
                                                 session: session)

            XCTAssertEqual(pick.voxel.index, target, "\(axis)")
            XCTAssertEqual(pick.intensity.storedScalar, before.intensity.storedScalar, "\(axis)")
            XCTAssertEqual(pick.intensity.hounsfieldUnits,
                           before.intensity.hounsfieldUnits,
                           accuracy: 0.0001,
                           "\(axis)")
            XCTAssertEqual(pick.label?.label, 13, "\(axis)")
            assertVector(pick.worldPoint,
                         dataset.worldPoint(for: target),
                         accuracy: 0.0001,
                         "patient coordinate mismatch for \(axis)")
        }
    }

    func testUpdateCrosshairPositionsMapsSliceToPerpendicularOffsets() async throws {
        let controller = try await makeController()
        setSurfaceSize(controller.coronalSurface, size: CGSize(width: 120, height: 80))
        setSurfaceSize(controller.sagittalSurface, size: CGSize(width: 120, height: 80))

        let changedAxes = controller.updateCrosshairPositions(changedAxis: .axial,
                                                              newNormalizedPosition: 0.75)

        let coronalOffset = try XCTUnwrap(controller.crosshairOffsets[.coronal])
        let sagittalOffset = try XCTUnwrap(controller.crosshairOffsets[.sagittal])
        XCTAssertEqual(Set(changedAxes), Set([.coronal, .sagittal]))
        XCTAssertEqual(coronalOffset.x, 0, accuracy: 0.0001)
        XCTAssertEqual(coronalOffset.y, -20, accuracy: 0.0001)
        XCTAssertEqual(sagittalOffset.x, 0, accuracy: 0.0001)
        XCTAssertEqual(sagittalOffset.y, -20, accuracy: 0.0001)
        XCTAssertEqual(controller.crosshairOffsets[.axial], .zero)
    }

    func testSliceScrollUpdatesCrosshairAndMatchingViewportSlice() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.scrollSlice(axis: .axial, deltaNormalized: 0.2)

        let axialSliceValue = await controller.engine.debugSlicePosition(for: controller.axialViewportID)
        let axialSlice = try XCTUnwrap(axialSliceValue)
        let normalizedAxial = try XCTUnwrap(controller.normalizedPositions[.axial])
        XCTAssertEqual(normalizedAxial, 0.7, accuracy: 0.0001)
        XCTAssertEqual(axialSlice, 0.7, accuracy: 0.0001)
    }

    func testStepSliceScrollMovesByWholeSlices() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.scrollSlice(axis: .axial, steps: 1)

        var axialSliceValue = await controller.engine.debugSlicePosition(for: controller.axialViewportID)
        var axialSlice = try XCTUnwrap(axialSliceValue)
        var normalizedAxial = try XCTUnwrap(controller.normalizedPositions[.axial])
        XCTAssertEqual(normalizedAxial, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(axialSlice, 2.0 / 3.0, accuracy: 0.0001)

        await controller.scrollSlice(axis: .axial, steps: -1)

        axialSliceValue = await controller.engine.debugSlicePosition(for: controller.axialViewportID)
        axialSlice = try XCTUnwrap(axialSliceValue)
        normalizedAxial = try XCTUnwrap(controller.normalizedPositions[.axial])
        XCTAssertEqual(normalizedAxial, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(axialSlice, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testStepSliceScrollUpdatesActiveAxisAndOnlyRequestedSlice() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let initialPositions = controller.normalizedPositions
        let initialWindowLevel = controller.windowLevel

        await controller.scrollSlice(axis: .coronal, steps: 1)

        let coronalSliceValue = await controller.engine.debugSlicePosition(for: controller.coronalViewportID)
        let coronalSlice = try XCTUnwrap(coronalSliceValue)
        let normalizedCoronal = try XCTUnwrap(controller.normalizedPositions[.coronal])
        let initialAxial = try XCTUnwrap(initialPositions[.axial])
        let initialSagittal = try XCTUnwrap(initialPositions[.sagittal])
        let normalizedAxial = try XCTUnwrap(controller.normalizedPositions[.axial])
        let normalizedSagittal = try XCTUnwrap(controller.normalizedPositions[.sagittal])
        XCTAssertEqual(controller.activeMPRAxis, .coronal)
        XCTAssertEqual(normalizedCoronal, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(coronalSlice, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(normalizedAxial, initialAxial, accuracy: 0.0001)
        XCTAssertEqual(normalizedSagittal, initialSagittal, accuracy: 0.0001)
        XCTAssertEqual(controller.windowLevel.window, initialWindowLevel.window, accuracy: 0.0001)
        XCTAssertEqual(controller.windowLevel.level, initialWindowLevel.level, accuracy: 0.0001)
    }

    func testMPRScrollStepMapperMatchesClinicalThresholds() {
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 6, hasPreciseScrollingDeltas: true), 1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -6, hasPreciseScrollingDeltas: true), -1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 5, hasPreciseScrollingDeltas: true), 0)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 0.6, hasPreciseScrollingDeltas: false), 1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -0.6, hasPreciseScrollingDeltas: false), -1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 0.5, hasPreciseScrollingDeltas: false), 0)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -0.5, hasPreciseScrollingDeltas: false), 0)
    }

    func testMPRRotationDragAngleCalculationNormalizesDelta() {
        let center = CGPoint(x: 100, y: 100)

        let quarterTurn = ClinicalViewportGridController.rotationAngleDegrees(
            initialAngleDegrees: 350,
            center: center,
            startLocation: CGPoint(x: 200, y: 100),
            currentLocation: CGPoint(x: 100, y: 200)
        )
        let counterTurn = ClinicalViewportGridController.rotationAngleDegrees(
            initialAngleDegrees: 10,
            center: center,
            startLocation: CGPoint(x: 200, y: 100),
            currentLocation: CGPoint(x: 100, y: 0)
        )

        XCTAssertEqual(quarterTurn, 80, accuracy: 0.0001)
        XCTAssertEqual(counterTurn, 280, accuracy: 0.0001)
    }

    func testCrosshairRotationConfiguresObliquePlanesForPerpendicularMPRViews() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let initialAxialGeometry = await controller.engine.debugMPRPlaneGeometry(for: controller.axialViewportID)
        let initialCoronalGeometry = await controller.engine.debugMPRPlaneGeometry(for: controller.coronalViewportID)
        let initialSagittalGeometry = await controller.engine.debugMPRPlaneGeometry(for: controller.sagittalViewportID)
        let initialAxial = try XCTUnwrap(initialAxialGeometry)
        let initialCoronal = try XCTUnwrap(initialCoronalGeometry)
        let initialSagittal = try XCTUnwrap(initialSagittalGeometry)

        controller.setCrosshairAngle(30, for: .axial)

        let currentAxial = try XCTUnwrap(controller.currentMPRPlane(for: .axial))
        let currentCoronal = try XCTUnwrap(controller.currentMPRPlane(for: .coronal))
        let currentSagittal = try XCTUnwrap(controller.currentMPRPlane(for: .sagittal))
        XCTAssertGreaterThan(abs(simd_dot(initialAxial.normalWorld, currentAxial.normalWorld)), 0.999)
        XCTAssertLessThan(abs(simd_dot(initialCoronal.normalWorld, currentCoronal.normalWorld)), 0.99)
        XCTAssertLessThan(abs(simd_dot(initialSagittal.normalWorld, currentSagittal.normalWorld)), 0.99)

        var configuredAxial: MPRPlaneGeometry?
        var configuredCoronal: MPRPlaneGeometry?
        var configuredSagittal: MPRPlaneGeometry?
        for _ in 0..<50 {
            let axial = await controller.engine.debugMPRPlaneGeometry(for: controller.axialViewportID)
            let coronal = await controller.engine.debugMPRPlaneGeometry(for: controller.coronalViewportID)
            let sagittal = await controller.engine.debugMPRPlaneGeometry(for: controller.sagittalViewportID)
            if let axial,
               let coronal,
               let sagittal,
               abs(simd_dot(initialAxial.normalWorld, axial.normalWorld)) > 0.999,
               abs(simd_dot(initialCoronal.normalWorld, coronal.normalWorld)) < 0.99,
               abs(simd_dot(initialSagittal.normalWorld, sagittal.normalWorld)) < 0.99 {
                configuredAxial = axial
                configuredCoronal = coronal
                configuredSagittal = sagittal
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThan(abs(simd_dot(initialAxial.normalWorld,
                                          try XCTUnwrap(configuredAxial).normalWorld)), 0.999)
        XCTAssertLessThan(abs(simd_dot(initialCoronal.normalWorld,
                                       try XCTUnwrap(configuredCoronal).normalWorld)), 0.99)
        XCTAssertLessThan(abs(simd_dot(initialSagittal.normalWorld,
                                       try XCTUnwrap(configuredSagittal).normalWorld)), 0.99)
    }

    func testMPRRotationToolPreservesPresentationStateAndResetClearsAngles() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        await controller.setMPRSlabThickness(7)
        let initialWindowLevel = controller.windowLevel
        let initialSlab = controller.slabThickness

        controller.setMPRInteractionTool(.rotation)
        controller.setCrosshairAngle(35, for: .axial)

        XCTAssertEqual(controller.mprInteractionTool, .rotation)
        XCTAssertEqual(controller.crosshairAngles[.axial], 35)
        XCTAssertNil(controller.mprPlaneRotationsByAxis[.axial])
        XCTAssertNotNil(controller.mprPlaneRotationsByAxis[.coronal])
        XCTAssertNotNil(controller.mprPlaneRotationsByAxis[.sagittal])
        XCTAssertEqual(controller.windowLevel, initialWindowLevel)
        XCTAssertEqual(controller.slabThickness, initialSlab, accuracy: 0.0001)

        controller.resetAllMPRViews()

        XCTAssertEqual(controller.crosshairAngles, [.axial: 0, .coronal: 0, .sagittal: 0])
        XCTAssertTrue(controller.mprPlaneRotationsByAxis.isEmpty)
        XCTAssertEqual(controller.windowLevel, initialWindowLevel)
        XCTAssertEqual(controller.slabThickness, initialSlab, accuracy: 0.0001)
    }

    func testCrosshairRotationKeepsDisplayTransformOnClinicalContract() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        controller.setCrosshairAngle(30, for: .axial)

        let coronal = controller.displayTransform(for: .coronal)
        XCTAssertEqual(coronal.labels.leading, "R")
        XCTAssertEqual(coronal.labels.trailing, "L")
        XCTAssertEqual(coronal.labels.top, "S")
        XCTAssertEqual(coronal.labels.bottom, "I")

        let sagittal = controller.displayTransform(for: .sagittal)
        XCTAssertEqual(sagittal.labels.leading, "A")
        XCTAssertEqual(sagittal.labels.trailing, "P")
        XCTAssertEqual(sagittal.labels.top, "S")
        XCTAssertEqual(sagittal.labels.bottom, "I")
    }

    func testPresentationTransformUsesRenderedPlaneGeometry() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let cached = controller.displayTransform(for: .coronal)
        let renderedPlane = makePresentationPlane(
            axisUWorld: SIMD3<Float>(0, 0, 1),
            axisVWorld: SIMD3<Float>(-1, 0, 0)
        )
        let expected = controller.displayTransform(for: renderedPlane, axis: .coronal)
        let texture = try makePresentationTexture()
        let frame = MPRTextureFrame(texture: texture,
                                    intensityRange: 0...1,
                                    pixelFormat: .int16Signed,
                                    viewportID: controller.coronalViewportID,
                                    planeGeometry: renderedPlane)

        let transform = try XCTUnwrap(controller.presentationTransform(for: controller.coronalViewportID,
                                                                       frame: frame))

        XCTAssertNotEqual(expected, cached)
        XCTAssertEqual(transform, expected)
        XCTAssertEqual(controller.displayTransformsByAxis[.coronal], expected)
    }

    func testMPRManipulationDefaultsAndTransformsArePresentationOnly() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        XCTAssertEqual(controller.activeMPRAxis, .axial)
        XCTAssertEqual(controller.mprInteractionTool, .crosshair)
        XCTAssertEqual(controller.viewportTransform(for: .axial), .identity)

        controller.setMPRInteractionTool(.pan)
        controller.setActiveMPRAxis(.sagittal)
        XCTAssertEqual(controller.mprInteractionTool, .pan)
        XCTAssertEqual(controller.activeMPRAxis, .sagittal)

        let positionsBefore = controller.normalizedPositions
        let axialSliceBefore = await controller.engine.debugSlicePosition(for: controller.axialViewportID)

        controller.panMPR(axis: .axial, deltaNormalized: SIMD2<Float>(0.1, -0.05))
        controller.zoomMPR(axis: .axial, factor: 2, anchor: SIMD2<Float>(0.25, 0.75))

        let axialTransform = controller.viewportTransform(for: .axial)
        XCTAssertGreaterThan(axialTransform.zoom, 1)
        XCTAssertNotEqual(axialTransform.pan, .zero)
        XCTAssertEqual(controller.normalizedPositions, positionsBefore)
        let axialSliceAfterTransform = await controller.engine.debugSlicePosition(for: controller.axialViewportID)
        XCTAssertEqual(axialSliceAfterTransform, axialSliceBefore)

        controller.resetMPRView(axis: .axial)
        XCTAssertEqual(controller.viewportTransform(for: .axial), .identity)

        controller.zoomMPR(axis: .coronal, factor: 2)
        controller.panMPR(axis: .coronal, deltaNormalized: SIMD2<Float>(0.2, 0.2))
        XCTAssertNotEqual(controller.viewportTransform(for: .coronal), .identity)
        controller.resetAllMPRViews()
        for axis in MTKCore.Axis.allCases {
            XCTAssertEqual(controller.viewportTransform(for: axis), .identity)
        }
    }

    func testMPRSliceSliderAndWindowLevelDragUpdateSharedClinicalState() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.setMPRSlicePosition(axis: .coronal, normalizedPosition: 0.75)
        XCTAssertEqual(controller.activeMPRAxis, .coronal)
        XCTAssertEqual(try XCTUnwrap(controller.normalizedPositions[.coronal]), 0.75, accuracy: 0.0001)
        let coronalSliceValue = await controller.engine.debugSlicePosition(for: controller.coronalViewportID)
        let coronalSlice = try XCTUnwrap(coronalSliceValue)
        XCTAssertEqual(coronalSlice, 0.75, accuracy: 0.0001)

        let previousWindowLevel = controller.windowLevel
        await controller.adjustMPRWindowLevel(screenDelta: CGSize(width: 10, height: -5))
        XCTAssertEqual(controller.windowLevel.window, previousWindowLevel.window + 20, accuracy: 0.0001)
        XCTAssertEqual(controller.windowLevel.level, previousWindowLevel.level + 10, accuracy: 0.0001)
    }

    func testUnchangedSliceScrollDoesNotScheduleRender() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let before = controller.debugRenderGeneration(for: controller.axialViewportID)

        await controller.handleSliceScroll(axis: .axial, delta: 0)

        let after = controller.debugRenderGeneration(for: controller.axialViewportID)
        XCTAssertEqual(after, before)
    }

    func testUnchangedWindowLevelDoesNotScheduleMPRRender() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let before = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }

        await controller.setMPRWindowLevel(window: controller.windowLevel.window,
                                           level: controller.windowLevel.level)

        let after = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        XCTAssertEqual(after, before)
    }

    func testSlabThicknessSyncsOnlyMPRViewports() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.setMPRSlabThickness(8)

        let axialSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        let coronalSlab = await controller.engine.debugSlabConfiguration(for: controller.coronalViewportID)
        let sagittalSlab = await controller.engine.debugSlabConfiguration(for: controller.sagittalViewportID)
        let volumeSlab = await controller.engine.debugSlabConfiguration(for: controller.volumeViewportID)
        XCTAssertEqual(axialSlab?.thickness, 9)
        XCTAssertEqual(axialSlab?.steps, 19)
        XCTAssertEqual(coronalSlab?.thickness, 9)
        XCTAssertEqual(coronalSlab?.steps, 19)
        XCTAssertEqual(sagittalSlab?.thickness, 9)
        XCTAssertEqual(sagittalSlab?.steps, 19)
        XCTAssertEqual(volumeSlab?.thickness, 1)
        XCTAssertEqual(volumeSlab?.steps, 1)
    }

    func testSlabBlendModeSyncsOnlyMPRViewports() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        XCTAssertEqual(controller.mprSlabBlendMode, .mip)

        await controller.setMPRSlabBlendMode(.mip)

        let axialSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        let coronalSlab = await controller.engine.debugSlabConfiguration(for: controller.coronalViewportID)
        let sagittalSlab = await controller.engine.debugSlabConfiguration(for: controller.sagittalViewportID)
        let volumeSlab = await controller.engine.debugSlabConfiguration(for: controller.volumeViewportID)
        XCTAssertEqual(controller.mprSlabBlendMode, .mip)
        XCTAssertEqual(axialSlab?.blend, .maximum)
        XCTAssertEqual(coronalSlab?.blend, .maximum)
        XCTAssertEqual(sagittalSlab?.blend, .maximum)
        XCTAssertEqual(volumeSlab?.blend, .single)
    }

    func testMPRImageAnnotationsStateUsesCurrentTechnicalValues() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.setMPRWindowLevel(window: 300, level: 50)
        await controller.setMPRSlabThickness(7)
        controller.zoomMPR(axis: .axial, factor: 2)
        controller.setCrosshairAngle(15, for: .axial)

        let state = controller.mprImageAnnotationsOverlayState(slotIndex: 0, axis: .axial)

        XCTAssertEqual(state.displayLines, [
            "Panel 1",
            "Image size: 4x4",
            "WW: 300 WL: 50",
            "Orientation: Axial",
            "Thickness: 7 mm",
            "Zoom: 200%",
            "Angle: 15 deg",
            "Pixel: 0"
        ])
    }

    func testMPRMetadataOverlaySettingsAreScopedPerViewport() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        controller.setMetadataOverlaySettings(
            ClinicalViewportMetadataOverlaySettings(isVisible: false),
            for: .axial
        )

        let axial = controller.mprImageAnnotationsOverlayState(slotIndex: 0, axis: .axial)
        let coronal = controller.mprImageAnnotationsOverlayState(slotIndex: 1, axis: .coronal)

        XCTAssertEqual(axial.displayLines, [])
        XCTAssertTrue(coronal.displayLines.contains("Panel 2"))
    }

    func testClinicalSessionExposesMetadataOverlaySettings() async throws {
        let controller = try await makeController()
        let session = ClinicalViewportSession(controller: controller)
        let settings = ClinicalViewportMetadataOverlaySettings(
            showsSubjectName: false,
            showsDoseValues: false
        )

        session.setMetadataOverlaySettings(settings, for: .sagittal)

        XCTAssertEqual(session.metadataOverlaySettings(for: session.sagittalViewportID), settings)
        XCTAssertEqual(session.metadataOverlaySettings(for: session.axialViewportID), .default)
        XCTAssertEqual(session.metadataOverlaySettingsByViewport[session.sagittalViewportID], settings)
    }

    func testAdaptiveInteractionUpdatesMPRQualityWithoutChangingHiddenVolumeQuality() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let initialQuality = await controller.engine.debugRenderQuality(for: controller.volumeViewportID)

        await controller.beginAdaptiveSamplingInteraction()

        XCTAssertEqual(controller.renderQualityState, .interacting)
        let previewQuality = await controller.engine.debugRenderQuality(for: controller.volumeViewportID)
        let previewSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        XCTAssertEqual(previewQuality?.quality, initialQuality?.quality)
        XCTAssertEqual(previewQuality?.samplingDistance ?? 0,
                       initialQuality?.samplingDistance ?? 0,
                       accuracy: 0.000_001)
        XCTAssertEqual(previewSlab?.steps, 5)

        await controller.endAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.renderQualityState, .settling)
        try await waitForRenderQuality(.settled, controller: controller)

        let finalQuality = await controller.engine.debugRenderQuality(for: controller.volumeViewportID)
        let finalSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        XCTAssertEqual(finalQuality?.quality, initialQuality?.quality)
        XCTAssertEqual(finalQuality?.samplingDistance ?? 0,
                       initialQuality?.samplingDistance ?? 0,
                       accuracy: 0.000_001)
        XCTAssertEqual(finalSlab?.steps, 7)
    }

    func testVolumeCameraGestureUpdatesVolumeViewportCameraOnly() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let initialVolumeCamera = await controller.engine.debugCamera(for: controller.volumeViewportID)
        let initialAxialCamera = await controller.engine.debugCamera(for: controller.axialViewportID)

        await controller.rotateVolumeCamera(screenDelta: CGSize(width: 12, height: 4))

        let updatedVolumeCamera = await controller.engine.debugCamera(for: controller.volumeViewportID)
        let updatedAxialCamera = await controller.engine.debugCamera(for: controller.axialViewportID)
        XCTAssertNotEqual(updatedVolumeCamera?.position, initialVolumeCamera?.position)
        XCTAssertEqual(updatedAxialCamera, initialAxialCamera)
    }

    func testVolumeCameraPitchIsClampedDuringDragRotation() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.rotateVolumeCamera(screenDelta: CGSize(width: 0, height: 10_000))

        XCTAssertEqual(controller.volumeCameraPitch, -1.35, accuracy: 0.0001)

        await controller.rotateVolumeCamera(screenDelta: CGSize(width: 0, height: -20_000))

        XCTAssertEqual(controller.volumeCameraPitch, 1.35, accuracy: 0.0001)
    }

    func testVolumeCameraRollRotatesUpVectorWithoutChangingOffset() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let beforeOffset = controller.volumeCameraOffset

        XCTAssertTrue(controller.tiltVolumeCameraInteractively(roll: Float.pi / 6, pitch: 0))

        XCTAssertEqual(controller.volumeCameraOffset.x, beforeOffset.x, accuracy: 0.000_1)
        XCTAssertEqual(controller.volumeCameraOffset.y, beforeOffset.y, accuracy: 0.000_1)
        XCTAssertEqual(controller.volumeCameraOffset.z, beforeOffset.z, accuracy: 0.000_1)
        XCTAssertGreaterThan(abs(controller.volumeCameraUp.x), 0.001)
        XCTAssertEqual(simd_length(controller.volumeCameraUp), 1, accuracy: 0.000_1)
    }

    func testVolumeCameraZoomUsesPinchScaleAndClampsDistance() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let initialDistance = simd_length(controller.volumeCameraOffset)

        await controller.zoomVolumeCamera(scale: 2)

        XCTAssertEqual(simd_length(controller.volumeCameraOffset),
                       initialDistance / 2,
                       accuracy: 0.0001)

        await controller.zoomVolumeCamera(scale: 0.001)

        XCTAssertEqual(simd_length(controller.volumeCameraOffset),
                       16,
                       accuracy: 0.0001)
    }

    func testVolumeCameraPanUsesDatasetDerivedBounds() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        controller.volumeCameraTarget = SIMD3<Float>(9.9, 0.5, 0.5)
        controller.volumeCameraOffset = SIMD3<Float>(0, 0, 20)
        controller.volumeCameraUp = SIMD3<Float>(0, 1, 0)
        _ = controller.volumeOrbitState.reset(target: controller.volumeCameraTarget,
                                              offset: controller.volumeCameraOffset,
                                              up: controller.volumeCameraUp,
                                              distanceLimits: 0.1...64)

        XCTAssertTrue(controller.panVolumeCameraInteractively(screenDelta: CGSize(width: -10_000,
                                                                                  height: 0)))

        XCTAssertLessThan(controller.volumeCameraTarget.x, 10)
        XCTAssertLessThanOrEqual(controller.volumeCameraTarget.x, 1.25)
        XCTAssertTrue(controller.volumeCameraTarget.x.isFinite)
    }

    func testVolumeViewport3DAndClinicalVolumeUseSameOrbitMath() async throws {
        let viewport = try VolumeViewport3D()
        let controller = try await makeController()
        let delta = CGSize(width: 40, height: -20)

        _ = viewport.applyNativeOrbitDelta(delta)
        _ = controller.rotateVolumeCameraInteractively(screenDelta: delta)

        let viewportOffset = viewport.state.camera.position - viewport.state.camera.target
        assertVector(simd_normalize(viewportOffset),
                     simd_normalize(controller.volumeCameraOffset),
                     accuracy: 0.0001)
        assertVector(viewport.state.camera.up,
                     controller.volumeCameraUp,
                     accuracy: 0.0001)
    }

    func testVolumeRenderSchedulingCoalescesInFlightRenderInsteadOfCancelling() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        await controller.renderAllAndWait()

        // Wait for asynchronous presentation callbacks to finish and clear the presentation gate
        for _ in 0..<100 {
            if controller.presentationInFlightTokens[controller.volumeViewportID] == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        let firstTask = try XCTUnwrap(controller.scheduleRender(for: controller.volumeViewportID))

        XCTAssertTrue(controller.renderInFlightViewports.contains(controller.volumeViewportID))

        let coalescedTask = controller.scheduleRender(for: controller.volumeViewportID)

        XCTAssertNotNil(coalescedTask)
        XCTAssertTrue(controller.renderInFlightViewports.contains(controller.volumeViewportID))
        XCTAssertTrue(controller.renderPendingViewports.contains(controller.volumeViewportID))

        await firstTask.value

        XCTAssertFalse(controller.renderInFlightViewports.contains(controller.volumeViewportID))
        XCTAssertFalse(controller.renderPendingViewports.contains(controller.volumeViewportID))
    }

    func testVolumeRenderSchedulingDefersWhilePresentationIsInFlight() async throws {
        let controller = try await makeController()
        controller.datasetApplied = true
        controller.presentationInFlightTokens[controller.volumeViewportID] = 7

        let task = controller.scheduleRender(for: controller.volumeViewportID)

        XCTAssertNil(task)
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.volumeViewportID), 1)
        XCTAssertTrue(controller.renderPendingViewports.contains(controller.volumeViewportID))
        XCTAssertFalse(controller.renderInFlightViewports.contains(controller.volumeViewportID))
    }

    func testTransferFunctionUpdatesHiddenVolumeStateWithoutSchedulingRender() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)
        let transferFunction = TransferFunction()

        try await controller.setTransferFunction(transferFunction)

        let mprAfter = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeAfter = controller.debugRenderGeneration(for: controller.volumeViewportID)
        XCTAssertEqual(mprAfter, mprBefore)
        XCTAssertEqual(volumeAfter, volumeBefore)
        XCTAssertEqual(controller.lastTransferFunction?.alphaPoints, transferFunction.alphaPoints)
    }

    func testVolumeViewportModeUpdatesDebugSnapshotRenderMode() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        try await controller.setVolumeViewportMode(.dvr)
        let dvrSnapshot = controller.debugSnapshot(for: controller.volumeViewportID)
        let dvrDescriptor = await controller.engine.debugDescriptor(for: controller.volumeViewportID)
        XCTAssertEqual(dvrSnapshot.viewportType, "volume3D")
        XCTAssertEqual(dvrSnapshot.renderMode, "dvr")
        XCTAssertEqual(dvrDescriptor?.type, .volume3D)

        try await controller.setVolumeViewportMode(.mip)
        let mipSnapshot = controller.debugSnapshot(for: controller.volumeViewportID)
        let mipDescriptor = await controller.engine.debugDescriptor(for: controller.volumeViewportID)
        XCTAssertEqual(mipSnapshot.viewportType, "projection(mip)")
        XCTAssertEqual(mipSnapshot.renderMode, "mip")
        XCTAssertEqual(mipDescriptor?.type, .projection(mode: .mip))

        try await controller.setVolumeViewportMode(.minip)
        let minipSnapshot = controller.debugSnapshot(for: controller.volumeViewportID)
        let minipDescriptor = await controller.engine.debugDescriptor(for: controller.volumeViewportID)
        XCTAssertEqual(minipSnapshot.viewportType, "projection(minip)")
        XCTAssertEqual(minipSnapshot.renderMode, "minip")
        XCTAssertEqual(minipDescriptor?.type, .projection(mode: .minip))

        try await controller.setVolumeViewportMode(.aip)
        let aipSnapshot = controller.debugSnapshot(for: controller.volumeViewportID)
        let aipDescriptor = await controller.engine.debugDescriptor(for: controller.volumeViewportID)
        XCTAssertEqual(aipSnapshot.viewportType, "projection(aip)")
        XCTAssertEqual(aipSnapshot.renderMode, "aip")
        XCTAssertEqual(aipDescriptor?.type, .projection(mode: .aip))
    }

    func testSchedulingVolumeRenderWithoutDatasetDoesNotRecordFailure() async throws {
        let controller = try await makeController()

        try await controller.setTransferFunction(TransferFunction())

        XCTAssertNil(controller.lastRenderError(for: controller.volumeViewportID))
    }

    func testVolumeSnapshotFrameTargetsVolumeViewportForExplicitExport() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        let frame = try await controller.renderVolumeSnapshotFrame()

        XCTAssertEqual(frame.metadata.viewportID, controller.volumeViewportID)
        XCTAssertEqual(frame.metadata.compositing, .frontToBack)
        XCTAssertEqual(frame.metadata.quality, .production)
        XCTAssertGreaterThan(frame.texture.width, 0)
        XCTAssertGreaterThan(frame.texture.height, 0)
    }

    func testMPRSnapshotFrameTargetsRequestedViewportForExplicitExport() async throws {
        let controller = try await makeController()
        setSnapshotSurfaceSizes(controller, size: CGSize(width: 64, height: 48))
        try await controller.applyDataset(makeSyntheticDataset())
        await controller.setMPRWindowLevel(window: 600, level: 80)
        controller.setMPRWindowInverted(true)
        controller.setMPRViewportTransform(
            MPRViewportTransform(zoom: 1.25,
                                 pan: SIMD2<Float>(0.08, -0.04),
                                 rotationRadians: 0),
            for: .coronal
        )

        XCTAssertTrue(controller.canExportMPRSnapshot(axis: .coronal))

        let frame = try await controller.renderMPRSnapshotFrame(axis: .coronal)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertEqual(frame.metadata.viewportID, controller.coronalViewportID)
        XCTAssertEqual(frame.metadata.compositing, .frontToBack)
        XCTAssertEqual(frame.metadata.quality, .production)
        XCTAssertEqual(frame.texture.width, 64)
        XCTAssertEqual(frame.texture.height, 48)
        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testVolumeSnapshotFrameReleasesPooledOutputTextureLease() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let releasesBefore = await controller.engine.debugOutputTextureLeaseReleasedCount

        _ = try await controller.renderVolumeSnapshotFrame()

        let outputPoolInUseCount = await controller.engine.debugOutputPoolInUseCount
        let outputLeaseReleasedCount = await controller.engine.debugOutputTextureLeaseReleasedCount
        XCTAssertEqual(outputPoolInUseCount, 0)
        XCTAssertGreaterThanOrEqual(outputLeaseReleasedCount - releasesBefore, 1)
    }

    func testVolumeSnapshotFrameWithTransferFunctionProducesVisiblePixels() async throws {
        let controller = try await makeController()
        setSnapshotSurfaceSizes(controller, size: CGSize(width: 64, height: 64))
        let dataset = makeSyntheticDataset()
        try await controller.applyDataset(dataset)
        try await controller.setTransferFunction(VolumeRenderRegressionFixture.transferFunction(for: dataset))

        let frame = try await controller.renderVolumeSnapshotFrame()
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testVolumeSnapshotFrameWithoutTransferFunctionProducesVisiblePixels() async throws {
        let controller = try await makeController()
        setSnapshotSurfaceSizes(controller, size: CGSize(width: 64, height: 64))
        try await controller.applyDataset(makeSyntheticDataset())
        try await controller.setTransferFunction(nil)

        let frame = try await controller.renderVolumeSnapshotFrame()
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testVolumeSnapshotFrameReportsMissingDatasetBeforeEngineRender() async throws {
        let controller = try await makeController()

        do {
            _ = try await controller.renderVolumeSnapshotFrame()
            XCTFail("Expected missing dataset error")
        } catch ClinicalViewportGridControllerError.noDatasetApplied {
            // Expected explicit failure mode.
        } catch {
            XCTFail("Expected noDatasetApplied, got \(error)")
        }
    }

    func testMPRSnapshotFrameReportsMissingDatasetBeforeEngineRender() async throws {
        let controller = try await makeController()

        XCTAssertFalse(controller.canExportMPRSnapshot(axis: .axial))
        do {
            _ = try await controller.renderMPRSnapshotFrame(axis: .axial)
            XCTFail("Expected missing dataset error")
        } catch ClinicalViewportGridControllerError.noDatasetApplied {
            // Expected explicit failure mode.
        } catch {
            XCTFail("Expected noDatasetApplied, got \(error)")
        }
    }

    func testShutdownDestroysViewportsAndReleasesSharedResource() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.shutdown()

        let viewportCount = await controller.engine.debugViewportCount
        let textureCount = await controller.engine.debugResourceTextureCount
        let referenceCount = await controller.engine.debugResourceReferenceCount
        XCTAssertEqual(viewportCount, 0)
        XCTAssertEqual(textureCount, 0)
        XCTAssertEqual(referenceCount, 0)
        XCTAssertNil(controller.sharedResourceHandle)
        XCTAssertFalse(controller.datasetApplied)
    }

    func testClinicalViewportGridCanBeConstructed() async throws {
        let controller = try await makeController()
        let definition = makeHangingProtocolDefinition()
        let context = HangingProtocolContext(
            current: HangingProtocolStudyDescriptor(id: "current",
                                                    role: .current,
                                                    modality: "CT",
                                                    anatomy: "Chest"),
            priors: [
                HangingProtocolStudyDescriptor(id: "prior",
                                               role: .prior,
                                               modality: "CT",
                                               anatomy: "Chest")
            ]
        )

        _ = ClinicalViewportGrid(controller: controller)
        _ = ClinicalViewportGrid(dataset: makeDataset())
        _ = ClinicalViewportGrid(controller: controller,
                                 hangingProtocolDefinition: definition,
                                 hangingProtocolContext: context)
    }

    func testApplyHangingProtocolMapsViewportSlots() async throws {
        let controller = try await makeController()
        let definition = makeHangingProtocolDefinition()
        let context = HangingProtocolContext(
            current: HangingProtocolStudyDescriptor(id: "current",
                                                    role: .current,
                                                    modality: "CT",
                                                    anatomy: "CT Chest"),
            priors: [
                HangingProtocolStudyDescriptor(id: "prior",
                                               role: .prior,
                                               modality: "CT",
                                               anatomy: "Chest")
            ]
        )

        let resolvedLayout = await controller.applyHangingProtocol(definition,
                                                                   context: context)
        let resolved = try XCTUnwrap(resolvedLayout)

        XCTAssertEqual(controller.hangingProtocolResolvedLayout, resolved)
        XCTAssertEqual(controller.hangingProtocolResolvedLayout?.screenLayout, .hSplit2x1)
        XCTAssertEqual(controller.hangingProtocolSlotAssignments.map(\.content), [
            .stack2D(.axial),
            .stack2D(.axial),
            .volume3D
        ])
        XCTAssertEqual(controller.hangingProtocolSlotAssignments.map(\.studyRole), [.current, .prior, .current])
        XCTAssertEqual(controller.hangingProtocolViewportContent(for: 2), .stack2D(.axial))
    }

    private func makeController() async throws -> ClinicalViewportGridController {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return try await ClinicalViewportGridController(device: device,
                                                        initialViewportSize: CGSize(width: 32, height: 32))
    }

    private func assertMPRWindows(controller: ClinicalViewportGridController,
                                  expected: ClosedRange<Int32>,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async throws {
        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        XCTAssertEqual(axialWindow, expected, file: file, line: line)
        XCTAssertEqual(coronalWindow, expected, file: file, line: line)
        XCTAssertEqual(sagittalWindow, expected, file: file, line: line)
    }

    private func makeDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        return VolumeDataset(
            data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: (-100)...300
        )
    }

    private func makeHangingProtocolDefinition() -> HangingProtocolDefinition {
        HangingProtocolDefinition(
            id: "ct-chest-follow-up",
            displayName: "CT Chest Follow-up",
            displaySets: [
                HangingProtocolDisplaySetDefinition(
                    id: "current",
                    role: .current,
                    filter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"])
                ),
                HangingProtocolDisplaySetDefinition(
                    id: "prior",
                    role: .prior,
                    filter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"])
                )
            ],
            rules: [
                HangingProtocolRule(
                    id: "ct-chest-current-prior",
                    priority: 10,
                    currentFilter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"]),
                    requiredPriorFilter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"]),
                    layout: HangingProtocolLayoutDefinition(
                        screenLayout: .hSplit2x1,
                        viewports: [
                            HangingProtocolViewportDefinition(slot: 1,
                                                              displaySetID: "current",
                                                              content: .stack2D(.axial)),
                            HangingProtocolViewportDefinition(slot: 2,
                                                              displaySetID: "prior",
                                                              content: .stack2D(.axial)),
                            HangingProtocolViewportDefinition(slot: 3,
                                                              displaySetID: "current",
                                                              content: .volume3D)
                        ]
                    )
                )
            ]
        )
    }

    private func makePresentationTexture() throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Sint,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makePresentationPlane(axisUWorld: SIMD3<Float>,
                                       axisVWorld: SIMD3<Float>) -> MPRPlaneGeometry {
        let normal = simd_normalize(simd_cross(axisUWorld, axisVWorld))
        return MPRPlaneGeometry(originVoxel: .zero,
                                axisUVoxel: axisUWorld,
                                axisVVoxel: axisVWorld,
                                originWorld: .zero,
                                axisUWorld: axisUWorld,
                                axisVWorld: axisVWorld,
                                originTexture: .zero,
                                axisUTexture: axisUWorld,
                                axisVTexture: axisVWorld,
                                normalWorld: normal)
    }

    private func makeLabelmapLayer() throws -> VolumeLayer {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values = [UInt16](repeating: 1, count: dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [LabelmapSegment(label: 1, color: SIMD4<Float>(1, 0, 0, 1))]
        )
        return VolumeLayer(id: "ui-grid-layer",
                           labelmap: labelmap,
                           opacity: 0.5)
    }

    private func makeSurfaceMeshLayer() -> SurfaceMeshLayer {
        let mesh = SurfaceMesh(
            id: "ui-grid-surface-mesh",
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
        return SurfaceMeshLayer(id: "ui-grid-surface-layer",
                                mesh: mesh,
                                material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1)),
                                opacity: 0.5)
    }

    private func makeTargetLabelmapLayer(label: UInt16,
                                         target: SIMD3<Int32>,
                                         baseDataset: VolumeDataset) throws -> VolumeLayer {
        let dimensions = baseDataset.dimensions
        var values = [UInt16](repeating: 0, count: dimensions.voxelCount)
        let index = Int(target.z) * dimensions.width * dimensions.height
            + Int(target.y) * dimensions.width
            + Int(target.x)
        values[index] = label
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: baseDataset.spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...Int32(label),
            orientation: baseDataset.orientation
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [LabelmapSegment(label: label, color: SIMD4<Float>(1, 0, 0, 1))]
        )
        return VolumeLayer(id: "target-label",
                           labelmap: labelmap,
                           opacity: 1)
    }

    private func makeQuantitativeScalarLayer(id: String,
                                             baseDataset: VolumeDataset) -> VolumeLayer {
        var values: [Int16] = []
        values.reserveCapacity(baseDataset.dimensions.voxelCount)
        var physicalValues: [Double] = []
        physicalValues.reserveCapacity(baseDataset.dimensions.voxelCount)
        for z in 0..<baseDataset.dimensions.depth {
            for y in 0..<baseDataset.dimensions.height {
                for x in 0..<baseDataset.dimensions.width {
                    let stored = Int16(x + y * 10 + z * 100)
                    values.append(stored)
                    physicalValues.append(Double(stored) / 10.0)
                }
            }
        }
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: baseDataset.dimensions,
            spacing: baseDataset.spacing,
            pixelFormat: .int16Signed,
            intensityRange: 0...900,
            orientation: baseDataset.orientation,
            recommendedWindow: 0...900,
            clinicalMetadata: ClinicalImageMetadata(modality: "PT",
                                                    frameOfReferenceUID: baseDataset.imageData.clinicalMetadata?.frameOfReferenceUID)
        )
        let mapping = QuantitativeScalarMapping(
            units: QuantitativeCodedConcept(codeValue: "g/ml{SUVbw}",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "SUV body weight"),
            physicalRange: 0...90,
            storedValueRange: 0...900,
            physicalValues: physicalValues,
            legendTitle: "SUV"
        )
        let scalarVolume = ScalarVolumeLayer(dataset: dataset,
                                             transferFunction: .defaultGrayscale(for: dataset),
                                             quantitativeMapping: mapping)
        return VolumeLayer(id: id,
                           scalarVolume: scalarVolume,
                           opacity: 0.5,
                           blendMode: .additive)
    }

    private func makePickingDataset(dimensions: VolumeDimensions) -> VolumeDataset {
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(Int16(x + y * 10 + z * 100))
                }
            }
        }
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.8, y: 1.2, z: 2.4),
            pixelFormat: .int16Signed,
            intensityRange: 0...900,
            recommendedWindow: 0...900
        )
    }

    private var dicomPickingTarget: SIMD3<Int32> {
        SIMD3<Int32>(2, 3, 4)
    }

    private func makeDicomPickingDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 5, height: 6, depth: 7)
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(Int16(x + y * 10 + z * 100))
                }
            }
        }

        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.8, y: 1.2, z: 2.4),
            pixelFormat: .int16Signed,
            intensityRange: 0...900,
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, -1, 0),
                                           origin: SIMD3<Float>(10, -20, 5)),
            recommendedWindow: 0...900,
            clinicalMetadata: ClinicalImageMetadata(modality: "CT",
                                                    seriesDescription: "DICOM oriented picking fixture",
                                                    rescaleSlope: 1,
                                                    rescaleIntercept: -1024,
                                                    sourcePixelFormat: .int16Signed)
        )
    }

    private func pickDicomTarget(axis: MTKCore.Axis,
                                 target: SIMD3<Int32>,
                                 dataset: VolumeDataset,
                                 controller: ClinicalViewportGridController,
                                 session: ClinicalViewportSession) async throws -> VolumePickResult {
        await session.setMPRSlicePosition(axis: axis,
                                          normalizedPosition: normalizedPosition(for: axis,
                                                                                 target: target,
                                                                                 dimensions: dataset.dimensions))
        let screenPoint = try mprScreenPoint(for: target,
                                             axis: axis,
                                             dataset: dataset,
                                             controller: controller,
                                             viewportSize: session.drawableSize(for: axis))
        return try session.pick(in: session.viewportID(for: axis),
                                screenPoint: screenPoint)
    }

    private func mprScreenPoint(for target: SIMD3<Int32>,
                                axis: MTKCore.Axis,
                                dataset: VolumeDataset,
                                controller: ClinicalViewportGridController,
                                viewportSize: CGSize) throws -> CGPoint {
        let planeAxis = controller.planeAxis(for: axis)
        let plane = MPRPlaneGeometryFactory.makePlane(
            for: dataset,
            axis: planeAxis,
            slicePosition: normalizedPosition(for: axis,
                                              target: target,
                                              dimensions: dataset.dimensions)
        )
        let screen = try VolumePicking.screenPoint(forWorldPoint: dataset.worldPoint(for: target),
                                                   dataset: dataset,
                                                   plane: plane,
                                                   displayTransform: controller.displayTransform(for: plane, axis: axis),
                                                   outputAspect: .aspectFit(physicalAspectRatio: plane.physicalAspectRatio),
                                                   viewportSize: viewportSize)
        return screen.screenPoint
    }

    private func normalizedPosition(for axis: MTKCore.Axis,
                                    target: SIMD3<Int32>,
                                    dimensions: VolumeDimensions) -> Float {
        switch axis {
        case .axial:
            return normalizedPosition(component: target.z, count: dimensions.depth)
        case .coronal:
            return normalizedPosition(component: target.y, count: dimensions.height)
        case .sagittal:
            return normalizedPosition(component: target.x, count: dimensions.width)
        }
    }

    private func normalizedPosition(component: Int32, count: Int) -> Float {
        guard count > 1 else { return 0 }
        return Float(component) / Float(count - 1)
    }

    private func makeSyntheticDataset() -> VolumeDataset {
        VolumeRenderRegressionFixture.dataset()
    }

    private func imageContainsVisiblePixels(_ image: CGImage) -> Bool {
        VolumeRenderRegressionFixture.imageContainsVisiblePixels(image)
    }

    private func setSurfaceSize(_ surface: MetalViewportSurface, size: CGSize) {
        surface.view.frame = CGRect(origin: .zero, size: size)
        surface.setContentScale(1)
    }

    private func setMPRSurfaceSizes(_ controller: ClinicalViewportGridController, size: CGSize) {
        setSurfaceSize(controller.axialSurface, size: size)
        setSurfaceSize(controller.coronalSurface, size: size)
        setSurfaceSize(controller.sagittalSurface, size: size)
    }

    private func setSnapshotSurfaceSizes(_ controller: ClinicalViewportGridController, size: CGSize) {
        setSurfaceSize(controller.axialSurface, size: size)
        setSurfaceSize(controller.coronalSurface, size: size)
        setSurfaceSize(controller.sagittalSurface, size: size)
        setSurfaceSize(controller.volumeSurface, size: size)
    }

    private func renderGenerationsByViewport(
        for viewports: [ViewportID],
        in controller: ClinicalViewportGridController
    ) -> [ViewportID: UInt64] {
        Dictionary(uniqueKeysWithValues: viewports.map { viewport in
            (viewport, controller.debugRenderGeneration(for: viewport))
        })
    }

}

private extension VolumeDataset {
    func worldPoint(for index: SIMD3<Int32>) -> SIMD3<Float> {
        imageData.indexToWorld.transformPoint(SIMD3<Float>(Float(index.x),
                                                           Float(index.y),
                                                           Float(index.z)))
    }
}

private func assertVector(_ actual: SIMD3<Float>,
                          _ expected: SIMD3<Float>,
                          accuracy: Float,
                          _ message: String = "",
                          file: StaticString = #filePath,
                          line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, message, file: file, line: line)
}
