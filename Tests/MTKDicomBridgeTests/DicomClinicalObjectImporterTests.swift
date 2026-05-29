import DicomCore
@testable import MTKDicomBridge
import XCTest

final class DicomClinicalObjectImporterTests: XCTestCase {
    func testImporterLoadsEncapsulatedDocumentWithoutVolumeAssembly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("consult.dcm")
        try DicomEncapsulatedDocumentBuilder.write(
            documentData: Data("%PDF-1.4".utf8),
            to: url,
            options: DicomEncapsulatedDocumentBuildOptions(
                kind: .pdf,
                sopInstanceUID: "2.25.123456",
                documentTitle: "Consult Note"
            )
        )
        let importer = DicomClinicalObjectImporter(callbackQueue: .global())
        let expectation = expectation(description: "Clinical object import completes")
        var captured: Result<DicomClinicalObjectImportResult, Error>?

        importer.loadObjects(from: url) { result in
            captured = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        let result = try XCTUnwrap(captured).get()
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects.first?.kind, .encapsulatedDocument)
        XCTAssertEqual(result.objects.first?.documentState?.kind, .pdf)
        XCTAssertEqual(result.objects.first?.exportState?.data, Data("%PDF-1.4".utf8))
    }
}
