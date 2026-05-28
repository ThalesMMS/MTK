import XCTest
@testable import MTKCore

@MainActor
final class RenderQualitySchedulerTests: XCTestCase {
    func testBeginInteractionUsesPreviewParameters() {
        let scheduler = RenderQualityScheduler(baseSamplingStep: 512,
                                               baseSlabSteps: 9,
                                               interactionFactor: 0.5)

        scheduler.beginInteraction()

        XCTAssertEqual(scheduler.state, .interacting)
        XCTAssertEqual(scheduler.currentParameters.volumeSamplingStep, 256)
        XCTAssertEqual(scheduler.currentParameters.mprSlabStepsFactor, 0.5)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)
        XCTAssertEqual(scheduler.currentSlabSteps, 5)
    }

    func testEndInteractionSettlesToFinalAfterDebounce() async throws {
        let scheduler = RenderQualityScheduler(baseSamplingStep: 512,
                                               baseSlabSteps: 9,
                                               interactionFactor: 0.5,
                                               settlingDelayNanoseconds: 10_000_000)

        scheduler.beginInteraction()
        scheduler.endInteraction()

        XCTAssertEqual(scheduler.state, .settling)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)

        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(scheduler.state, .settled)
        XCTAssertEqual(scheduler.currentParameters.volumeSamplingStep, 512)
        XCTAssertEqual(scheduler.currentParameters.mprSlabStepsFactor, 1)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .production)
        XCTAssertEqual(scheduler.currentSlabSteps, 9)
    }

    func testNewInteractionCancelsPendingSettle() async throws {
        let scheduler = RenderQualityScheduler(settlingDelayNanoseconds: 20_000_000)

        scheduler.beginInteraction()
        scheduler.endInteraction()
        scheduler.beginInteraction()

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(scheduler.state, .interacting)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)
    }

    func testOverlappingInteractionsSettleOnlyAfterAllEnd() async throws {
        let scheduler = RenderQualityScheduler(settlingDelayNanoseconds: 10_000_000)

        scheduler.beginInteraction()
        scheduler.beginInteraction()
        scheduler.endInteraction()

        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(scheduler.state, .interacting)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)

        scheduler.endInteraction()
        XCTAssertEqual(scheduler.state, .settling)

        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(scheduler.state, .settled)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .production)
    }

    func testForceSettledImmediatelyRestoresFinalParameters() {
        let scheduler = RenderQualityScheduler(baseSamplingStep: 320,
                                               baseSlabSteps: 7,
                                               interactionFactor: 0.5)

        scheduler.beginInteraction()
        scheduler.forceSettled()

        XCTAssertEqual(scheduler.state, .settled)
        XCTAssertEqual(scheduler.currentParameters.volumeSamplingStep, 320)
        XCTAssertEqual(scheduler.currentSlabSteps, 7)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .production)
    }

    func testApplyingVolumeRenderQualitySettingsMapsFinalAndInteractiveSampling() {
        let scheduler = RenderQualityScheduler(baseSamplingStep: 512,
                                               interactionFactor: 0.5)
        let settings = VolumeRenderQualitySettings(renderResolution: .high,
                                                   interactingResolution: .low,
                                                   depthResolution: .high,
                                                   iterations: .medium)

        scheduler.applyVolumeRenderQualitySettings(settings)

        XCTAssertEqual(scheduler.baseSamplingStep, 768)
        XCTAssertEqual(scheduler.interactionFactor, Float(1.0 / 3.0), accuracy: 0.0001)

        scheduler.beginInteraction()
        XCTAssertEqual(scheduler.currentParameters.volumeSamplingStep, 256, accuracy: 0.0001)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)
    }

    func testApplyingVolumeRenderQualitySettingsDuringInteractionKeepsPreviewState() {
        let scheduler = RenderQualityScheduler(baseSamplingStep: 512,
                                               interactionFactor: 0.5)
        scheduler.beginInteraction()
        let settings = VolumeRenderQualitySettings(renderResolution: .fantastic,
                                                   interactingResolution: .medium,
                                                   depthResolution: .high,
                                                   iterations: .medium)

        scheduler.applyVolumeRenderQualitySettings(settings)

        XCTAssertEqual(scheduler.state, .interacting)
        XCTAssertEqual(scheduler.currentParameters.qualityTier, .preview)
        XCTAssertEqual(scheduler.currentParameters.volumeSamplingStep, 512, accuracy: 0.0001)
    }
}
