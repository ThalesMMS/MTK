import DicomCore
import Foundation
import MTKCore
@testable import MTKDicomBridge
import XCTest
import simd

final class VolumeMaskDicomSegmentationExporterTests: XCTestCase {
    func testEditedMaskExportsValidSegWithSourceReferencesAndSegmentMetadata() throws {
        let baseDataset = makeDataset()
        let editedDataset = makeEditedDataset(from: baseDataset)
        let firstReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9601",
            referencedFrameNumbers: [1]
        )
        let secondReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9602",
            referencedFrameNumbers: [2]
        )
        let segment = DicomSegment(
            number: 4,
            label: "Manual ROI",
            description: "Edited mask",
            algorithmType: "MANUAL",
            trackingID: "manual-roi",
            trackingUID: "2.25.9701",
            recommendedDisplayCIELabValue: [45_000, 35_000, 32_000]
        )
        let options = VolumeMaskDicomSegmentationExportOptions(
            sopInstanceUID: "2.25.9702",
            studyInstanceUID: "2.25.9703",
            seriesInstanceUID: "2.25.9704",
            segment: segment,
            sourceImageReferencesBySlice: [
                0: [firstReference],
                1: [secondReference]
            ]
        )

        let data = try VolumeMaskDicomSegmentationExporter.makePart10Data(
            baseDataset: baseDataset,
            editedDataset: editedDataset,
            options: options
        )
        let parsed = try XCTUnwrap(parseSegmentationPart10(data))

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.9702")
        XCTAssertEqual(parsed.rows, 3)
        XCTAssertEqual(parsed.columns, 3)
        XCTAssertEqual(parsed.segments, [segment])
        XCTAssertEqual(parsed.frames.count, 2)
        XCTAssertEqual(parsed.frames[0].sourceImageReferences, [firstReference])
        XCTAssertEqual(parsed.frames[1].sourceImageReferences, [secondReference])
        XCTAssertEqual(parsed.frames[0].pixelData, .binary([0, 0, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(parsed.frames[1].pixelData, .binary([1, 0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(parsed.frames[0].geometry?.imagePositionPatient, SIMD3<Double>(10, 20, 30))
        XCTAssertEqual(parsed.frames[1].geometry?.imagePositionPatient, SIMD3<Double>(10, 20, 31.5))
        XCTAssertEqual(parsed.frames[0].geometry?.pixelMeasures?.pixelSpacing, SIMD2<Double>(0.7, 0.8))
        XCTAssertEqual(parsed.frames[0].geometry?.pixelMeasures?.sliceThickness, 1.5)
        XCTAssertEqual(parsed.labelmapsBySegment[4]?.voxels,
                       [
                           0, 0, 0, 0, 4, 0, 0, 0, 0,
                           4, 0, 0, 0, 0, 0, 0, 0, 0
                       ])
    }

    func testExportRejectsUnchangedMask() throws {
        let baseDataset = makeDataset()

        XCTAssertThrowsError(
            try VolumeMaskDicomSegmentationExporter.makeSegmentation(
                baseDataset: baseDataset,
                editedDataset: baseDataset
            )
        ) { error in
            XCTAssertEqual(error as? VolumeMaskDicomSegmentationExportError, .noEditedVoxels)
        }
    }

    private func makeDataset() -> VolumeDataset {
        let values = [Int16](repeating: 100, count: 18)
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 3, height: 3, depth: 2),
            spacing: VolumeSpacing(x: 0.7, y: 0.8, z: 1.5),
            pixelFormat: .int16Signed,
            intensityRange: 0...100,
            orientation: VolumeOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 1, 0),
                origin: SIMD3<Float>(10, 20, 30)
            ),
            clinicalMetadata: ClinicalImageMetadata(
                modality: "CT",
                studyInstanceUID: "2.25.9703"
            )
        )
    }

    private func makeEditedDataset(from dataset: VolumeDataset) -> VolumeDataset {
        var values = [Int16](repeating: 100, count: dataset.dimensions.voxelCount)
        values[4] = 0
        values[9] = 0
        var edited = dataset
        edited.data = values.withUnsafeBytes { Data($0) }
        return edited
    }

    private func parseSegmentationPart10(_ data: Data) throws -> DicomSegmentation? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VolumeMaskDicomSegmentationExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("segmentation.dcm")
        try data.write(to: url)
        return try DCMDecoder(contentsOf: url).segmentation
    }
}
