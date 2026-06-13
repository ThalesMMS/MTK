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

    func testUpdatePresetAppliesEffectiveRenderParameters() async throws {
        let request = makeRenderRequest()
        let preset = makeTestPreset(name: "MIP Preset",
                                    samplingDistance: 1.0 / 128.0,
                                    compositing: .maximumIntensity)

        _ = try await adapter.updatePreset(preset, for: request.dataset)
        _ = try await adapter.renderFrame(using: request)

        let snapshotOptional = await adapter.debugLastSnapshot
        let snapshot = try XCTUnwrap(snapshotOptional)
        XCTAssertEqual(snapshot.preset?.name, "MIP Preset")
        XCTAssertEqual(snapshot.metadata.compositing, .maximumIntensity)
        XCTAssertEqual(snapshot.metadata.samplingDistance, preset.samplingDistance, accuracy: 1e-6)
    }

    func testUpdatePresetAppliesTransferFunctionToSubsequentRenders() async throws {
        let transparentRequest = makeTransparentRenderRequest()
        let baselineFrame = try await adapter.renderFrame(using: transparentRequest)
        let baselineImage = try await TextureSnapshotExporter().makeCGImage(from: baselineFrame)
        XCTAssertFalse(VolumeRenderRegressionFixture.imageContainsVisiblePixels(baselineImage))

        let preset = makeTestPreset(name: "Visible Preset",
                                    transferFunction: makeVisibleTransferFunction(for: transparentRequest.dataset),
                                    samplingDistance: transparentRequest.samplingDistance,
                                    compositing: transparentRequest.compositing)

        _ = try await adapter.updatePreset(preset, for: transparentRequest.dataset)
        let frame = try await adapter.renderFrame(using: transparentRequest)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(image))
    }

    func testExplicitOverridesTakePrecedenceOverPresetParameters() async throws {
        let request = makeRenderRequest()
        let preset = makeTestPreset(name: "Preset Defaults",
                                    samplingDistance: 1.0 / 128.0,
                                    compositing: .maximumIntensity)

        _ = try await adapter.updatePreset(preset, for: request.dataset)
        try await adapter.send(.setCompositing(.averageIntensity))
        try await adapter.send(.setSamplingStep(1.0 / 64.0))
        _ = try await adapter.renderFrame(using: request)

        let snapshotOptional = await adapter.debugLastSnapshot
        let snapshot = try XCTUnwrap(snapshotOptional)
        XCTAssertEqual(snapshot.preset?.name, "Preset Defaults")
        XCTAssertEqual(snapshot.metadata.compositing, .averageIntensity)
        XCTAssertEqual(snapshot.metadata.samplingDistance, 1.0 / 64.0, accuracy: 1e-6)
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

    func testShiftChangesRenderedOutputAndTransferCache() async throws {
        let request = makeShiftSensitiveRenderRequest()
        let baselineFrame = try await adapter.renderFrame(using: request)
        let baselineImage = try await TextureSnapshotExporter().makeCGImage(from: baselineFrame)
        let baselineTransferTextureOptional = await adapter.debugTransferCacheTexture
        let baselineTransferTexture = try XCTUnwrap(baselineTransferTextureOptional)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(baselineImage))

        try await adapter.setShift(1_000)
        let shiftedFrame = try await adapter.renderFrame(using: request)
        let shiftedImage = try await TextureSnapshotExporter().makeCGImage(from: shiftedFrame)
        let shiftedSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(shiftedImage))
        let shiftedTransferTextureOptional = await adapter.debugTransferCacheTexture
        let shiftedTransferTexture = try XCTUnwrap(shiftedTransferTextureOptional)

        XCTAssertEqual(shiftedSummary.maxBlue, 0)
        XCTAssertEqual(shiftedSummary.maxGreen, 0)
        XCTAssertEqual(shiftedSummary.maxRed, 0)
        XCTAssertNotEqual(ObjectIdentifier(baselineTransferTexture as AnyObject),
                          ObjectIdentifier(shiftedTransferTexture as AnyObject))
    }

    func testToneCurveControlPointsChangeRenderedOutput() async throws {
        let request = makeRenderRequest()
        try await adapter.setToneCurveControlPoints([
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0)
        ], forChannel: 0)

        let darkFrame = try await adapter.renderFrame(using: request)
        let darkImage = try await TextureSnapshotExporter().makeCGImage(from: darkFrame)
        let darkSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(darkImage))

        XCTAssertEqual(darkSummary.maxBlue, 0)
        XCTAssertEqual(darkSummary.maxGreen, 0)
        XCTAssertEqual(darkSummary.maxRed, 0)

        try await adapter.setToneCurveControlPoints([
            SIMD2<Float>(0, 1),
            SIMD2<Float>(1, 1)
        ], forChannel: 0)

        let visibleFrame = try await adapter.renderFrame(using: request)
        let visibleImage = try await TextureSnapshotExporter().makeCGImage(from: visibleFrame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(visibleImage))
    }

    func testToneCurveGainChangesRenderedOutput() async throws {
        let request = makeRenderRequest()
        try await adapter.setToneCurveGain(0, forChannel: 0)

        let darkFrame = try await adapter.renderFrame(using: request)
        let darkImage = try await TextureSnapshotExporter().makeCGImage(from: darkFrame)
        let darkSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(darkImage))

        XCTAssertEqual(darkSummary.maxBlue, 0)
        XCTAssertEqual(darkSummary.maxGreen, 0)
        XCTAssertEqual(darkSummary.maxRed, 0)

        try await adapter.setToneCurveGain(1, forChannel: 0)

        let visibleFrame = try await adapter.renderFrame(using: request)
        let visibleImage = try await TextureSnapshotExporter().makeCGImage(from: visibleFrame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(visibleImage))
    }

    func testChannelIntensityControlsRenderedOutput() async throws {
        let request = makeRenderRequest()
        try await adapter.updateChannelIntensities([0, 0, 0, 0])

        let darkFrame = try await adapter.renderFrame(using: request)
        let darkImage = try await TextureSnapshotExporter().makeCGImage(from: darkFrame)
        let darkSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(darkImage))

        XCTAssertEqual(darkSummary.maxBlue, 0)
        XCTAssertEqual(darkSummary.maxGreen, 0)
        XCTAssertEqual(darkSummary.maxRed, 0)

        try await adapter.updateChannelIntensities([1, 0, 0, 0])

        let visibleFrame = try await adapter.renderFrame(using: request)
        let visibleImage = try await TextureSnapshotExporter().makeCGImage(from: visibleFrame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(visibleImage))
    }

    func testRenderFrameStandaloneOutputRemainsReadableAfterSubsequentRender() async throws {
        let firstFrame = try await adapter.renderFrame(using: makeRenderRequest())
        _ = try await adapter.renderFrame(using: makeTransparentRenderRequest())

        let image = try await TextureSnapshotExporter().makeCGImage(from: firstFrame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(image))
    }

    func testRenderInteractiveTextureReusesOutputForSameViewport() async throws {
        let firstTexture = try await adapter.renderInteractiveTexture(using: makeRenderRequest())
        let secondTexture = try await adapter.renderInteractiveTexture(using: makeRenderRequest())

        XCTAssertEqual(ObjectIdentifier(firstTexture as AnyObject),
                       ObjectIdentifier(secondTexture as AnyObject))
    }

    func testEnqueueInteractiveTextureProducesReadableOutput() async throws {
        let request = makeRenderRequest()
        let texture = try await adapter.enqueueInteractiveTexture(using: request)

        // A following completed render proves the queued interactive command has
        // drained through the adapter's in-flight lock before readback.
        _ = try await adapter.renderFrame(using: makeTransparentRenderRequest())

        let frame = VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(request: request, texture: texture)
        )
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)

        XCTAssertTrue(VolumeRenderRegressionFixture.imageContainsVisiblePixels(image))
    }

    func testEnqueueInteractiveFrameReportsDebugFrameIndex() async throws {
        let firstFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        defer { firstFrame.outputTextureLease?.release() }
        let secondFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        defer { secondFrame.outputTextureLease?.release() }

        XCTAssertEqual(firstFrame.metadata.debugFrameIndex, 0)
        XCTAssertEqual(secondFrame.metadata.debugFrameIndex, 1)
    }

    func testEnqueueInteractiveFramesUseDistinctOutputTexturesWhileLeasesArePending() async throws {
        let firstFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        let secondFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        let thirdFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        let frames = [firstFrame, secondFrame, thirdFrame]
        defer {
            frames.forEach { $0.outputTextureLease?.release() }
        }

        XCTAssertEqual(frames.compactMap(\.outputTextureLease).count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.outputTextureLease?.isReleased == false })

        let textureIDs = Set(frames.map { ObjectIdentifier($0.texture as AnyObject) })
        XCTAssertEqual(textureIDs.count, 3)
    }

    func testEnqueueInteractiveFrameDoesNotReuseTextureWhileLeaseIsPending() async throws {
        let firstFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        defer { firstFrame.outputTextureLease?.release() }
        let firstTextureID = ObjectIdentifier(firstFrame.texture as AnyObject)

        let secondFrame = try await adapter.enqueueInteractiveFrame(using: makeRenderRequest())
        defer { secondFrame.outputTextureLease?.release() }
        let secondTextureID = ObjectIdentifier(secondFrame.texture as AnyObject)

        XCTAssertNotEqual(firstTextureID, secondTextureID)
        XCTAssertFalse(firstFrame.outputTextureLease?.isReleased ?? true)
    }

    func testEnqueueInteractiveFusionFrameUsesCachedCompositeResources() async throws {
        try await adapter.send(.setWindow(min: -1_024, max: 1_024))
        let firstFrame = try await adapter.enqueueInteractiveFrame(using: makeFusionRenderRequest())
        defer { firstFrame.outputTextureLease?.release() }
        let secondFrame = try await adapter.enqueueInteractiveFrame(using: makeFusionRenderRequest())
        defer { secondFrame.outputTextureLease?.release() }

        XCTAssertNotNil(firstFrame.outputTextureLease)
        XCTAssertNotNil(secondFrame.outputTextureLease)
        let passCreationCount = await adapter.debugLayerCompositePassCreationCount
        let scratchTextureAllocationCount = await adapter.debugLayerStackScratchTextureAllocationCount

        XCTAssertEqual(passCreationCount, 1)
        XCTAssertEqual(scratchTextureAllocationCount, 3)
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

    func testPublicClipPlaneRemovesPixelsAcrossVolumeCompositingModes() async throws {
        let compositingModes: [VolumeRenderRequest.Compositing] = [
            .frontToBack,
            .maximumIntensity,
            .minimumIntensity,
            .averageIntensity
        ]

        for compositing in compositingModes {
            var request = VolumeRenderRegressionFixture.request(compositing: compositing)
            let plane = try VolumeClipPlane(textureCenteredNormal: SIMD3<Float>(0, 0, 1),
                                            offset: -1,
                                            dataset: request.dataset)
            request.clipping = try VolumeClippingState(clipPlanes: [plane])

            let frame = try await adapter.renderFrame(using: request)
            let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
            let summary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(image))

            XCTAssertEqual(summary.maxBlue, 0, "compositing \(compositing)")
            XCTAssertEqual(summary.maxGreen, 0, "compositing \(compositing)")
            XCTAssertEqual(summary.maxRed, 0, "compositing \(compositing)")
        }
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

    private func makeFusionRenderRequest() -> VolumeRenderRequest {
        let baseDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 16, height: 16, depth: 16),
            pixelFormat: .int16Signed,
            seed: 1
        )
        let overlayDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: baseDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 11
        )
        let doseDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: baseDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 21
        )
        let baseTransfer = makeVisibleTransferFunction(for: baseDataset)
        let overlayTransfer = makeVisibleTransferFunction(for: overlayDataset)
        let doseTransfer = makeVisibleTransferFunction(for: doseDataset)
        let layers = [
            VolumeLayer(id: "ct",
                        dataset: baseDataset,
                        transferFunction: baseTransfer),
            VolumeLayer(id: "pet",
                        dataset: overlayDataset,
                        transferFunction: overlayTransfer,
                        opacity: 0.5,
                        blendMode: .sourceOver),
            VolumeLayer(id: "dose",
                        dataset: doseDataset,
                        transferFunction: doseTransfer,
                        opacity: 0.25,
                        blendMode: .additive)
        ]
        return VolumeRenderRequest(
            dataset: baseDataset,
            transferFunction: baseTransfer,
            viewportSize: CGSize(width: 32, height: 32),
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: 1.0 / 32.0,
            compositing: .frontToBack,
            quality: .interactive,
            layers: layers
        )
    }

    private func makeShiftSensitiveRenderRequest() -> VolumeRenderRequest {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let values: [Int16] = Array(repeating: 500, count: dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: 0...1_000,
            recommendedWindow: 0...1_000
        )
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [
                    .init(intensity: 0, opacity: 0),
                    .init(intensity: 1_000, opacity: 1)
                ],
                colourPoints: [
                    .init(intensity: 0, colour: SIMD4<Float>(1, 1, 1, 1)),
                    .init(intensity: 1_000, colour: SIMD4<Float>(1, 1, 1, 1))
                ]
            ),
            viewportSize: VolumeRenderRegressionFixture.viewportSize,
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    private func makeTestPreset(name: String,
                                transferFunction: VolumeTransferFunction? = nil,
                                samplingDistance: Float = 0.002,
                                compositing: VolumeRenderRequest.Compositing = .frontToBack) -> VolumeRenderingPreset {
        let transfer = transferFunction ?? VolumeTransferFunction(
            opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
            colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0,
                                                                     colour: SIMD4<Float>(repeating: 1))]
        )
        return VolumeRenderingPreset(
            name: name,
            transferFunction: transfer,
            samplingDistance: samplingDistance,
            compositing: compositing
        )
    }

    private func makeVisibleTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        return VolumeTransferFunction(
            opacityPoints: [
                .init(intensity: lower, opacity: 1),
                .init(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                .init(intensity: lower, colour: SIMD4<Float>(1, 1, 1, 1)),
                .init(intensity: upper, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }

}
