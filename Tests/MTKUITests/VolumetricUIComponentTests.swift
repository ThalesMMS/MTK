//  VolumetricUIComponentTests.swift
//  MTK
//  GPU-free smoke tests for new UI surface APIs.
//  Thales Matheus Mendonça Santos — October 2025

import Metal
import XCTest
@testable import MTKUI

@MainActor
final class VolumetricUIComponentTests: XCTestCase {
    func testStubSceneControllerPublishesState() async throws {
        throw XCTSkip("Stub controller is no longer used on macOS. Real controller requires GPU resources.")
    }

    func testVolumeGestureConfigurationIsEnabledReflectsCapabilities() {
        let disabled = VolumeGestureConfiguration(allowsTranslation: false,
                                                  allowsZoom: false,
                                                  allowsRotation: false,
                                                  allowsWindowLevel: false,
                                                  allowsSlabThickness: false)
        XCTAssertFalse(disabled.isEnabled)

        var enabled = disabled
        enabled.allowsZoom = true
        XCTAssertTrue(enabled.isEnabled)
    }

#if canImport(SwiftUI)
    func testDefaultVolumetricUIStyleUsesConfiguredCrosshairLineWidth() {
        let style = DefaultVolumetricUIStyle(crosshairLineWidth: 3)

        XCTAssertEqual(style.lineWidth, 3)
    }

    func testVolumeViewportOverlayConfigurationSupportsCustomOrientationLabels() {
        let defaultLabels = VolumeViewportOverlayConfiguration.default.orientationLabels
        XCTAssertEqual(defaultLabels, MPRLabels(leading: "L", trailing: "R", top: "A", bottom: "P"))

        let localizedLabels = MPRLabels(leading: "Esq", trailing: "Dir", top: "Ant", bottom: "Post")
        let configuration = VolumeViewportOverlayConfiguration(orientationLabels: localizedLabels)

        XCTAssertEqual(configuration.orientationLabels, localizedLabels)
    }

    func testGestureOverlayCompiles() throws {
#if os(iOS)
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")
        let controller = try VolumeViewportController()
        _ = VolumetricGestureOverlay(controller: controller)
#else
        throw XCTSkip("VolumetricGestureOverlay is only available on iOS builds")
#endif
    }
#endif
}
