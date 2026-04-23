//
//  MetalVolumeRenderingAdapterSPITests.swift
//  MTK
//
//  Unit tests for MetalVolumeRenderingAdapter SPI debug properties.
//

import CoreGraphics
import Foundation
import Metal
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

// MARK: - SPI Testing Properties (MetalVolumeRenderingAdapter+Testing.swift)

final class MetalVolumeRenderingAdapterSPIPropertiesTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testDebugOverridesReflectsDefaultState() async {
        let overrides = await adapter.debugOverrides
        XCTAssertNil(overrides.compositing, "Default compositing override should be nil")
        XCTAssertNil(overrides.samplingDistance, "Default samplingDistance override should be nil")
        XCTAssertNil(overrides.window, "Default window override should be nil")
        XCTAssertTrue(overrides.lightingEnabled, "Default lightingEnabled override should be true")
    }

    func testDebugOverridesReflectsChangesViaSend() async throws {
        try await adapter.send(.setWindow(min: -500, max: 1500))
        let overrides = await adapter.debugOverrides
        XCTAssertEqual(overrides.window, -500...1500)
    }

    func testDebugOverridesReflectsCompositingChange() async throws {
        try await adapter.send(.setCompositing(.maximumIntensity))
        let overrides = await adapter.debugOverrides
        XCTAssertEqual(overrides.compositing, .maximumIntensity)
    }

    func testDebugOverridesReflectsLightingChange() async throws {
        try await adapter.send(.setLighting(false))
        let overrides = await adapter.debugOverrides
        XCTAssertFalse(overrides.lightingEnabled)
    }

    func testDebugLastSnapshotIsNilBeforeRendering() async {
        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNil(snapshot, "lastSnapshot should be nil before any render")
    }

    func testDebugCurrentPresetIsNilByDefault() async {
        let preset = await adapter.debugCurrentPreset
        XCTAssertNil(preset, "currentPreset should be nil by default")
    }

    func testDebugCurrentPresetReflectsUpdatePresetCall() async throws {
        let preset = makeTestPreset(name: "CT Bone")
        let dataset = makeDataset()
        _ = try await adapter.updatePreset(preset, for: dataset)
        let current = await adapter.debugCurrentPreset
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.name, "CT Bone")
    }

    func testDebugLastSnapshotContainsCorrectWindowAfterRender() async throws {
        let window: ClosedRange<Int32> = -500...1500
        try await adapter.send(.setWindow(min: window.lowerBound, max: window.upperBound))
        let request = makeRenderRequest()
        _ = try await adapter.renderFrame(using: request)
        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot, "lastSnapshot should be set after a successful render")
        XCTAssertEqual(snapshot?.window, window)
    }

    func testRenderFrameProducesVisiblePixels() async throws {
        let frame = try await adapter.renderFrame(using: makeRenderRequest())
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let summary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(image))

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(image),
                      "pixel summary: \(summary)")
    }

    func testRenderFrameStandaloneOutputRemainsReadableAfterSubsequentRender() async throws {
        let firstFrame = try await adapter.renderFrame(using: makeRenderRequest())
        _ = try await adapter.renderFrame(using: makeTransparentRenderRequest())

        let image = try await TextureSnapshotExporter().makeCGImage(from: firstFrame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(image))
    }

    func testProjectionCompositingDisablesTransferFunctionProjectionPath() async throws {
        let baseRequest = makeRenderRequest()
        let expectations: [(VolumeRenderRequest.Compositing, Int32)] = [
            (.maximumIntensity, 2),
            (.minimumIntensity, 3),
            (.averageIntensity, 4)
        ]

        for (compositing, expectedMethod) in expectations {
            let request = VolumeRenderRequest(
                dataset: makeDataset(),
                transferFunction: baseRequest.transferFunction,
                viewportSize: CGSize(width: 64, height: 64),
                camera: baseRequest.camera,
                samplingDistance: 1.0 / 64.0,
                compositing: compositing,
                quality: .interactive
            )

            let uniforms = try await adapter.buildVolumeUniforms(for: request)

            XCTAssertEqual(uniforms.method, expectedMethod)
            XCTAssertEqual(uniforms.useTFProj, 0)
        }
    }

    func testFrontToBackCompositingKeepsTransferFunctionProjectionPathEnabled() async throws {
        let request = makeRenderRequest()

        let uniforms = try await adapter.buildVolumeUniforms(for: request)

        XCTAssertEqual(uniforms.method, 1)
        XCTAssertEqual(uniforms.useTFProj, 1)
    }

    private func makeDataset() -> VolumeDataset {
        VolumeRenderRegressionFixture.dataset()
    }

    private func makeRenderRequest() -> VolumeRenderRequest {
        VolumeRenderRegressionFixture.request()
    }

    private func makeTransparentRenderRequest() -> VolumeRenderRequest {
        let dataset = makeDataset()
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [
                    .init(intensity: Float(dataset.intensityRange.lowerBound), opacity: 0),
                    .init(intensity: Float(dataset.intensityRange.upperBound), opacity: 0)
                ],
                colourPoints: [
                    .init(intensity: Float(dataset.intensityRange.lowerBound), colour: SIMD4<Float>(1, 1, 1, 1)),
                    .init(intensity: Float(dataset.intensityRange.upperBound), colour: SIMD4<Float>(1, 1, 1, 1))
                ]
            ),
            viewportSize: VolumeRenderRegressionFixture.viewportSize,
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    private func makeTestPreset(name: String) -> VolumeRenderingPreset {
        let transfer = VolumeTransferFunction(
            opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
            colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(repeating: 1))]
        )
        return VolumeRenderingPreset(
            name: name,
            transferFunction: transfer,
            samplingDistance: 0.002,
            compositing: .frontToBack
        )
    }

}
