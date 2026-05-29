import CoreGraphics
import DicomCore
import Foundation
import Metal
import MTKCore
import MTKUI
@testable import MTKDicomBridge
import XCTest
import simd

final class ViewerROIDicomRoundTripTests: XCTestCase {
    func testMeasurementAnnotationsRoundTripThroughTID1500StructuredReport() throws {
        let annotationID = UUID(uuidString: "00000000-0000-0000-0000-000000000261")!
        let source = sourceReference(frame: 3)
        let options = makeOptions(
            sopInstanceUID: "2.25.26101",
            sourceImageReferencesBySlice: [2: [source]]
        )
        let annotation = ViewerROIAnnotation(
            id: annotationID,
            kind: .distance,
            axis: .axial,
            sliceIndex: 2,
            normalizedImagePoints: [
                CGPoint(x: 0.25, y: 0.5),
                CGPoint(x: 0.75, y: 0.5)
            ],
            measurement: .distanceMillimeters(25)
        )

        let data = try ViewerROIDicomRoundTrip.makeStructuredReportPart10Data(
            from: [annotation],
            options: options
        )
        let report = try XCTUnwrap(open(data: data, name: "roi_sr").structuredReport)
        let measurement = try XCTUnwrap(report.measurements.first)
        let reopened = ViewerROIDicomRoundTrip.makeAnnotations(from: report,
                                                               axis: .axial,
                                                               options: options)

        XCTAssertEqual(report.sopClassUID, DicomSRDocument.comprehensiveSRStorageSOPClassUID)
        XCTAssertEqual(report.templateIdentifier, "1500")
        XCTAssertEqual(report.contentLabel, "ROI")
        XCTAssertEqual(measurement.name?.codeValue, "ROI_DISTANCE")
        XCTAssertEqual(measurement.value, 25)
        XCTAssertEqual(measurement.units?.codeValue, "mm")
        XCTAssertEqual(measurement.trackingID, annotationID.uuidString)
        XCTAssertEqual(measurement.roi?.graphicType, "POLYLINE")
        XCTAssertEqual(measurement.roi?.graphicData, [3, 5, 7, 5])
        XCTAssertEqual(measurement.sourceImageReferences, [source])
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.id, annotationID)
        XCTAssertEqual(reopened.first?.kind, .distance)
        XCTAssertEqual(reopened.first?.sliceIndex, 2)
        XCTAssertEqual(reopened.first?.measurement, .distanceMillimeters(25))
        XCTAssertEqual(reopened.first?.normalizedImagePoints, annotation.normalizedImagePoints)
    }

    @MainActor
    func testPresentationStateReopensAndReappliesROIAnnotationsInMPRViewer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let source = sourceReference(frame: 2)
        let options = makeOptions(
            sopInstanceUID: "2.25.26111",
            imageWidth: 5,
            imageHeight: 5,
            sourceImageReferencesBySlice: [1: [source]]
        )
        let annotation = ViewerROIAnnotation(
            kind: .closedPath,
            axis: .axial,
            sliceIndex: 1,
            normalizedImagePoints: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1),
                CGPoint(x: 0, y: 1)
            ],
            measurement: .areaSquareMillimeters(16)
        )

        let data = try ViewerROIDicomRoundTrip.makePresentationStatePart10Data(
            from: [annotation],
            options: options
        )
        let presentation = try XCTUnwrap(open(data: data, name: "roi_pr").grayscalePresentationState)
        let state = DicomPresentationStateMPRBridge.makePresentationState(
            from: presentation,
            options: DicomPresentationStateMPRBridgeOptions(axis: .axial,
                                                            imageWidth: 5,
                                                            imageHeight: 5)
        )
        let controller = try await ClinicalViewportGridController(
            device: device,
            initialViewportSize: CGSize(width: 32, height: 32)
        )

        await controller.applyMPRPresentationState(state, to: .axial)
        let reapplied = controller.mprROIAnnotations(for: .axial)

        XCTAssertEqual(presentation.graphicAnnotations.first?.referencedImages, [
            DicomPresentationReferencedImage(
                referencedSOPClassUID: source.referencedSOPClassUID,
                referencedSOPInstanceUID: source.referencedSOPInstanceUID,
                referencedFrameNumbers: source.referencedFrameNumbers
            )
        ])
        XCTAssertEqual(presentation.graphicAnnotations.first?.graphicObjects.first?.graphicFilled, true)
        XCTAssertEqual(state.graphicAnnotations.first?.kind, .polygon)
        XCTAssertEqual(state.graphicAnnotations.first?.sliceIndex, 1)
        XCTAssertEqual(reapplied.count, 1)
        XCTAssertEqual(reapplied.first?.kind, .closedPath)
        XCTAssertEqual(reapplied.first?.seriesIdentifier, "2.25.26111")
        XCTAssertEqual(reapplied.first?.sliceIndex, 1)
        XCTAssertEqual(reapplied.first?.normalizedImagePoints.first, CGPoint(x: 0, y: 0))
    }

    func testLabelmapMaskRoundTripsThroughSyntheticSegmentation() throws {
        let baseDataset = makeBaseDataset()
        let layer = try makeLabelmapLayer(baseDataset: baseDataset)
        let firstSource = sourceReference(frame: 1)
        let secondSource = sourceReference(frame: 2)
        let options = makeOptions(
            sopInstanceUID: "2.25.26121",
            sourceImageReferencesBySlice: [
                0: [firstSource],
                1: [secondSource]
            ]
        )

        let data = try ViewerROIDicomRoundTrip.makeSegmentationPart10Data(
            from: layer,
            options: options
        )
        let parsed = try XCTUnwrap(open(data: data, name: "roi_seg").segmentation)
        let reopened = try DicomSegmentationVolumeLayerBuilder.makeVolumeLayer(
            from: parsed,
            alignedTo: baseDataset,
            options: DicomSegmentationVolumeLayerOptions(includeSurfaceMeshLayers: false)
        )
        let labelmap = try XCTUnwrap(reopened.labelmap)

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.26121")
        XCTAssertEqual(parsed.segments.first?.number, 1)
        XCTAssertEqual(parsed.segments.first?.label, "Target")
        XCTAssertEqual(parsed.frames.count, 2)
        XCTAssertEqual(parsed.frames[0].sourceImageReferences, [firstSource])
        XCTAssertEqual(parsed.frames[1].sourceImageReferences, [secondSource])
        XCTAssertEqual(parsed.labelmapsBySegment[1]?.voxels, [1, 0, 0, 1, 0, 1, 0, 0])
        XCTAssertEqual(labelmap.segments.first?.name, "Target")
        XCTAssertEqual(littleEndianUInt16Values(labelmap.dataset.data), [1, 0, 0, 1, 0, 1, 0, 0])
    }

    private func makeOptions(
        sopInstanceUID: String,
        imageWidth: Int = 9,
        imageHeight: Int = 9,
        sourceImageReferencesBySlice: [Int: [DicomSourceImageReference]]
    ) -> ViewerROIDicomRoundTripOptions {
        ViewerROIDicomRoundTripOptions(
            sopInstanceUID: sopInstanceUID,
            studyInstanceUID: "2.25.261001",
            sourceSeriesInstanceUID: "2.25.261002",
            outputSeriesInstanceUID: "2.25.261003",
            sourceSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            sourceSOPInstanceUID: "2.25.261004",
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            sourceImageReferencesBySlice: sourceImageReferencesBySlice
        )
    }

    private func sourceReference(frame: Int) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.261004",
            referencedFrameNumbers: [frame]
        )
    }

    private func makeBaseDataset() -> VolumeDataset {
        VolumeDataset(
            data: Data(count: 2 * 2 * 2 * VolumePixelFormat.int16Signed.bytesPerVoxel),
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 0.7, y: 0.8, z: 1.5),
            pixelFormat: .int16Signed,
            intensityRange: -100...100,
            orientation: VolumeOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 1, 0),
                origin: SIMD3<Float>(10, 20, 30)
            ),
            clinicalMetadata: ClinicalImageMetadata(
                modality: "CT",
                studyInstanceUID: "2.25.261001",
                seriesInstanceUID: "2.25.261002"
            )
        )
    }

    private func makeLabelmapLayer(baseDataset: VolumeDataset) throws -> VolumeLayer {
        let values: [UInt16] = [1, 0, 0, 1, 0, 1, 0, 0]
        let dataset = VolumeDataset(
            data: littleEndianData(from: values),
            dimensions: baseDataset.dimensions,
            spacing: baseDataset.spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1,
            orientation: baseDataset.orientation,
            clinicalMetadata: baseDataset.imageData.clinicalMetadata
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [
                LabelmapSegment(label: 1,
                                name: "Target",
                                color: SIMD4<Float>(1, 0, 0, 1))
            ]
        )
        return VolumeLayer(id: "roi-mask", labelmap: labelmap)
    }

    private func open(data: Data, name: String) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func littleEndianData(from values: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<UInt16>.size)
        for value in values {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }

    private func littleEndianUInt16Values(_ data: Data) -> [UInt16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
        }
    }
}
