import XCTest
@testable import MTKCore

final class VolumeRenderQualitySettingsTests: XCTestCase {
    func testDefaultSettingsAreExplicitAndStable() {
        let settings = VolumeRenderQualitySettings.default

        XCTAssertEqual(settings.renderResolution, .high)
        XCTAssertEqual(settings.interactingResolution, .medium)
        XCTAssertEqual(settings.depthResolution, .high)
        XCTAssertEqual(settings.iterations, .medium)
        XCTAssertEqual(settings.shadowMode, .hard)
        XCTAssertFalse(settings.disableShadowsWhenInteracting)
        XCTAssertEqual(settings.directionalLightIntensity, 1.0)
        XCTAssertEqual(settings.ambientLightIntensity, 0.2)
    }

    func testSettingsRoundTripThroughCodable() throws {
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .low,
                                                   depthResolution: .medium,
                                                   iterations: .high,
                                                   shadowMode: .soft,
                                                   disableShadowsWhenInteracting: true,
                                                   directionalLightIntensity: 1.4,
                                                   ambientLightIntensity: 0.35)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VolumeRenderQualitySettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testSamplingMappingCombinesResolutionAndIterations() {
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .medium,
                                                   depthResolution: .low,
                                                   iterations: .high)

        XCTAssertEqual(settings.finalSamplingStep, 1_280)
        XCTAssertEqual(settings.interactingSamplingStep, 640)
        XCTAssertEqual(settings.interactionSamplingFactor, 0.5)
        XCTAssertEqual(settings.depthGradientScale, 2.0)
    }

    func testSanitizedSettingsClampLightIntensities() {
        let settings = VolumeRenderQualitySettings(directionalLightIntensity: 12,
                                                   ambientLightIntensity: -1).sanitized

        XCTAssertEqual(settings.directionalLightIntensity, 2)
        XCTAssertEqual(settings.ambientLightIntensity, 0)
    }

    func testLightingIsDisabledForInteractiveQualityWhenRequested() {
        let settings = VolumeRenderQualitySettings(shadowMode: .hard,
                                                   disableShadowsWhenInteracting: true)

        XCTAssertFalse(settings.lightingEnabled(for: .preview))
        XCTAssertFalse(settings.lightingEnabled(for: .interactive))
        XCTAssertTrue(settings.lightingEnabled(for: .production))
    }
}
