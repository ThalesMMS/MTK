import XCTest
@testable import MTKCore

final class VolumeRenderingBuiltinPresetMetadataTests: XCTestCase {
    func test_allCases_haveNonEmptyDisplayName() {
        for preset in VolumeRenderingBuiltinPreset.allCases {
            XCTAssertFalse(preset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Expected non-empty displayName for \(preset)")
        }
    }

    func test_allCases_haveModalityAndCategory() {
        for preset in VolumeRenderingBuiltinPreset.allCases {
            XCTAssertFalse(
                preset.modality.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Expected non-empty modality for \(preset)"
            )
            XCTAssertFalse(
                preset.category.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Expected non-empty category for \(preset)"
            )
        }
    }

    func test_ctLiverVasculature_usesHepaticCategory() {
        XCTAssertEqual(VolumeRenderingBuiltinPreset.ctLiverVasculature.category, .hepatic)
    }
}
