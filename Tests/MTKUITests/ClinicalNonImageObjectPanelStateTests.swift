@testable import MTKUI
import XCTest

final class ClinicalNonImageObjectPanelStateTests: XCTestCase {
    func testPanelStateNavigatesObjectsAndWraps() {
        let state = ClinicalNonImageObjectPanelState(items: [
            item(id: "doc", kind: .encapsulatedDocument),
            item(id: "wave", kind: .waveform),
            item(id: "video", kind: .video)
        ])

        XCTAssertEqual(state.selectedItem?.id, "doc")
        XCTAssertEqual(state.selectedItemNumberLabel, "1 / 3")
        XCTAssertEqual(state.selectingNext().selectedItem?.id, "wave")
        XCTAssertEqual(state.selectingPrevious().selectedItem?.id, "video")
        XCTAssertEqual(state.selectingItem(id: "video").selectedItemNumberLabel, "3 / 3")
    }

    func testExportStateRequiresDataOrSourceURL() {
        XCTAssertFalse(ClinicalObjectExportState(suggestedFilename: "", byteCount: -1).isExportable)
        XCTAssertTrue(ClinicalObjectExportState(
            suggestedFilename: "waveform.csv",
            byteCount: 4,
            data: Data("a,b\n".utf8)
        ).isExportable)
        XCTAssertTrue(ClinicalObjectExportState(
            suggestedFilename: "video.h264",
            byteCount: 4,
            sourceURL: URL(fileURLWithPath: "/tmp/video.h264")
        ).isExportable)
    }

#if canImport(SwiftUI)
    @MainActor
    func testClinicalNonImageObjectPanelViewCompiles() {
        var state = ClinicalNonImageObjectPanelState(items: [item(id: "doc", kind: .encapsulatedDocument)])
        _ = ClinicalNonImageObjectPanelView(state: .init(get: { state }, set: { state = $0 }))
    }
#endif

    private func item(id: String, kind: ClinicalNonImageObjectKind) -> ClinicalNonImageObjectDisplayItem {
        ClinicalNonImageObjectDisplayItem(id: id, kind: kind, title: id)
    }
}
