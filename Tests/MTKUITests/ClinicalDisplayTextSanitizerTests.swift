@testable import MTKUI
import XCTest

final class ClinicalDisplayTextSanitizerTests: XCTestCase {
    func testSafeSeriesTitleRejectsEmptyValues() {
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle(nil))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle(""))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("   \n\t  "))
    }

    func testSafeSeriesTitleRejectsDICOMPersonNameValues() {
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("DOE^JANE"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("PatientName=DOE^JANE"))
    }

    func testSafeSeriesTitleRejectsPatientLabelsAndIdentifiers() {
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("Patient ID 123456"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("MRN: 123456"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("DOB 1970-01-01"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("(0010,0010) DOE^JANE"))
    }

    func testSafeSeriesTitleRejectsAgeAndSexDemographics() {
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("CT ABDOMEN 045Y F"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("CT ABDOMEN 52yo F"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSeriesTitle("Brain 52 years Male"))
    }

    func testSafeSeriesTitleAcceptsClinicalSeriesDescriptions() {
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSeriesTitle("CT Abdomen Venous"),
                       "CT Abdomen Venous")
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSeriesTitle("  Synthetic   CT + PET\nfusion  "),
                       "Synthetic CT + PET fusion")
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSeriesTitle("MPR Axial Recon"),
                       "MPR Axial Recon")
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSeriesTitle("CTA Abdomen F/U 52yo"),
                       "CTA Abdomen F/U 52yo")
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSeriesTitle("CT Chest 45yo F/U"),
                       "CT Chest 45yo F/U")
    }

    func testChromeTitleUsesFallbackForUnsafeValues() {
        XCTAssertEqual(ClinicalDisplayTextSanitizer.chromeTitle("DOE^JANE",
                                                                fallback: "Volume Rendering"),
                       "Volume Rendering")
        XCTAssertEqual(ClinicalDisplayTextSanitizer.chromeTitle("CT Chest",
                                                                fallback: "Clinical Viewer"),
                       "CT Chest")
    }

    func testSafeSubjectNameFormatsDicomPersonNameWithoutFallback() {
        XCTAssertEqual(ClinicalDisplayTextSanitizer.safeSubjectName("Sample^Subject"), "Sample Subject")
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSubjectName(nil))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSubjectName(""))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSubjectName("Patient ID 123456"))
        XCTAssertNil(ClinicalDisplayTextSanitizer.safeSubjectName("Brain 52 years Male"))
    }
}
