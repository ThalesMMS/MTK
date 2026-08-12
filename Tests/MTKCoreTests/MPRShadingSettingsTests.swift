import XCTest

@testable import MTKCore

final class MPRShadingSettingsTests: XCTestCase {
    func test_defaultDisablesShadingAndUsesDocumentedComponents() {
        XCTAssertFalse(MPRShadingSettings.default.isEnabled)
        XCTAssertEqual(MPRShadingSettings.default.ambient, 0.35)
        XCTAssertEqual(MPRShadingSettings.default.diffuse, 0.55)
        XCTAssertEqual(MPRShadingSettings.default.specular, 0.10)
        XCTAssertEqual(MPRShadingSettings.componentRange, 0...1)
    }

    func test_sanitizedClampsFiniteComponentsAndReplacesNonFiniteValues() {
        let settings = MPRShadingSettings(
            isEnabled: true,
            ambient: -1,
            diffuse: 4,
            specular: .nan
        ).sanitized

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.ambient, 0)
        XCTAssertEqual(settings.diffuse, 1)
        XCTAssertEqual(settings.specular, MPRShadingSettings.default.specular)
    }
}
