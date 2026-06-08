import XCTest
@testable import MTKCore

final class VolumeRenderQualitySettingsTests: XCTestCase {
    func testDefaultSettingsAreExplicitAndStable() {
        let settings = VolumeRenderQualitySettings.default

        XCTAssertEqual(settings.renderResolution, .high)
        XCTAssertEqual(settings.interactingResolution, .medium)
        XCTAssertEqual(settings.depthResolution, .high)
        XCTAssertEqual(settings.iterations, .medium)
        XCTAssertEqual(settings.shadowMode, .off)
        XCTAssertFalse(settings.disableShadowsWhenInteracting)
        XCTAssertEqual(settings.directionalLightIntensity, 1.0)
        XCTAssertEqual(settings.ambientLightIntensity, 0.2)
        XCTAssertEqual(settings.effectiveShadowMode(for: .production), .off)
        XCTAssertTrue(settings.lightingEnabled(for: .production))
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

    func testShadowModeShaderValuesAreStable() {
        XCTAssertEqual(VolumeShadowMode.off.shaderValue, 0)
        XCTAssertEqual(VolumeShadowMode.hard.shaderValue, 1)
        XCTAssertEqual(VolumeShadowMode.soft.shaderValue, 2)
        XCTAssertFalse(VolumeShadowMode.off.isEnabled)
        XCTAssertTrue(VolumeShadowMode.hard.isEnabled)
        XCTAssertTrue(VolumeShadowMode.soft.isEnabled)
    }

    func testEffectiveShadowModeReflectsInteractionAndLightIntensity() {
        let interacting = VolumeRenderQualitySettings(shadowMode: .soft,
                                                      disableShadowsWhenInteracting: true)
        let dark = VolumeRenderQualitySettings(shadowMode: .hard,
                                               directionalLightIntensity: 0)

        XCTAssertEqual(interacting.effectiveShadowMode(for: .interactive), .off)
        XCTAssertEqual(interacting.effectiveShadowMode(for: .production), .soft)
        XCTAssertEqual(dark.effectiveShadowMode(for: .production), .off)
    }

    func testDisablingShadowsDuringInteractionKeepsLightingEnabled() {
        let settings = VolumeRenderQualitySettings(shadowMode: .hard,
                                                   disableShadowsWhenInteracting: true)

        XCTAssertEqual(settings.effectiveShadowMode(for: .preview), .off)
        XCTAssertEqual(settings.effectiveShadowMode(for: .interactive), .off)
        XCTAssertEqual(settings.effectiveShadowMode(for: .production), .hard)
        XCTAssertTrue(settings.lightingEnabled(for: .preview))
        XCTAssertTrue(settings.lightingEnabled(for: .interactive))
        XCTAssertTrue(settings.lightingEnabled(for: .production))
    }
}
