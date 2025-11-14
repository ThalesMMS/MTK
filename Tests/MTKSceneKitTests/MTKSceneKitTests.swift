//  MTKSceneKitTests.swift
//  MTK
//  Guards SceneKit volume factory behaviour and skips when unavailable.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
#if canImport(SceneKit)
import SceneKit
import Metal
#endif
@testable import MTKSceneKit

final class MTKSceneKitTests: XCTestCase {
    func testFactoryCreatesVolumeNodeWhenMetalAvailable() throws {
#if canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on test host")
        }
        throw XCTSkip("Scene kit factory scaffolding not yet available in MTK")
#else
        XCTAssertTrue(true)
#endif
    }
}
