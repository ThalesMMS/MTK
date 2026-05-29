import DicomCore
@testable import MTKDicomBridge
import MTKUI
import XCTest

final class DicomClinicalObjectDisplayBridgeTests: XCTestCase {
    func testEncapsulatedDocumentMapsToDocumentPanelStateAndExportPayload() {
        let payload = Data("<ClinicalDocument/>".utf8)
        let document = DicomEncapsulatedDocument(
            sopClassUID: DicomEncapsulatedDocument.encapsulatedCDAStorageSOPClassUID,
            sopInstanceUID: "2.25.document",
            documentTitle: "  Consult Note  ",
            mimeType: "text/xml",
            documentData: payload,
            sourceInstances: [
                DicomEncapsulatedDocumentSourceInstance(
                    referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                    referencedSOPInstanceUID: "2.25.source"
                )
            ]
        )

        let item = DicomClinicalObjectDisplayBridge.makeItem(from: document)

        XCTAssertEqual(item.id, "document-2.25.document")
        XCTAssertEqual(item.kind, .encapsulatedDocument)
        XCTAssertEqual(item.title, "Consult Note")
        XCTAssertEqual(item.documentState?.kind, .cda)
        XCTAssertEqual(item.documentState?.textPreview, "<ClinicalDocument/>")
        XCTAssertEqual(item.documentState?.sourceInstanceCount, 1)
        XCTAssertEqual(item.exportState?.suggestedFilename, "Consult-Note.xml")
        XCTAssertEqual(item.exportState?.data, payload)
    }

    func testWaveformMapsChannelsToTemporalTracesAndCSVExport() throws {
        let waveform = DicomWaveform(
            sopClassUID: DicomWaveform.twelveLeadECGWaveformStorageSOPClassUID,
            sopInstanceUID: "2.25.waveform",
            modality: "ECG",
            multiplexGroups: [
                DicomWaveformMultiplexGroup(
                    label: "Lead",
                    samplingFrequency: 500,
                    channels: [
                        DicomWaveformChannel(number: 1, label: "I", samples: [1, -1, 2]),
                        DicomWaveformChannel(number: 2, label: "II", samples: [2, -2, 4])
                    ]
                )
            ]
        )

        let item = DicomClinicalObjectDisplayBridge.makeItem(from: waveform)
        let state = try XCTUnwrap(item.waveformState)

        XCTAssertEqual(item.id, "waveform-2.25.waveform")
        XCTAssertEqual(item.kind, .waveform)
        XCTAssertEqual(state.traces.map(\.label), ["Lead I", "Lead II"])
        XCTAssertEqual(state.durationSeconds, 0.006)
        XCTAssertEqual(
            String(data: try XCTUnwrap(item.exportState?.data), encoding: .utf8)?
                .components(separatedBy: "\n"),
            ["sample,Lead I,Lead II", "0,1,2", "1,-1,-2", "2,2,4"]
        )
    }

    func testVideoMapsStreamMetadataForPlayerAndExportURL() throws {
        let streamURL = URL(fileURLWithPath: "/tmp/endoscopy.h264")
        let video = DicomVideo(
            sopClassUID: DicomVideo.videoEndoscopicImageStorageSOPClassUID,
            sopInstanceUID: "2.25.video",
            modality: "ES",
            imageType: ["ORIGINAL", "PRIMARY", "VIDEO"],
            transferSyntaxUID: DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41.rawValue,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            columns: 320,
            rows: 240,
            numberOfFrames: 60,
            frameTimeMilliseconds: 40,
            streamData: Data([1, 2, 3, 4]),
            encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor(
                pixelDataOffset: 0,
                numberOfFrames: 60,
                basicOffsetTable: DicomBasicOffsetTable(offsets: [], byteRange: 0..<0),
                extendedOffsetTable: nil,
                fragments: [],
                frameFragmentIndexes: [],
                diagnostics: []
            )
        )

        let item = DicomClinicalObjectDisplayBridge.makeItem(from: video, streamURL: streamURL)
        let state = try XCTUnwrap(item.videoState)

        XCTAssertEqual(item.id, "video-2.25.video")
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(state.codecLabel, "H.264")
        XCTAssertEqual(state.dimensionsLabel, "320 x 240")
        XCTAssertEqual(state.durationSeconds, 2.4)
        XCTAssertEqual(state.streamURL, streamURL)
        XCTAssertEqual(item.exportState?.sourceURL, streamURL)
    }
}
