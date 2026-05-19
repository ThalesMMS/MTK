import MTKCore
import MTKFixtures
import XCTest

final class ClinicalSyntheticFixturesTests: XCTestCase {
    func testLabelmapFixtureBuildsRegisteredBaseLabelmapAndSurfaces() throws {
        let fixture = try ClinicalSyntheticFixtures.makeLabelmapOverlay()

        XCTAssertEqual(fixture.baseDataset.dimensions, VolumeDimensions(width: 96, height: 96, depth: 64))
        XCTAssertEqual(fixture.baseDataset.imageData.clinicalMetadata?.modality, "SYN")
        XCTAssertEqual(fixture.labelmapLayer.id, ClinicalSyntheticFixtureIDs.labelmapLayer)
        XCTAssertEqual(fixture.labelmapLayer.opacity, 0.65)
        XCTAssertTrue(fixture.labelmapLayer.isVisible)

        let labelmap = try XCTUnwrap(fixture.labelmapLayer.labelmap)
        XCTAssertEqual(labelmap.dataset.dimensions, fixture.baseDataset.dimensions)
        XCTAssertEqual(labelmap.dataset.spacing, fixture.baseDataset.spacing)
        XCTAssertEqual(labelmap.dataset.orientation, fixture.baseDataset.orientation)
        XCTAssertEqual(labelmap.segments.map(\.label), [1, 2])

        XCTAssertEqual(fixture.surfaceMeshLayers.count, 2)
        XCTAssertTrue(fixture.surfaceMeshLayers.allSatisfy(\.mesh.isRenderable))
        XCTAssertTrue(fixture.surfaceMeshLayers.allSatisfy { $0.id.hasPrefix(ClinicalSyntheticFixtureIDs.surfaceLayerPrefix) })
    }

    func testFusionFixtureBuildsRegisteredCTAndPETLayer() {
        let fixture = ClinicalSyntheticFixtures.makeFusion()

        XCTAssertEqual(fixture.baseDataset.dimensions, VolumeDimensions(width: 96, height: 96, depth: 64))
        XCTAssertEqual(fixture.baseDataset.imageData.clinicalMetadata?.modality, "CT")
        XCTAssertEqual(fixture.petLayer.id, ClinicalSyntheticFixtureIDs.petLayer)
        XCTAssertEqual(fixture.petLayer.blendMode, .additive)
        XCTAssertEqual(fixture.petLayer.opacity, 0.5)
        XCTAssertTrue(fixture.petLayer.isVisible)

        let pet = fixture.petLayer.scalarVolume
        XCTAssertEqual(pet?.dataset.dimensions, fixture.baseDataset.dimensions)
        XCTAssertEqual(pet?.dataset.spacing, fixture.baseDataset.spacing)
        XCTAssertEqual(pet?.dataset.orientation, fixture.baseDataset.orientation)
        XCTAssertEqual(pet?.dataset.imageData.clinicalMetadata?.modality, "PT")
        XCTAssertFalse(pet?.transferFunction.opacityPoints.isEmpty ?? true)
        XCTAssertFalse(pet?.transferFunction.colourPoints.isEmpty ?? true)
    }

    func testCropClipFixtureUsesLabelmapBaseVolume() throws {
        let dataset = try ClinicalSyntheticFixtures.makeCropClipVolume()

        XCTAssertEqual(dataset.dimensions, VolumeDimensions(width: 96, height: 96, depth: 64))
        XCTAssertEqual(dataset.recommendedWindow, (-500)...650)
    }

    func testFixturePresetLoaderReportsMissingHeadResource() {
        XCTAssertThrowsError(try FixtureVolumePresetLoader.dataset(for: .head)) { error in
            guard case VolumeTextureFactory.PresetLoadingError.resourceNotBundled(let preset) = error else {
                XCTFail("Expected resourceNotBundled, got \(error)")
                return
            }
            XCTAssertEqual(preset, "head")
        }
    }

    func testFixturePresetLoaderReportsNoDataForNonResourcePresets() {
        XCTAssertThrowsError(try FixtureVolumePresetLoader.dataset(for: .dicom)) { error in
            guard case VolumeTextureFactory.PresetLoadingError.noDataAvailable(let preset) = error else {
                XCTFail("Expected noDataAvailable, got \(error)")
                return
            }
            XCTAssertEqual(preset, "dicom")
        }
    }
}
