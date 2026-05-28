import CoreGraphics
import Foundation
import Metal
import simd
import XCTest
@_spi(Testing) import MTKCore
@testable import MTKUI

@MainActor
final class Volume3DWindowLevelTests: XCTestCase {
    func testWindowPresetMappingsUseClinicalTransferFunctionsAndWindows() {
        XCTAssertEqual(Volume3DWindowPreset.default.clinicalTransferFunctionPreset, .ctSoftTissue)
        XCTAssertNil(Volume3DWindowPreset.default.windowLevelPreset)
        XCTAssertEqual(Volume3DWindowPreset.abdomen.clinicalTransferFunctionPreset, .ctAbdomen)
        XCTAssertEqual(Volume3DWindowPreset.abdomen.windowLevelPreset?.id, "weasis.ct-abdomen")
        XCTAssertEqual(Volume3DWindowPreset.bone.clinicalTransferFunctionPreset, .ctBone)
        XCTAssertEqual(Volume3DWindowPreset.bone.windowLevelPreset, WindowLevelPresetLibrary.bone)
        XCTAssertEqual(Volume3DWindowPreset.brain.clinicalTransferFunctionPreset, .ctBrain)
        XCTAssertEqual(Volume3DWindowPreset.brain.windowLevelPreset, WindowLevelPresetLibrary.brain)
        XCTAssertEqual(Volume3DWindowPreset.lungs.clinicalTransferFunctionPreset, .ctLung)
        XCTAssertEqual(Volume3DWindowPreset.lungs.windowLevelPreset, WindowLevelPresetLibrary.lung)
        XCTAssertEqual(Volume3DWindowPreset.endoscopy.clinicalTransferFunctionPreset, .ctVRBone)
        XCTAssertEqual(Volume3DWindowPreset.endoscopy.windowLevelPreset, WindowLevelPresetLibrary.bone)
        XCTAssertTrue(Volume3DWindowPreset.other.usesPlaceholderMapping)
    }

    func testWindowLevelMenuIncludesScrollableCLUTSectionAndSelectionState() throws {
        let menu = Volume3DWindowLevelToolMenu.menu(selectedWindowPreset: .bone,
                                                    selectedCLUTPreset: Volume3DCLUTPreset.allPresets[12])
        let clutSection = try XCTUnwrap(menu.sections.first)

        XCTAssertEqual(menu.items.map(\.title), [
            "Default",
            "Abdomen",
            "Bone",
            "Brain",
            "Lungs",
            "Endoscopy",
            "Other",
            "Select WW/WL tool"
        ])
        XCTAssertEqual(menu.items.first { $0.title == "Bone" }?.systemImage, "checkmark")
        XCTAssertEqual(clutSection.title, "CLUTs")
        XCTAssertEqual(clutSection.maximumVisibleItems, 12)
        XCTAssertEqual(clutSection.items.map(\.title), Volume3DCLUTPreset.allPresets.map(\.displayName))
        XCTAssertEqual(clutSection.items[12].systemImage, "checkmark")
    }

    func testGeneratedCLUTPreservesOpacityAndReplacesColorPoints() throws {
        let base = try ClinicalTransferFunctionPreset.ctBone.loadTransferFunction()
        let clut = try XCTUnwrap(Volume3DCLUTPreset.allPresets.first { $0.id == "rainbow-1" })

        let mapped = clut.transferFunction(basedOn: base)

        XCTAssertEqual(mapped.alphaPoints, base.alphaPoints)
        XCTAssertEqual(mapped.minimumValue, base.minimumValue)
        XCTAssertEqual(mapped.maximumValue, base.maximumValue)
        XCTAssertNotEqual(mapped.colourPoints, base.colourPoints)
        XCTAssertEqual(mapped.colourPoints.first?.dataValue, base.minimumValue)
        XCTAssertEqual(mapped.colourPoints.last?.dataValue, base.maximumValue)
    }

    func testWindowLevelDragPreservesCameraClippingAndLayers() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable for VolumeViewport3D WW/WL test.")
        }
        let dataset = VolumeRenderRegressionFixture.dataset()
        let viewport = try VolumeViewport3D(device: device,
                                            surface: try makeSurface(device: device))
        await viewport.applyDataset(dataset)
        await viewport.setWindowLevel(window: 400, level: 40)
        let clipping = try VolumeClippingState(
            cropBox: VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.1, 0.1),
                                   textureMax: SIMD3<Float>(0.9, 0.9, 0.9))
        )
        try await viewport.setVolumeClipping(clipping)
        await viewport.setVolumeLayers([try makeLabelmapLayer(for: dataset)])

        let cameraBefore = viewport.state.camera
        let layerIDsBefore = viewport.volumeLayers.map(\.id)

        await viewport.adjustTransferFunctionShift(screenDelta: SIMD2<Float>(10, -5))

        XCTAssertEqual(viewport.state.windowLevel.window, 420, accuracy: 0.001)
        XCTAssertEqual(viewport.state.windowLevel.level, 50, accuracy: 0.001)
        XCTAssertEqual(viewport.state.camera, cameraBefore)
        XCTAssertEqual(viewport.state.clipping, clipping)
        XCTAssertEqual(viewport.volumeLayers.map(\.id), layerIDsBefore)
    }

    func testApplyingCLUTTransferFunctionPreservesCameraClippingAndLayers() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable for VolumeViewport3D CLUT test.")
        }
        let dataset = VolumeRenderRegressionFixture.dataset()
        let viewport = try VolumeViewport3D(device: device,
                                            surface: try makeSurface(device: device))
        await viewport.applyDataset(dataset)
        let clipping = try VolumeClippingState(
            cropBox: VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.1, 0.1),
                                   textureMax: SIMD3<Float>(0.9, 0.9, 0.9))
        )
        try await viewport.setVolumeClipping(clipping)
        await viewport.setVolumeLayers([try makeLabelmapLayer(for: dataset)])

        let base = try ClinicalTransferFunctionPreset.ctBone.loadTransferFunction()
        let clut = try XCTUnwrap(Volume3DCLUTPreset.allPresets.first { $0.id == "redhot" })
        let cameraBefore = viewport.state.camera
        let layerIDsBefore = viewport.volumeLayers.map(\.id)

        try await viewport.setTransferFunction(clut.transferFunction(basedOn: base))

        XCTAssertEqual(viewport.state.camera, cameraBefore)
        XCTAssertEqual(viewport.state.clipping, clipping)
        XCTAssertEqual(viewport.volumeLayers.map(\.id), layerIDsBefore)
    }

    private func makeSurface(device: any MTLDevice) throws -> MetalViewportSurface {
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        surface.setContentScale(1)
        return surface
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
        return VolumeLayer(id: "window-level-layer",
                           labelmap: labelmap,
                           opacity: 0.5)
    }
}
