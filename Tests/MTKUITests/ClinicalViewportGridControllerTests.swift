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

    func testWindowLevelSyncsAllViewports() async throws {
        let controller = try await makeController()
        let dataset = makeDataset()
        try await controller.applyDataset(dataset)

        await controller.setMPRWindowLevel(window: 120, level: 40)

        let expected: ClosedRange<Int32> = (-20)...100
        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        let volumeWindow = await controller.engine.debugWindow(for: controller.volumeViewportID)
        XCTAssertEqual(axialWindow, expected)
        XCTAssertEqual(coronalWindow, expected)
        XCTAssertEqual(sagittalWindow, expected)
        XCTAssertEqual(volumeWindow, expected)

        // Ensure shared state drives the value: setting same WL again should not schedule any new renders.
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)

        await controller.setMPRWindowLevel(window: 120, level: 40)

        let mprAfter = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeAfter = controller.debugRenderGeneration(for: controller.volumeViewportID)
        XCTAssertEqual(mprAfter, mprBefore)
        XCTAssertEqual(volumeAfter, volumeBefore)
    }

#if DEBUG
    func testWindowLevelCommitDoesNotMutateMPRWindowsWhenVolumeWindowFails() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let committedRange = try XCTUnwrap(controller.committedMPRWindowRange)
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)
        let volumeWindowBefore = await controller.engine.debugWindow(for: controller.volumeViewportID)

        controller.debugWindowConfigurationFailureViewports = [controller.volumeViewportID]
        await controller.setMPRWindowLevel(window: 120, level: 40)

        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        let volumeWindowAfter = await controller.engine.debugWindow(for: controller.volumeViewportID)
        XCTAssertEqual(axialWindow, committedRange)
        XCTAssertEqual(coronalWindow, committedRange)
        XCTAssertEqual(sagittalWindow, committedRange)
        XCTAssertEqual(volumeWindowAfter, volumeWindowBefore)
        XCTAssertEqual(controller.windowLevel.range, committedRange)
        XCTAssertEqual(controller.committedMPRWindowRange, committedRange)
        XCTAssertEqual(controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }, mprBefore)
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

    func testSurfaceMeshLayerControlsSyncToVolumeViewportOnly() async throws {
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
        XCTAssertGreaterThan(controller.debugRenderGeneration(for: controller.volumeViewportID), volumeBefore)

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

        let targetUV = SIMD2<Float>(1.0 / 4.0, 4.0 / 6.0)
        let screenPoint = controller.displayTransform(for: .axial).screenCoordinates(forTexture: targetUV)
        await controller.setCrosshair(in: .axial,
                                      normalizedPoint: CGPoint(x: CGFloat(screenPoint.x),
                                                               y: CGFloat(screenPoint.y)))

        let sagittalSliceValue = await controller.engine.debugSlicePosition(for: controller.sagittalViewportID)
        let coronalSliceValue = await controller.engine.debugSlicePosition(for: controller.coronalViewportID)
        let sagittalSlice = try XCTUnwrap(sagittalSliceValue)
        let coronalSlice = try XCTUnwrap(coronalSliceValue)
        XCTAssertEqual(sagittalSlice, 1.0 / 4.0, accuracy: 0.0001)
        XCTAssertEqual(coronalSlice, 4.0 / 6.0, accuracy: 0.0001)
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
        let screenPoint = controller.displayTransform(for: .axial).screenCoordinates(forTexture: targetUV)
        let viewportSize = controller.drawableSize(for: .axial)
        let pick = try session.pick(
            in: controller.axialViewportID,
            screenPoint: CGPoint(x: CGFloat(screenPoint.x) * viewportSize.width,
                                 y: CGFloat(screenPoint.y) * viewportSize.height)
        )

        XCTAssertEqual(pick.hitKind, .mprPlane(.z))
        XCTAssertEqual(pick.voxel.index, SIMD3<Int32>(1, 2, 2))
        XCTAssertEqual(pick.intensity.storedScalar, 221)
        XCTAssertEqual(pick.label?.label, 9)
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

    func testMPRScrollStepMapperMatchesClinicalThresholds() {
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 6, hasPreciseScrollingDeltas: true), 1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -6, hasPreciseScrollingDeltas: true), -1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 5, hasPreciseScrollingDeltas: true), 0)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 0.6, hasPreciseScrollingDeltas: false), 1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -0.6, hasPreciseScrollingDeltas: false), -1)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: 0.5, hasPreciseScrollingDeltas: false), 0)
        XCTAssertEqual(MPRScrollStepMapper.steps(deltaY: -0.5, hasPreciseScrollingDeltas: false), 0)
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

    func testAdaptiveInteractionUpdatesVolumeAndMPRQuality() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())

        await controller.beginAdaptiveSamplingInteraction()

        XCTAssertEqual(controller.renderQualityState, .interacting)
        let previewQuality = await controller.engine.debugRenderQuality(for: controller.volumeViewportID)
        let previewSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        XCTAssertEqual(previewQuality?.quality, .preview)
        XCTAssertEqual(previewQuality?.samplingDistance ?? 0, 1 / 256, accuracy: 0.000_001)
        XCTAssertEqual(previewSlab?.steps, 5)

        await controller.endAdaptiveSamplingInteraction()
        XCTAssertEqual(controller.renderQualityState, .settling)
        try await waitForRenderQuality(.settled, controller: controller)

        let finalQuality = await controller.engine.debugRenderQuality(for: controller.volumeViewportID)
        let finalSlab = await controller.engine.debugSlabConfiguration(for: controller.axialViewportID)
        XCTAssertEqual(finalQuality?.quality, .production)
        XCTAssertEqual(finalQuality?.samplingDistance ?? 0, 1 / 512, accuracy: 0.000_001)
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

    func testTransferFunctionSchedulesVolumeViewportOnly() async throws {
        let controller = try await makeController()
        try await controller.applyDataset(makeDataset())
        let mprBefore = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeBefore = controller.debugRenderGeneration(for: controller.volumeViewportID)

        try await controller.setTransferFunction(TransferFunction())

        let mprAfter = controller.mprViewportIDs.map { controller.debugRenderGeneration(for: $0) }
        let volumeAfter = controller.debugRenderGeneration(for: controller.volumeViewportID)
        XCTAssertEqual(mprAfter, mprBefore)
        XCTAssertGreaterThan(volumeAfter, volumeBefore)
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

        _ = ClinicalViewportGrid(controller: controller)
        _ = ClinicalViewportGrid(dataset: makeDataset())
    }

    private func makeController() async throws -> ClinicalViewportGridController {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return try await ClinicalViewportGridController(device: device,
                                                        initialViewportSize: CGSize(width: 32, height: 32))
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
        await controller.setSlicePosition(axis: axis,
                                          normalizedPosition: normalizedPosition(for: axis,
                                                                                 target: target,
                                                                                 dimensions: dataset.dimensions))
        let screenPoint = try mprScreenPoint(for: target,
                                             axis: axis,
                                             dataset: dataset,
                                             controller: controller,
                                             viewportSize: controller.drawableSize(for: axis))
        return try session.pick(in: controller.viewportID(for: axis),
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
