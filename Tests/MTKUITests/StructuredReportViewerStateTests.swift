import CoreGraphics
import Metal
@testable import MTKUI
import XCTest

final class StructuredReportViewerStateTests: XCTestCase {
    func testSelectionSynchronizesPanelAndOverlayFinding() {
        var state = StructuredReportViewerState(
            title: "CAD SR",
            treeRoot: StructuredReportTreeNode(id: "root", title: "Root", valueType: "CONTAINER"),
            cadFindings: [
                finding(id: "f1", type: "Nodule", point: CGPoint(x: 0.2, y: 0.3)),
                finding(id: "f2", type: "Calcification", point: CGPoint(x: 0.8, y: 0.7))
            ]
        )

        XCTAssertEqual(state.selectedFindingID, "f1")
        XCTAssertEqual(state.selectedFinding?.findingType, "Nodule")

        state.selectFinding(id: "f2")

        XCTAssertEqual(state.selectedFindingID, "f2")
        XCTAssertTrue(state.isSelected(state.cadFindings[1]))
        XCTAssertFalse(state.isSelected(state.cadFindings[0]))
    }

    func testFindingSanitizesConfidenceAndPreservesDetails() {
        let item = CADFindingOverlayItem(
            id: " finding ",
            findingType: " Mass ",
            characteristics: ["  spiculated  ", ""],
            confidenceScore: 1.25,
            graphicRegion: StructuredReportGraphicRegion(
                kind: .ellipse,
                normalizedPoints: [
                    CGPoint(x: -1, y: 0.25),
                    CGPoint(x: 2, y: 0.75)
                ]
            ),
            measurements: [
                StructuredReportMeasurementLine(id: "m", name: "Long Axis", value: 12.2, unit: "mm")
            ]
        )

        XCTAssertEqual(item.id, "finding")
        XCTAssertEqual(item.findingType, "Mass")
        XCTAssertEqual(item.characteristics, ["spiculated"])
        XCTAssertEqual(item.confidenceScore, 1)
        XCTAssertEqual(item.summaryText, "Mass 100%")
        XCTAssertEqual(item.detailLines, ["Mass 100%", "spiculated", "12.2 mm"])
        XCTAssertEqual(item.graphicRegion.normalizedPoints, [
            CGPoint(x: 0, y: 0.25),
            CGPoint(x: 1, y: 0.75)
        ])
    }

    @MainActor
    func testControllerPublishesStructuredReportSelectionState() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }
        let controller = try await ClinicalViewportGridController(initialViewportSize: CGSize(width: 16, height: 16))
        let state = StructuredReportViewerState(
            title: "CAD SR",
            treeRoot: StructuredReportTreeNode(id: "root", title: "Root", valueType: "CONTAINER"),
            cadFindings: [
                finding(id: "f1", type: "Nodule", point: CGPoint(x: 0.2, y: 0.3)),
                finding(id: "f2", type: "Mass", point: CGPoint(x: 0.5, y: 0.5))
            ]
        )

        controller.applyStructuredReportViewerState(state)
        controller.selectStructuredReportFinding(id: "f2")

        XCTAssertEqual(controller.structuredReportViewerState?.selectedFindingID, "f2")
        XCTAssertEqual(controller.cadFindingsForOverlay(axis: .axial).map(\.id), ["f1", "f2"])
    }

    private func finding(id: String, type: String, point: CGPoint) -> CADFindingOverlayItem {
        CADFindingOverlayItem(
            id: id,
            findingType: type,
            confidenceScore: 0.8,
            graphicRegion: StructuredReportGraphicRegion(kind: .point, normalizedPoints: [point])
        )
    }
}
