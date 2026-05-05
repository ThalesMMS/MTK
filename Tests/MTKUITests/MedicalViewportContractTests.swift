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

        await session.controller.shutdown()
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
}
