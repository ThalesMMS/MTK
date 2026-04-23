import CoreGraphics
import Metal
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
    }

    func testWindowLevelSyncsOnlyMPRViewports() async throws {
        let controller = try await makeController()
        let dataset = makeDataset()
        try await controller.applyDataset(dataset)

        await controller.setMPRWindowLevel(window: 120, level: 40)

        let expected: ClosedRange<Int32> = (-20)...100
        let initialVolumeWindow = dataset.recommendedWindow ?? dataset.intensityRange
        let axialWindow = await controller.engine.debugWindow(for: controller.axialViewportID)
        let coronalWindow = await controller.engine.debugWindow(for: controller.coronalViewportID)
        let sagittalWindow = await controller.engine.debugWindow(for: controller.sagittalViewportID)
        let volumeWindow = await controller.engine.debugWindow(for: controller.volumeViewportID)
        XCTAssertEqual(axialWindow, expected)
        XCTAssertEqual(coronalWindow, expected)
        XCTAssertEqual(sagittalWindow, expected)
        XCTAssertEqual(volumeWindow, initialVolumeWindow)
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

    private func setSnapshotSurfaceSizes(_ controller: ClinicalViewportGridController, size: CGSize) {
        setSurfaceSize(controller.axialSurface, size: size)
        setSurfaceSize(controller.coronalSurface, size: size)
        setSurfaceSize(controller.sagittalSurface, size: size)
        setSurfaceSize(controller.volumeSurface, size: size)
    }

}
