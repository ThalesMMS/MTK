@testable import MTKUI
import XCTest

final class ClinicalEncapsulatedDocumentViewTests: XCTestCase {
    func testDocumentStateNormalizesMetadataAndTextPreview() {
        let state = ClinicalEncapsulatedDocumentDisplayState(
            title: "  Discharge Summary  ",
            kind: .cda,
            mimeType: " text/xml ",
            byteCount: 18,
            preferredFileExtension: " xml ",
            sourceInstanceCount: 2,
            documentData: Data(" <ClinicalDocument/> ".utf8)
        )

        XCTAssertEqual(state.title, "Discharge Summary")
        XCTAssertEqual(state.displayTitle, "Discharge Summary")
        XCTAssertEqual(state.mimeType, "text/xml")
        XCTAssertEqual(state.preferredFileExtension, "xml")
        XCTAssertEqual(state.sourceInstanceCount, 2)
        XCTAssertEqual(state.textPreview, "<ClinicalDocument/>")
        XCTAssertTrue(state.isExportable)
    }

    func testDocumentKindResolvesFromMIMEOrExtension() {
        XCTAssertEqual(ClinicalEncapsulatedDocumentKind(mimeType: "application/pdf"), .pdf)
        XCTAssertEqual(ClinicalEncapsulatedDocumentKind(mimeType: "application/octet-stream", preferredFileExtension: "stl"), .stl)
        XCTAssertEqual(ClinicalEncapsulatedDocumentKind(mimeType: "application/xml"), .cda)
        XCTAssertEqual(ClinicalEncapsulatedDocumentKind(mimeType: "application/octet-stream"), .other)
    }

#if canImport(SwiftUI)
    @MainActor
    func testClinicalEncapsulatedDocumentViewCompiles() {
        let state = ClinicalEncapsulatedDocumentDisplayState(
            kind: .pdf,
            mimeType: "application/pdf",
            byteCount: 9,
            preferredFileExtension: "pdf",
            documentData: Data("%PDF-1.4".utf8)
        )

        _ = ClinicalEncapsulatedDocumentView(state: state)
    }
#endif
}
