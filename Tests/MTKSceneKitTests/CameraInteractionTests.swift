//  CameraInteractionTests.swift
//  MTK
//  Exercises the camera controller store contracts.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
@testable import MTKSceneKit

final class CameraInteractionTests: XCTestCase {
    func testStoreRetainsControllersWeakly() {
        let store = VolumeCameraControllerStore()
        class Dummy: VolumeCameraControlling {
            func orbit(by delta: SIMD2<Float>) {}
            func pan(by delta: SIMD2<Float>) {}
            func zoom(by factor: Float) {}
        }

        let key = NSObject()
        let controller = Dummy()
        store.register(key: key, controller: controller)
        XCTAssertNotNil(store.controller(for: key))
        store.remove(key: key)
        XCTAssertNil(store.controller(for: key))
    }
}
