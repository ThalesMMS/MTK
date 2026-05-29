import CoreGraphics
import DicomCore
import MTKUI
@testable import MTKDicomBridge
import XCTest

final class DicomStructuredReportViewerBridgeTests: XCTestCase {
    func testChestCADStructuredReportBuildsOverlayAndPanelState() {
        let source = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.262001",
            referencedFrameNumbers: [4]
        )
        let finding = cadFinding(
            trackingID: "finding-1",
            graphicType: "POINT",
            graphicData: [3, 3],
            source: source,
            findingType: "Pulmonary nodule",
            characteristic: "Spiculated margin",
            confidence: 0.91
        )
        let document = document(
            sopClassUID: DicomSRDocument.chestCADSRStorageSOPClassUID,
            children: [finding]
        )

        let state = DicomStructuredReportViewerBridge.makeState(
            from: document,
            options: DicomStructuredReportViewerBridgeOptions(imageWidth: 5, imageHeight: 5)
        )

        XCTAssertEqual(state.title, "CAD_SR")
        XCTAssertEqual(state.treeRoot.children.count, 1)
        XCTAssertEqual(state.measurements.first?.name, "Confidence Score")
        XCTAssertEqual(state.cadFindings.count, 1)
        XCTAssertEqual(state.cadFindings.first?.id, "finding-1")
        XCTAssertEqual(state.cadFindings.first?.findingType, "Pulmonary nodule")
        XCTAssertEqual(state.cadFindings.first?.characteristics, ["Spiculated margin"])
        XCTAssertEqual(state.cadFindings.first?.confidenceScore, 0.91)
        XCTAssertEqual(state.cadFindings.first?.graphicRegion.kind, .point)
        XCTAssertEqual(state.cadFindings.first?.graphicRegion.normalizedPoints, [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(state.cadFindings.first?.graphicRegion.sourceFrameNumbers, [4])
        XCTAssertEqual(state.selectedFindingID, "finding-1")
    }

    func testMammographyCADStructuredReportMapsPolylineCircleAndEllipseFindings() {
        let source = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.1",
            referencedSOPInstanceUID: "2.25.262011",
            referencedFrameNumbers: [1]
        )
        let document = document(
            sopClassUID: DicomSRDocument.mammographyCADSRStorageSOPClassUID,
            children: [
                cadFinding(trackingID: "polyline",
                           graphicType: "POLYLINE",
                           graphicData: [1, 1, 5, 1, 5, 5],
                           source: source,
                           findingType: "Architectural distortion",
                           characteristic: "Linear distribution",
                           confidence: 0.7),
                cadFinding(trackingID: "circle",
                           graphicType: "CIRCLE",
                           graphicData: [3, 3, 5, 3],
                           source: source,
                           findingType: "Mass",
                           characteristic: "Round",
                           confidence: 0.8),
                cadFinding(trackingID: "ellipse",
                           graphicType: "ELLIPSE",
                           graphicData: [2, 3, 4, 3, 3, 2, 3, 4],
                           source: source,
                           findingType: "Calcification cluster",
                           characteristic: "Grouped",
                           confidence: 0.6)
            ]
        )

        var state = DicomStructuredReportViewerBridge.makeState(
            from: document,
            options: DicomStructuredReportViewerBridgeOptions(imageWidth: 5, imageHeight: 5)
        )

        XCTAssertEqual(state.cadFindings.map(\.graphicRegion.kind), [.polyline, .circle, .ellipse])
        XCTAssertEqual(state.cadFindings.map(\.findingType), [
            "Architectural distortion",
            "Mass",
            "Calcification cluster"
        ])
        XCTAssertEqual(state.cadFindings[1].summaryText, "Mass 80%")
        XCTAssertEqual(state.cadFindings[2].graphicRegion.normalizedPoints, [
            CGPoint(x: 0.25, y: 0.5),
            CGPoint(x: 0.75, y: 0.5),
            CGPoint(x: 0.5, y: 0.25),
            CGPoint(x: 0.5, y: 0.75)
        ])

        state.selectFinding(id: "ellipse")

        XCTAssertEqual(state.selectedFinding?.findingType, "Calcification cluster")
    }

    private func document(sopClassUID: String,
                          children: [DicomSRContentItem]) -> DicomSRDocument {
        DicomSRDocument(
            sopClassUID: sopClassUID,
            sopInstanceUID: "2.25.262999",
            modality: "SR",
            contentLabel: "CAD_SR",
            contentDescription: "CAD structured report",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: DicomCodedConcept(codeValue: "126000",
                                               codingSchemeDesignator: "DCM",
                                               codeMeaning: "Imaging Measurement Report"),
                continuityOfContent: "SEPARATE",
                children: children
            )
        )
    }

    private func cadFinding(trackingID: String,
                            graphicType: String,
                            graphicData: [Double],
                            source: DicomSourceImageReference,
                            findingType: String,
                            characteristic: String,
                            confidence: Double) -> DicomSRContentItem {
        DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "CONTAINER",
            conceptName: DicomCodedConcept(codeValue: "111001",
                                           codingSchemeDesignator: "DCM",
                                           codeMeaning: "CAD Finding"),
            trackingID: trackingID,
            children: [
                DicomSRContentItem(
                    relationshipType: "HAS CONCEPT MOD",
                    valueType: "CODE",
                    conceptName: DicomCodedConcept(codeValue: "FINDING_TYPE",
                                                   codingSchemeDesignator: "99MTK",
                                                   codeMeaning: "Finding Type"),
                    codeValue: DicomCodedConcept(codeValue: findingType.uppercased().replacingOccurrences(of: " ", with: "_"),
                                                 codingSchemeDesignator: "99MTK",
                                                 codeMeaning: findingType)
                ),
                DicomSRContentItem(
                    relationshipType: "HAS CONCEPT MOD",
                    valueType: "CODE",
                    conceptName: DicomCodedConcept(codeValue: "FINDING_CHARACTERISTIC",
                                                   codingSchemeDesignator: "99MTK",
                                                   codeMeaning: "Finding Characteristic"),
                    codeValue: DicomCodedConcept(codeValue: characteristic.uppercased().replacingOccurrences(of: " ", with: "_"),
                                                 codingSchemeDesignator: "99MTK",
                                                 codeMeaning: characteristic)
                ),
                DicomSRContentItem(
                    relationshipType: "CONTAINS",
                    valueType: "NUM",
                    conceptName: DicomCodedConcept(codeValue: "CONFIDENCE",
                                                   codingSchemeDesignator: "99MTK",
                                                   codeMeaning: "Confidence Score"),
                    numericValue: confidence,
                    measurementUnits: DicomCodedConcept(codeValue: "1",
                                                        codingSchemeDesignator: "UCUM",
                                                        codeMeaning: "ratio"),
                    trackingID: "\(trackingID)-confidence"
                ),
                DicomSRContentItem(
                    relationshipType: "INFERRED FROM",
                    valueType: "SCOORD",
                    conceptName: DicomCodedConcept(codeValue: "111030",
                                                   codingSchemeDesignator: "DCM",
                                                   codeMeaning: "Image Region"),
                    referencedSOPs: [source],
                    graphicType: graphicType,
                    graphicData: graphicData
                )
            ]
        )
    }
}
