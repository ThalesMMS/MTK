import DicomCore
import MTKUI
@testable import MTKDicomBridge
import XCTest

final class DicomKeyObjectSelectionNavigationBridgeTests: XCTestCase {
    func testKeyObjectReferencesResolveLoadedInstances() throws {
        let keyObject = DicomKeyObjectReference(
            studyInstanceUID: "2.25.263001",
            seriesInstanceUID: "2.25.263002",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.263004",
            referencedFrameNumbers: [1]
        )
        let dataSet = DicomKeyObjectSelectionBuilder.dataSet(
            title: DicomCodedConcept(codeValue: "113000",
                                     codingSchemeDesignator: "DCM",
                                     codeMeaning: "Key Object"),
            keyObjects: [keyObject],
            studyInstanceUID: "2.25.263001",
            seriesInstanceUID: "2.25.263100",
            sopInstanceUID: "2.25.263200"
        )
        let decoder = try open(dataSet: dataSet,
                               sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID)
        let document = try XCTUnwrap(decoder.keyObjectSelection)
        let loadedInstances = [
            LoadedKeyImageInstance(
                studyInstanceUID: "2.25.263001",
                seriesInstanceUID: "2.25.263002",
                sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
                sopInstanceUID: "2.25.263003",
                sliceIndex: 0
            ),
            LoadedKeyImageInstance(
                studyInstanceUID: "2.25.263001",
                seriesInstanceUID: "2.25.263002",
                sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
                sopInstanceUID: "2.25.263004",
                sliceIndex: 7
            )
        ]

        let state = DicomKeyObjectSelectionNavigationBridge.makeState(
            from: document,
            loadedInstances: loadedInstances
        )

        XCTAssertEqual(state.references.map(\.referencedSOPInstanceUID), ["2.25.263004"])
        XCTAssertEqual(state.resolvedImages.map(\.sliceIndex), [7])
        XCTAssertEqual(state.selectedImage?.reference.referencedFrameNumbers, [1])
    }

    func testLoadedInstancesMapDecoderSliceOrder() {
        let instances = DicomKeyObjectSelectionNavigationBridge.makeLoadedInstances(from: [
            DicomSeriesImageInstance(
                studyInstanceUID: "2.25.study",
                seriesInstanceUID: "2.25.series",
                sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
                sopInstanceUID: "2.25.image",
                sliceIndex: 4,
                instanceNumber: 12
            )
        ])

        XCTAssertEqual(instances.first?.sopInstanceUID, "2.25.image")
        XCTAssertEqual(instances.first?.sliceIndex, 4)
        XCTAssertEqual(instances.first?.instanceNumber, 12)
    }

    private func open(dataSet: DicomDataSet, sopClassUID: String) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("key_object_selection_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }
}
