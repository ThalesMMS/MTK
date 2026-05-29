import Foundation
import MTKCore

extension ClinicalViewportGridController {
    public func applyStructuredReportViewerState(_ state: StructuredReportViewerState?) {
        structuredReportViewerState = state
    }

    public func selectStructuredReportFinding(id: CADFindingOverlayItem.ID?) {
        guard var state = structuredReportViewerState else { return }
        state.selectFinding(id: id)
        structuredReportViewerState = state
    }

    func cadFindingsForOverlay(axis: MTKCore.Axis) -> [CADFindingOverlayItem] {
        guard let state = structuredReportViewerState else { return [] }
        guard let sliceIndex = currentMPRSliceIndex(for: axis) else {
            return state.cadFindings
        }
        let frameNumber = sliceIndex + 1
        return state.cadFindings.filter { finding in
            finding.graphicRegion.sourceFrameNumbers.isEmpty ||
                finding.graphicRegion.sourceFrameNumbers.contains(frameNumber)
        }
    }
}
