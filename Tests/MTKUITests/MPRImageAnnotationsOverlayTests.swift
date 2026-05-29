import MTKCore
@testable import MTKUI
import XCTest

final class MPRImageAnnotationsOverlayTests: XCTestCase {
    func testDisplayLinesContainOnlyTechnicalMPRValues() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 2,
            axis: .coronal,
            imageSize: MPRImageAnnotationSize(width: 512, height: 128),
            windowLevel: WindowLevelShift(window: 120, level: 40),
            slabThickness: 15,
            zoom: 1.5,
            angleDegrees: 12
        )

        XCTAssertEqual(state.displayLines, [
            "Panel 2",
            "Image size: 512x128",
            "WW: 120 WL: 40",
            "Orientation: Coronal",
            "Thickness: 15 mm",
            "Zoom: 150%",
            "Angle: 12 deg"
        ])
    }

    func testStateSanitizesInvalidNumbers() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 0,
            axis: .sagittal,
            windowLevel: WindowLevelShift(window: .nan, level: .infinity),
            slabThickness: .nan,
            zoom: .nan,
            angleDegrees: .infinity
        )

        XCTAssertEqual(state.panelNumber, 1)
        XCTAssertEqual(state.displayLines, [
            "Panel 1",
            "WW: 0 WL: 0",
            "Orientation: Sagittal",
            "Thickness: 0 mm",
            "Zoom: 0%",
            "Angle: 0 deg"
        ])
    }

    func testMetadataLinesIncludeSanitizedStudySeriesAndSamples() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 1,
            axis: .axial,
            subjectName: "Sample^Subject",
            studyTitle: "  CT   Chest  ",
            seriesTitle: "Patient ID 123456",
            windowLevel: WindowLevelShift(window: 400, level: 40),
            slabThickness: 3,
            zoom: 1,
            angleDegrees: 0,
            metadataSample: makeMetadataSample()
        )

        XCTAssertTrue(state.topLines.contains("Sample Subject"))
        XCTAssertTrue(state.topLines.contains("Study: CT Chest"))
        XCTAssertFalse(state.topLines.contains("Patient ID 123456"))
        XCTAssertTrue(state.bottomLines.contains("Pixel: 42"))
        XCTAssertTrue(state.bottomLines.contains("SUV: 4.25 SUV body weight"))
        XCTAssertTrue(state.bottomLines.contains("Dose: 2.00 GY"))
    }

    func testMetadataSettingsHideMPRLinesPerViewportState() {
        let state = MPRImageAnnotationsOverlayState(
            panelNumber: 1,
            axis: .axial,
            windowLevel: WindowLevelShift(window: 400, level: 40),
            slabThickness: 3,
            zoom: 1,
            angleDegrees: 0,
            metadataSample: makeMetadataSample(),
            metadataOverlaySettings: ClinicalViewportMetadataOverlaySettings(isVisible: false)
        )

        XCTAssertEqual(state.displayLines, [])
    }

    private func makeMetadataSample() -> ClinicalViewportMetadataSample {
        let voxel = VoxelIndex(index: SIMD3<Int32>(0, 0, 0),
                               continuousIndex: SIMD3<Float>(0, 0, 0))
        let intensity = VolumeIntensitySample(storedScalar: 42,
                                              modalityValue: 42,
                                              hounsfieldUnits: 42)
        let quantitativeValue = QuantitativeScalarValue(
            value: 4.25,
            units: QuantitativeCodedConcept(codeValue: "SUVbw",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "SUV body weight"),
            quantityDefinitions: [],
            physicalRange: 0...15,
            legendTitle: "SUV"
        )
        let scalarSample = VolumeScalarSample(layerID: "pet",
                                              voxel: voxel,
                                              intensity: intensity,
                                              quantitativeValue: quantitativeValue)
        let doseSample = RTDoseSample(layerID: "dose",
                                      doseValue: 2,
                                      doseUnits: "GY",
                                      storedScalar: 200,
                                      voxel: voxel,
                                      baseWorldPoint: SIMD3<Float>(0, 0, 0),
                                      doseWorldPoint: SIMD3<Float>(0, 0, 0))
        return ClinicalViewportMetadataSample(intensity: intensity,
                                              scalarSamples: [scalarSample],
                                              doseSamples: [doseSample])
    }
}
