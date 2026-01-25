//  VolumetricUIComponentTests.swift
//  MTK
//  GPU-free smoke tests for new UI surface APIs.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
@testable import MTKUI
import MTKSceneKit

@MainActor
final class VolumetricUIComponentTests: XCTestCase {
    func testStubSceneControllerPublishesState() async throws {
        throw XCTSkip("Stub controller is no longer used on macOS. Real controller requires GPU resources.")
    }

#if canImport(SwiftUI)
    func testGestureOverlayCompiles() throws {
#if os(iOS)
        let controller = try VolumetricSceneController()
        _ = VolumetricGestureOverlay(controller: controller)
#else
        throw XCTSkip("VolumetricGestureOverlay is only available on iOS builds")
#endif
    }
#endif
}
