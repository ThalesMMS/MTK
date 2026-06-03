//
//  MetalVolumeRenderingAdapterParameterTests.swift
//  MTK
//
//  Unit tests for MetalVolumeRenderingAdapter parameter helpers.
//

import Foundation
import Metal
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

// MARK: - clipPlanes function (MetalVolumeRenderingAdapter+Parameters.swift)

final class ClipPlanesTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testPreset0ReturnsAllZeroPlanes() async {
        let planes = await adapter.clipPlanes(preset: 0, offset: 0)
        XCTAssertEqual(planes.0, .zero, "preset 0: plane 0 should be zero")
        XCTAssertEqual(planes.1, .zero, "preset 0: plane 1 should be zero")
        XCTAssertEqual(planes.2, .zero, "preset 0: plane 2 should be zero")
    }

    func testPreset1AxialReturnsCorrectNormal() async {
        let planes = await adapter.clipPlanes(preset: 1, offset: 0)
        // Axial: normal (0, 0, 1), offset 0
        XCTAssertEqual(planes.0.x, 0, accuracy: 1e-6, "axial: normal.x should be 0")
        XCTAssertEqual(planes.0.y, 0, accuracy: 1e-6, "axial: normal.y should be 0")
        XCTAssertEqual(planes.0.z, 1, accuracy: 1e-6, "axial: normal.z should be 1")
        XCTAssertEqual(planes.0.w, 0, accuracy: 1e-6, "axial: offset should be 0 when no offset")
        XCTAssertEqual(planes.1, .zero, "axial: plane 1 should be zero")
        XCTAssertEqual(planes.2, .zero, "axial: plane 2 should be zero")
    }

    func testPreset2SagittalReturnsCorrectNormal() async {
        let planes = await adapter.clipPlanes(preset: 2, offset: 0)
        // Sagittal: normal (1, 0, 0)
        XCTAssertEqual(planes.0.x, 1, accuracy: 1e-6, "sagittal: normal.x should be 1")
        XCTAssertEqual(planes.0.y, 0, accuracy: 1e-6, "sagittal: normal.y should be 0")
        XCTAssertEqual(planes.0.z, 0, accuracy: 1e-6, "sagittal: normal.z should be 0")
        XCTAssertEqual(planes.0.w, 0, accuracy: 1e-6, "sagittal: offset should be 0 when no offset")
        XCTAssertEqual(planes.1, .zero)
        XCTAssertEqual(planes.2, .zero)
    }

    func testPreset3CoronalReturnsCorrectNormal() async {
        let planes = await adapter.clipPlanes(preset: 3, offset: 0)
        // Coronal: normal (0, 1, 0)
        XCTAssertEqual(planes.0.x, 0, accuracy: 1e-6, "coronal: normal.x should be 0")
        XCTAssertEqual(planes.0.y, 1, accuracy: 1e-6, "coronal: normal.y should be 1")
        XCTAssertEqual(planes.0.z, 0, accuracy: 1e-6, "coronal: normal.z should be 0")
        XCTAssertEqual(planes.0.w, 0, accuracy: 1e-6, "coronal: offset should be 0 when no offset")
        XCTAssertEqual(planes.1, .zero)
        XCTAssertEqual(planes.2, .zero)
    }

    func testOffsetIsNegatedInPlaneW() async {
        // offset is stored as -offset (planeOffset = -offset)
        let offset: Float = 0.3
        let planes = await adapter.clipPlanes(preset: 1, offset: offset)
        XCTAssertEqual(planes.0.w, -offset, accuracy: 1e-6,
                       "plane w component should be negated offset")
    }

    func testNegativeOffsetIsNegatedToPositiveW() async {
        let offset: Float = -0.5
        let planes = await adapter.clipPlanes(preset: 2, offset: offset)
        XCTAssertEqual(planes.0.w, -offset, accuracy: 1e-6,
                       "negative offset should produce positive plane w")
    }

    func testUnknownPresetReturnsAllZeroPlanes() async {
        for preset in [4, 99, -1] {
            let planes = await adapter.clipPlanes(preset: preset, offset: 0)
            XCTAssertEqual(planes.0, .zero, "preset \(preset): plane 0 should be zero")
            XCTAssertEqual(planes.1, .zero, "preset \(preset): plane 1 should be zero")
            XCTAssertEqual(planes.2, .zero, "preset \(preset): plane 2 should be zero")
        }
    }

    // Boundary: offset zero always leaves w = 0 for all valid presets.
    func testZeroOffsetAllPresetsHaveZeroW() async {
        for preset in [1, 2, 3] {
            let planes = await adapter.clipPlanes(preset: preset, offset: 0)
            XCTAssertEqual(planes.0.w, 0, accuracy: 1e-6,
                           "preset \(preset) with zero offset should have zero w")
        }
    }
}

// MARK: - computeOptionFlags (MetalVolumeRenderingAdapter+Parameters.swift)

final class ComputeOptionFlagsTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testDefaultStateProducesZeroFlags() async {
        // Default extendedState has adaptiveEnabled = false
        let flags = await adapter.computeOptionFlags()
        XCTAssertEqual(flags, 0, "Default state should produce zero option flags")
    }

    func testAdaptiveEnabledSetsBit2() async {
        await adapter.setAdaptiveEnabledForTesting(true)
        let flags = await adapter.computeOptionFlags()
        XCTAssertNotEqual(flags, 0, "Adaptive enabled should produce non-zero flags")
        XCTAssertTrue((flags & (1 << 2)) != 0, "Bit 2 should be set when adaptive is enabled")
    }

    func testAdaptiveDisabledClearsBit2() async {
        // Enable then disable
        await adapter.setAdaptiveEnabledForTesting(true)
        await adapter.setAdaptiveEnabledForTesting(false)
        let flags = await adapter.computeOptionFlags()
        XCTAssertEqual(flags & (1 << 2), 0, "Bit 2 should be clear when adaptive is disabled")
    }

    func testOtherBitsAreZeroWhenAdaptiveEnabled() async {
        await adapter.setAdaptiveEnabledForTesting(true)
        let flags = await adapter.computeOptionFlags()
        let bit2Mask: UInt16 = (1 << 2)
        XCTAssertEqual(flags & ~bit2Mask, 0, "Only bit 2 should be set when adaptive is enabled")
    }
}

extension MetalVolumeRenderingAdapter {
    fileprivate func setAdaptiveEnabledForTesting(_ value: Bool) {
        extendedState.adaptiveEnabled = value
    }
}

// MARK: - Gate uniforms

final class GateUniformTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testDensityGateDoesNotEnableHuGate() async throws {
        try await adapter.send(.setWindow(min: -1024, max: 1023))
        try await adapter.setDensityGate(floor: 0.2, ceil: 0.8)

        let uniforms = try await adapter.buildVolumeUniforms(for: makeRequest())

        XCTAssertEqual(uniforms.useHuGate, 0)
        XCTAssertEqual(uniforms.densityFloor, 0.2, accuracy: 1e-6)
        XCTAssertEqual(uniforms.densityCeil, 0.8, accuracy: 1e-6)
    }

    func testHuGateUsesRawHUUniforms() async throws {
        try await adapter.send(.setWindow(min: -1024, max: 1023))
        try await adapter.setHuGate(enabled: true, minHU: 150, maxHU: 400)

        let uniforms = try await adapter.buildVolumeUniforms(for: makeRequest())

        XCTAssertEqual(uniforms.useHuGate, 1)
        XCTAssertEqual(uniforms.gateHuMin, 150)
        XCTAssertEqual(uniforms.gateHuMax, 400)
    }

    func testRenderQualitySettingsPopulateLightingUniforms() async throws {
        try await adapter.send(.setWindow(min: -1024, max: 1023))
        let settings = VolumeRenderQualitySettings(renderResolution: .high,
                                                   interactingResolution: .medium,
                                                   depthResolution: .low,
                                                   iterations: .medium,
                                                   shadowMode: .soft,
                                                   directionalLightIntensity: 1.5,
                                                   ambientLightIntensity: 0.4)

        let params = try await adapter.buildRenderingParameters(for: makeRequest(renderQualitySettings: settings))

        XCTAssertEqual(params.material.isLightingOn, 1)
        XCTAssertEqual(params.material.shadowMode, VolumeShadowMode.soft.shaderValue)
        XCTAssertEqual(params.light, 1.5, accuracy: 1e-6)
        XCTAssertEqual(params.shade, 0.4, accuracy: 1e-6)
        XCTAssertEqual(params.scale, 2.0, accuracy: 1e-6)
    }

    func testShadowOffDisablesLightingAndShaderMode() async throws {
        try await adapter.send(.setWindow(min: -1024, max: 1023))
        let settings = VolumeRenderQualitySettings(shadowMode: .off)

        let uniforms = try await adapter.buildVolumeUniforms(for: makeRequest(renderQualitySettings: settings))

        XCTAssertEqual(uniforms.isLightingOn, 0)
        XCTAssertEqual(uniforms.shadowMode, VolumeShadowMode.off.shaderValue)
    }

    func testHardAndSoftShadowModesPopulateDistinctShaderModes() async throws {
        try await adapter.send(.setWindow(min: -1024, max: 1023))
        let hardUniforms = try await adapter.buildVolumeUniforms(
            for: makeRequest(renderQualitySettings: VolumeRenderQualitySettings(shadowMode: .hard))
        )
        let softUniforms = try await adapter.buildVolumeUniforms(
            for: makeRequest(renderQualitySettings: VolumeRenderQualitySettings(shadowMode: .soft))
        )

        XCTAssertEqual(hardUniforms.isLightingOn, 1)
        XCTAssertEqual(softUniforms.isLightingOn, 1)
        XCTAssertEqual(hardUniforms.shadowMode, VolumeShadowMode.hard.shaderValue)
        XCTAssertEqual(softUniforms.shadowMode, VolumeShadowMode.soft.shaderValue)
        XCTAssertNotEqual(hardUniforms.shadowMode, softUniforms.shadowMode)
    }

    private func makeRequest(renderQualitySettings: VolumeRenderQualitySettings = .default) -> VolumeRenderRequest {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [
                    VolumeTransferFunction.OpacityControlPoint(intensity: -1024, opacity: 0),
                    VolumeTransferFunction.OpacityControlPoint(intensity: 1023, opacity: 1)
                ],
                colourPoints: [
                    VolumeTransferFunction.ColourControlPoint(intensity: -1024,
                                                              colour: SIMD4<Float>(0, 0, 0, 1)),
                    VolumeTransferFunction.ColourControlPoint(intensity: 1023,
                                                              colour: SIMD4<Float>(1, 1, 1, 1))
                ]
            ),
            viewportSize: CGSize(width: 16, height: 16),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive,
            renderQualitySettings: renderQualitySettings
        )
    }
}

final class MetalVolumeRenderingAdapterParameterTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testVolumeRenderRequestClippingPopulatesShaderTrimAndPlaneParameters() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )
        try await adapter.send(.setWindow(min: dataset.intensityRange.lowerBound,
                                          max: dataset.intensityRange.upperBound))
        let crop = try VolumeCropBox(textureMin: SIMD3<Float>(0.1, 0.2, 0.3),
                                     textureMax: SIMD3<Float>(0.9, 0.8, 0.7))
        let plane = try VolumeClipPlane(textureCenteredNormal: SIMD3<Float>(0, 0, 1),
                                        offset: 0.25,
                                        dataset: dataset)
        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction.defaultGrayscale(for: dataset),
            viewportSize: CGSize(width: 16, height: 16),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0.5, 0.5, 2),
                target: SIMD3<Float>(repeating: 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive,
            clipping: try VolumeClippingState(cropBox: crop, clipPlanes: [plane])
        )

        let params = try await adapter.buildRenderingParameters(for: request)

        XCTAssertEqual(params.trimXMin, 0.1, accuracy: 1e-6)
        XCTAssertEqual(params.trimXMax, 0.9, accuracy: 1e-6)
        XCTAssertEqual(params.trimYMin, 0.2, accuracy: 1e-6)
        XCTAssertEqual(params.trimYMax, 0.8, accuracy: 1e-6)
        XCTAssertEqual(params.trimZMin, 0.3, accuracy: 1e-6)
        XCTAssertEqual(params.trimZMax, 0.7, accuracy: 1e-6)
        XCTAssertEqual(params.clipPlane0.x, 0, accuracy: 1e-6)
        XCTAssertEqual(params.clipPlane0.y, 0, accuracy: 1e-6)
        XCTAssertEqual(params.clipPlane0.z, 1, accuracy: 1e-6)
        XCTAssertEqual(params.clipPlane0.w, -0.25, accuracy: 1e-6)
        XCTAssertEqual(params.clipPlane1, .zero)
        XCTAssertEqual(params.clipPlane2, .zero)
    }

    func testCameraUniformsUsePhysicalVolumeGeometryForAnisotropicDataset() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 5, depth: 5),
            spacing: VolumeSpacing(x: 1, y: 1, z: 2),
            pixelFormat: .int16Signed
        )
        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction.defaultGrayscale(for: dataset),
            viewportSize: CGSize(width: 64, height: 64),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0.5, 0.5, 2.5),
                target: SIMD3<Float>(repeating: 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive
        )

        let camera = try await adapter.makeCameraUniforms(for: request,
                                                          viewportSize: (64, 64),
                                                          frameIndex: 7)

        XCTAssertEqual(camera.modelMatrix.columns.0.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(camera.modelMatrix.columns.1.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(camera.modelMatrix.columns.2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(camera.inverseModelMatrix.columns.0.x, 2.0, accuracy: 1e-6)
        XCTAssertEqual(camera.inverseModelMatrix.columns.1.y, 2.0, accuracy: 1e-6)
        XCTAssertEqual(camera.inverseModelMatrix.columns.2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(camera.cameraPositionLocal, SIMD3<Float>(0, 0, 2))
        XCTAssertEqual(camera.frameIndex, 7)
        XCTAssertTrue(camera.inverseViewProjectionMatrix.allFinite)
    }
}

private extension simd_float4x4 {
    var allFinite: Bool {
        for column in 0..<4 {
            for row in 0..<4 where !self[column][row].isFinite {
                return false
            }
        }
        return true
    }
}

// MARK: - resolveWindow priority (MetalVolumeRenderingAdapter+Dispatch.swift)

final class ResolveWindowTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testThrowsWhenNoWindowSourceIsAvailable() async {
        // dataset has no recommendedWindow, no extendedState.huWindow, no overrides.window
        let dataset = makeDataset(recommendedWindow: nil)
        await XCTAssertThrowsAsync(
            try await adapter.resolveWindow(for: dataset),
            expecting: MetalVolumeRenderingAdapter.AdapterError.windowNotSpecified
        )
    }

    func testUsesDatasetRecommendedWindowWhenNoOverride() async throws {
        let window: ClosedRange<Int32> = -500...1500
        let dataset = makeDataset(recommendedWindow: window)
        let resolved = try await adapter.resolveWindow(for: dataset)
        XCTAssertEqual(resolved, window)
    }

    func testOverridesWindowTakesPriorityOverDatasetRecommendedWindow() async throws {
        let overrideWindow: ClosedRange<Int32> = 0...4095
        await adapter.setWindowOverrideForTesting(overrideWindow)

        let datasetWindow: ClosedRange<Int32> = -1024...3071
        let dataset = makeDataset(recommendedWindow: datasetWindow)
        let resolved = try await adapter.resolveWindow(for: dataset)
        XCTAssertEqual(resolved, overrideWindow,
                       "overrides.window should take priority over dataset.recommendedWindow")
    }

    func testExtendedStateHuWindowTakesPriorityOverOverridesWindow() async throws {
        let huWindow: ClosedRange<Int32> = 100...200
        let overrideWindow: ClosedRange<Int32> = 0...4095
        await adapter.setWindowOverrideForTesting(overrideWindow)
        await adapter.setHuWindowForTesting(huWindow)

        let dataset = makeDataset(recommendedWindow: -1024...3071)
        let resolved = try await adapter.resolveWindow(for: dataset)
        XCTAssertEqual(resolved, huWindow,
                       "extendedState.huWindow should take highest priority")
    }

    func testOverridesWindowWorksWhenDatasetHasNoRecommendedWindow() async throws {
        let overrideWindow: ClosedRange<Int32> = 500...1000
        await adapter.setWindowOverrideForTesting(overrideWindow)

        let dataset = makeDataset(recommendedWindow: nil)
        let resolved = try await adapter.resolveWindow(for: dataset)
        XCTAssertEqual(resolved, overrideWindow)
    }

    private func makeDataset(recommendedWindow: ClosedRange<Int32>?) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: recommendedWindow
        )
    }
}

extension MetalVolumeRenderingAdapter {
    fileprivate func setWindowOverrideForTesting(_ window: ClosedRange<Int32>?) {
        overrides.window = window
    }

    fileprivate func setHuWindowForTesting(_ window: ClosedRange<Int32>?) {
        extendedState.huWindow = window
    }
}
