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
        _ = try await adapter.renderImage(using: request)
        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot, "lastSnapshot should be set after a successful render")
        XCTAssertEqual(snapshot?.window, window)
    }

    private func makeDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: -1024...3071
        )
    }

    private func makeRenderRequest() -> VolumeRenderRequest {
        let dataset = makeDataset()
        let transfer = VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: 4095, opacity: 1),
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: 4095, colour: SIMD4<Float>(1, 1, 1, 1)),
            ]
        )
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transfer,
            viewportSize: CGSize(width: 64, height: 64),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1.0 / 64.0,
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