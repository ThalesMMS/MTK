import Metal
import MTKCore
@testable import MTKUI
import XCTest

@MainActor
final class MedicalViewportContractTests: XCTestCase {
    func testStackViewportAppliesDatasetAndScrollsSlices() async throws {
        try requireMetalDevice()
        let viewport = try StackViewport(axis: .axial)
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))

        await viewport.applyDataset(dataset)
        await viewport.setSliceIndex(4)
        await viewport.scroll(by: -2)

        XCTAssertEqual(viewport.viewportType, .stack(axis: .axial))
        XCTAssertEqual(viewport.renderMode, .stack)
        XCTAssertEqual(viewport.sliceCount, 6)
        XCTAssertEqual(viewport.sliceIndex, 2)
        XCTAssertEqual(viewport.state.viewportID, viewport.id)
        XCTAssertEqual(viewport.state.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(viewport.state.slice?.index, 2)
        XCTAssertEqual(viewport.state.slice?.count, 6)
        XCTAssertEqual(viewport.state.presentation.isMetalBacked, true)
        XCTAssertTrue(viewport.surface is MetalViewportSurface)

        await viewport.scroll(by: -10)
        XCTAssertEqual(viewport.sliceIndex, 0)

        await viewport.scroll(by: -1, loop: true)
        XCTAssertEqual(viewport.sliceIndex, 5)

        viewport.setWindowPresentation(isInverted: false, clut: .invertedGrayscale)
        XCTAssertEqual(viewport.windowPresentation.clut, .invertedGrayscale)
        XCTAssertTrue(viewport.windowPresentation.effectiveInversion)

        viewport.setWindowPresentation(isInverted: true, clut: .invertedGrayscale)
        XCTAssertFalse(viewport.windowPresentation.effectiveInversion)

        let transform = Viewer2DTransform(zoom: 2,
                                          pan: SIMD2<Double>(0.1, -0.1),
                                          rotationRadians: .pi / 2,
                                          isFlippedHorizontally: true,
                                          isFlippedVertically: false)
        viewport.setViewportTransform(transform)
        XCTAssertEqual(viewport.viewportTransform, transform)
    }

    func testStackViewportSnapshotFrameExportsCurrent2DPresentation() async throws {
        try requireMetalDevice()
        let viewport = try StackViewport(axis: .axial)
        viewport.metalSurface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        viewport.metalSurface.setContentScale(1)
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 8, height: 8, depth: 4))

        await viewport.applyDataset(dataset)
        await viewport.setSliceIndex(2)
        await viewport.setWindowLevel(window: 600, level: -700)
        viewport.setWindowPresentation(isInverted: true, clut: .grayscale)
        viewport.setViewportTransform(
            Viewer2DTransform(zoom: 1.25,
                              pan: SIMD2<Double>(0.05, -0.05),
                              rotationRadians: .pi / 2,
                              isFlippedHorizontally: true,
                              isFlippedVertically: false)
        )

        let frame = try await viewport.renderSnapshotFrame()
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertEqual(frame.metadata.viewportID, viewport.id)
        XCTAssertEqual(frame.metadata.quality, .production)
        XCTAssertEqual(frame.metadata.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(frame.texture.width, 64)
        XCTAssertEqual(frame.texture.height, 64)
        XCTAssertTrue(imageContainsVisiblePixels(image))
    }

    func testStackViewportSnapshotFrameReportsMissingDataset() async throws {
        try requireMetalDevice()
        let viewport = try StackViewport(axis: .axial)

        do {
            _ = try await viewport.renderSnapshotFrame()
            XCTFail("Expected missing dataset error")
        } catch VolumeViewportController.Error.datasetNotLoaded {
            // Expected explicit failure mode.
        } catch {
            XCTFail("Expected datasetNotLoaded, got \(error)")
        }
    }

    func testStackViewportAppliesLabelmapVolumeLayers() async throws {
        try requireMetalDevice()
        let viewport = try StackViewport(axis: .axial)
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 4, depth: 4))
        let layer = try makeLabelmapLayer(id: "stack-segmentation", dimensions: dataset.dimensions)

        await viewport.applyDataset(dataset)
        await viewport.setVolumeLayers([layer])
        await viewport.setVolumeLayerOpacity(id: layer.id, opacity: 0.25)
        await viewport.setVolumeLayerBlendMode(id: layer.id, blendMode: .additive)
        await viewport.setVolumeLayerVisibility(id: layer.id, isVisible: false)

        XCTAssertEqual(viewport.volumeLayers.count, 1)
        XCTAssertEqual(viewport.volumeLayers.first?.labelmap?.dataset.dimensions, dataset.dimensions)
        XCTAssertEqual(viewport.volumeLayers.first?.opacity, 0.25)
        XCTAssertEqual(viewport.volumeLayers.first?.blendMode, .additive)
        XCTAssertEqual(viewport.volumeLayers.first?.isVisible, false)
    }

    func testVolumeViewportSwitchesBetweenMPRAndProjectionContracts() async throws {
        try requireMetalDevice()
        let viewport = try VolumeViewport(axis: .coronal, normalizedSlicePosition: 0.25)
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))

        await viewport.applyDataset(dataset)

        XCTAssertEqual(viewport.viewportType, .volume(axis: .coronal))
        XCTAssertEqual(viewport.renderMode, .mpr(blend: .single))
        XCTAssertEqual(viewport.state.slice?.axis, .coronal)
        XCTAssertEqual(viewport.state.slice?.index, 1)
        XCTAssertEqual(viewport.state.dataset?.spacing, dataset.spacing)
        XCTAssertEqual(viewport.state.presentation.isMetalBacked, true)

        await viewport.setProjectionMode(.mip)

        XCTAssertEqual(viewport.viewportType, .projection(mode: .mip))
        XCTAssertEqual(viewport.renderMode, .projection(mode: .mip))
        XCTAssertNil(viewport.state.slice)

        await viewport.setOrientation(.sagittal)

        XCTAssertEqual(viewport.viewportType, .volume(axis: .sagittal))
        XCTAssertEqual(viewport.state.slice?.axis, .sagittal)
    }

    func testVolumeViewport3DAppliesDatasetMethodWindowAndCameraState() async throws {
        try requireMetalDevice()
        let viewport = try VolumeViewport3D()
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))

        await viewport.applyDataset(dataset)
        await viewport.setRenderMethod(.mip)
        await viewport.setWindowLevel(window: 200, level: -800)
        await viewport.rotateCamera(screenDelta: SIMD2<Float>(3, 2))

        XCTAssertEqual(viewport.viewportType, .volume3D)
        XCTAssertEqual(viewport.renderMode, .volume3D(method: .mip))
        XCTAssertEqual(viewport.state.dataset?.intensityRange, dataset.intensityRange)
        XCTAssertEqual(viewport.state.windowLevel.window, 200, accuracy: 0.001)
        XCTAssertEqual(viewport.state.windowLevel.level, -800, accuracy: 0.001)
        XCTAssertNotEqual(viewport.state.camera.position, VolumetricCameraState().position)
        XCTAssertTrue(viewport.surface is MetalViewportSurface)
    }

    func testVolumeViewport3DForwardsAdaptiveSamplingControls() async throws {
        try requireMetalDevice()
        let viewport = try VolumeViewport3D()
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))

        await viewport.applyDataset(dataset)
        await viewport.beginAdaptiveSamplingInteraction()
        await viewport.endAdaptiveSamplingInteraction()
        await viewport.forceFinalRenderQuality()

        XCTAssertEqual(viewport.viewportType, .volume3D)
        XCTAssertEqual(viewport.state.dataset?.dimensions, dataset.dimensions)
        XCTAssertTrue(viewport.state.presentation.isMetalBacked)
    }

    func testVolumeViewport3DAppliesProgressiveDatasetUpdates() async throws {
        try requireMetalDevice()
        let viewport = try VolumeViewport3D()
        let preview = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let final = makeDataset(dimensions: VolumeDimensions(width: 5, height: 5, depth: 6))
        let updates = AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error> { continuation in
            continuation.yield(
                ProgressiveVolumeDatasetUpdate(
                    layer: ProgressiveVolumeLayer(index: 0,
                                                  totalLayerCount: 2,
                                                  quality: .preview,
                                                  fractionComplete: 0.5,
                                                  isFinal: false),
                    dataset: preview
                )
            )
            continuation.yield(
                ProgressiveVolumeDatasetUpdate(
                    layer: ProgressiveVolumeLayer(index: 1,
                                                  totalLayerCount: 2,
                                                  quality: .final,
                                                  fractionComplete: 1.0,
                                                  isFinal: true),
                    dataset: final
                )
            )
            continuation.finish()
        }

        try await viewport.applyProgressiveDatasetUpdates(updates)

        XCTAssertEqual(viewport.state.dataset?.dimensions, final.dimensions)
        XCTAssertEqual(viewport.progressiveVolumeState.phase, .complete)
        XCTAssertEqual(viewport.state.progressiveVolumeState.currentLayer?.index, 1)
        XCTAssertEqual(viewport.renderMode, .volume3D(method: .dvr))
    }

    func testVolumeViewport3DAppliesScalarVolumeLayers() async throws {
        try requireMetalDevice()
        let viewport = try VolumeViewport3D()
        let baseDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let petDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let layer = makeScalarVolumeLayer(id: "pet-layer", dataset: petDataset)

        await viewport.applyDataset(baseDataset)
        await viewport.setVolumeLayers([layer])
        await viewport.setVolumeLayerOpacity(id: layer.id, opacity: 0.25)
        await viewport.setVolumeLayerBlendMode(id: layer.id, blendMode: .additive)
        await viewport.setVolumeLayerVisibility(id: layer.id, isVisible: false)

        XCTAssertEqual(viewport.volumeLayers.count, 1)
        XCTAssertEqual(viewport.volumeLayers.first?.scalarVolume?.dataset, petDataset)
        XCTAssertEqual(viewport.volumeLayers.first?.opacity, 0.25)
        XCTAssertEqual(viewport.volumeLayers.first?.blendMode, .additive)
        XCTAssertEqual(viewport.volumeLayers.first?.isVisible, false)
    }

    func testClinicalViewportGridAcceptsPublicSessionContract() async throws {
        try requireMetalDevice()
        let session = try await ClinicalViewportSession.make()

        _ = ClinicalViewportGrid(session: session)

        XCTAssertEqual(session.volumeViewportMode, .dvr)
        XCTAssertEqual(session.debugSnapshot(for: session.volumeViewportID).viewportType, "volume3D")
    }

    func testClinicalViewportSessionExposesViewportIdentityAndPresentationByAxis() async throws {
        try requireMetalDevice()
        let session = try await ClinicalViewportSession.make()
        let surfaceSize = CGSize(width: 120, height: 80)
        session.surface(for: .axial).metalView.frame = CGRect(origin: .zero, size: surfaceSize)
        session.surface(for: .axial).setContentScale(1)

        XCTAssertEqual(session.viewportID(for: .axial), session.axialViewportID)
        XCTAssertEqual(session.viewportID(for: .coronal), session.coronalViewportID)
        XCTAssertEqual(session.viewportID(for: .sagittal), session.sagittalViewportID)
        XCTAssertTrue(session.surface(for: .axial) === session.axialSurface)
        XCTAssertTrue(session.surface(for: .coronal) === session.coronalSurface)
        XCTAssertTrue(session.surface(for: .sagittal) === session.sagittalSurface)
        XCTAssertEqual(session.drawableSize(for: .axial), surfaceSize)
        XCTAssertEqual(session.displayTransform(for: .axial), session.displayTransform(for: session.axialViewportID))
        XCTAssertEqual(session.renderQualityState, .settled)

        await session.shutdown()
    }

    func testClinicalViewportSessionPublishesViewportStatesWithoutControllerAccess() async throws {
        try requireMetalDevice()
        let dataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let session = try await ClinicalViewportSession.make(dataset: dataset)

        await session.setMPRSlicePosition(axis: .axial, normalizedPosition: 0.75)
        await session.setMPRWindowLevel(window: 650, level: -50)
        await session.setMPRSlabBlendMode(.mip)
        try await session.setVolumeViewportMode(.mip)

        let axialState = session.state(for: .axial)
        let volumeState = session.volumeViewportState

        XCTAssertEqual(session.viewportStates.count, 4)
        XCTAssertEqual(axialState.viewportID, session.axialViewportID)
        XCTAssertEqual(axialState.viewportType, .volume(axis: .axial))
        XCTAssertEqual(axialState.renderMode, .mpr(blend: .mip))
        XCTAssertEqual(axialState.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(axialState.windowLevel.window, 650, accuracy: 0.001)
        XCTAssertEqual(axialState.windowLevel.level, -50, accuracy: 0.001)
        XCTAssertEqual(axialState.slice?.axis, .axial)
        XCTAssertEqual(axialState.slice?.index, 4)
        XCTAssertEqual(axialState.slice?.count, 6)
        XCTAssertEqual(try XCTUnwrap(axialState.slice?.normalizedPosition), 0.75, accuracy: 0.001)
        XCTAssertTrue(axialState.presentation.isMetalBacked)
        XCTAssertEqual(try XCTUnwrap(session.state(for: session.axialViewportID)), axialState)

        XCTAssertEqual(volumeState.viewportID, session.volumeViewportID)
        XCTAssertEqual(volumeState.viewportType, .projection(mode: .mip))
        XCTAssertEqual(volumeState.renderMode, .projection(mode: .mip))
        XCTAssertEqual(volumeState.dataset?.dimensions, dataset.dimensions)
        XCTAssertEqual(volumeState.clipping, session.volumeClipping)
        XCTAssertTrue(volumeState.presentation.isMetalBacked)
        XCTAssertEqual(try XCTUnwrap(session.state(for: session.volumeViewportID)), volumeState)

        await session.shutdown()
    }

    func testClinicalViewportSessionAppliesPublicVolumeClipping() async throws {
        try requireMetalDevice()
        let session = try await ClinicalViewportSession.make()
        let crop = try VolumeCropBox(textureMin: SIMD3<Float>(0.2, 0.2, 0.2),
                                     textureMax: SIMD3<Float>(0.8, 0.8, 0.8))
        let clipping = try VolumeClippingState(cropBox: crop)

        try await session.setVolumeClipping(clipping)

        XCTAssertEqual(session.volumeClipping, clipping)
        try await session.clearVolumeClipping()
        XCTAssertEqual(session.volumeClipping, .disabled)
    }

    func testClinicalViewportSessionAppliesPublicSurfaceMeshLayers() async throws {
        try requireMetalDevice()
        let session = try await ClinicalViewportSession.make()
        let layer = makeSurfaceMeshLayer()

        await session.setSurfaceMeshLayers([layer])

        XCTAssertEqual(session.surfaceMeshLayers, [layer])
        await session.setSurfaceMeshLayerVisibility(id: layer.id, isVisible: false)
        XCTAssertEqual(session.surfaceMeshLayers.first?.isVisible, false)
        await session.setSurfaceMeshLayerOpacity(id: layer.id, opacity: 0.25)
        XCTAssertEqual(session.surfaceMeshLayers.first?.opacity, 0.25)
    }

    func testClinicalViewportSessionTogglesSegmentationBetweenLabelmapAndSurfaceLayer() async throws {
        try requireMetalDevice()
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let session = try await ClinicalViewportSession.make(dataset: makeDataset(dimensions: dimensions))
        let labelmapLayer = try makeLabelmapLayer(id: "segmentation-labelmap", dimensions: dimensions)
        let surfaceLayer = makeSurfaceMeshLayer()

        await session.setVolumeLayers([labelmapLayer])
        await session.setSurfaceMeshLayers([])

        XCTAssertEqual(session.volumeLayers.map(\.id), ["segmentation-labelmap"])
        XCTAssertTrue(session.surfaceMeshLayers.isEmpty)

        await session.setVolumeLayers([])
        await session.setSurfaceMeshLayers([surfaceLayer])
        await session.setSurfaceMeshLayerVisibility(id: surfaceLayer.id, isVisible: false)

        XCTAssertTrue(session.volumeLayers.isEmpty)
        XCTAssertEqual(session.surfaceMeshLayers.map(\.id), [surfaceLayer.id])
        XCTAssertEqual(session.surfaceMeshLayers.first?.isVisible, false)

        await session.shutdown()
    }

    func testClinicalViewportSessionAppliesScalarVolumeLayerControls() async throws {
        try requireMetalDevice()
        let baseDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let petDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let session = try await ClinicalViewportSession.make(dataset: baseDataset)
        let layer = makeScalarVolumeLayer(id: "session-pet", dataset: petDataset)

        await session.setVolumeLayers([layer])
        await session.setVolumeLayerOpacity(id: layer.id, opacity: 0.35)
        await session.setVolumeLayerBlendMode(id: layer.id, blendMode: .additive)
        await session.setVolumeLayerVisibility(id: layer.id, isVisible: false)

        XCTAssertEqual(session.volumeLayers.count, 1)
        XCTAssertEqual(session.volumeLayers.first?.scalarVolume?.dataset, petDataset)
        XCTAssertEqual(session.volumeLayers.first?.opacity, 0.35)
        XCTAssertEqual(session.volumeLayers.first?.blendMode, .additive)
        XCTAssertEqual(session.volumeLayers.first?.isVisible, false)
        XCTAssertNil(session.lastRenderError)

        await session.shutdown()
    }

    func testClinicalViewportSessionExposesQuantitativeScalarLegend() async throws {
        try requireMetalDevice()
        let baseDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let scalarDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let session = try await ClinicalViewportSession.make(dataset: baseDataset)
        let mapping = QuantitativeScalarMapping(
            units: QuantitativeCodedConcept(codeValue: "SUVbw",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "SUV body weight"),
            quantityDefinitions: [
                QuantitativeQuantityDefinition(
                    conceptCode: QuantitativeCodedConcept(codeValue: "126400",
                                                          codingSchemeDesignator: "DCM",
                                                          codeMeaning: "Standardized Uptake Value")
                )
            ],
            physicalRange: 0...12,
            storedValueRange: scalarDataset.intensityRange,
            legendTitle: "SUV"
        )
        let scalarVolume = ScalarVolumeLayer(
            dataset: scalarDataset,
            transferFunction: .defaultGrayscale(for: scalarDataset),
            quantitativeMapping: mapping
        )
        let layer = VolumeLayer(id: "suv-layer", scalarVolume: scalarVolume)

        await session.setVolumeLayers([layer])

        XCTAssertEqual(session.quantitativeScalarLegends.count, 1)
        XCTAssertEqual(session.quantitativeScalarLegends[0].layerID, "suv-layer")
        XCTAssertEqual(session.quantitativeScalarLegends[0].title, "SUV")
        XCTAssertEqual(session.quantitativeScalarLegends[0].unitsLabel, "SUV body weight")
        XCTAssertEqual(session.quantitativeScalarLegends[0].physicalRange.upperBound, 12)

        await session.shutdown()
    }

    func testClinicalViewportSessionAppliesRTDoseOverlaysAsVolumeLayers() async throws {
        try requireMetalDevice()
        let baseDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let doseDataset = makeDataset(dimensions: VolumeDimensions(width: 4, height: 5, depth: 6))
        let session = try await ClinicalViewportSession.make(dataset: baseDataset)
        let overlay = RTDoseVolumeOverlay(id: "plan-dose",
                                          dataset: doseDataset,
                                          doseUnits: "GY",
                                          doseGridScaling: 0.01,
                                          opacity: 0.4)

        await session.setRTDoseOverlays([overlay])
        await session.setRTDoseOverlayOpacity(id: "plan-dose", opacity: 0.25)

        XCTAssertEqual(session.rtDoseOverlays.count, 1)
        XCTAssertEqual(session.volumeLayers.map(\.id), ["plan-dose"])
        XCTAssertEqual(session.volumeLayers.first?.opacity, 0.25)

        await session.shutdown()
    }

    private func requireMetalDevice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }
    }

    private func makeDataset(dimensions: VolumeDimensions) -> VolumeDataset {
        var voxels = [Int16]()
        voxels.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    voxels.append(Int16(-1_000 + x + y * 10 + z * 100))
                }
            }
        }
        return VolumeDataset(
            data: voxels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 2),
            pixelFormat: .int16Signed,
            intensityRange: -1_000...(-456),
            recommendedWindow: -900...(-500)
        )
    }

    private func makeSurfaceMeshLayer() -> SurfaceMeshLayer {
        let mesh = SurfaceMesh(
            id: "medical-viewport-surface-mesh",
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
        return SurfaceMeshLayer(id: "medical-viewport-surface-layer",
                                mesh: mesh,
                                material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1)),
                                opacity: 0.5)
    }

    private func makeScalarVolumeLayer(id: String, dataset: VolumeDataset) -> VolumeLayer {
        VolumeLayer(id: id,
                    dataset: dataset,
                    transferFunction: .defaultGrayscale(for: dataset),
                    opacity: 0.6,
                    blendMode: .sourceOver)
    }

    private func makeLabelmapLayer(id: String, dimensions: VolumeDimensions) throws -> VolumeLayer {
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
}
