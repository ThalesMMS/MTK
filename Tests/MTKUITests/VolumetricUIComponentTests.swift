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

#if canImport(SwiftUI)
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
