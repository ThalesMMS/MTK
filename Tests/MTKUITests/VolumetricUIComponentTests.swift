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
#if os(macOS)
        let controller = VolumetricSceneController()
        XCTAssertEqual(Double(controller.sliceState.normalizedPosition), 0.5, accuracy: 0.001)
        await controller.setMprPlane(axis: .z, normalized: 0.75)
        XCTAssertEqual(Double(controller.sliceState.normalizedPosition), 0.75, accuracy: 0.001)
        let mapping = VolumeCubeMaterial.makeHuWindowMapping(
            minHU: -500,
            maxHU: 500,
            datasetRange: -1024...3071,
            transferDomain: nil
        )
        await controller.setHuWindow(mapping)
        XCTAssertEqual(controller.windowLevelState.window, 1000, accuracy: 0.1)
        XCTAssertEqual(controller.windowLevelState.level, 0, accuracy: 0.1)
#else
        throw XCTSkip("State publishing tested on macOS host targets where the stub controller is available")
#endif
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
