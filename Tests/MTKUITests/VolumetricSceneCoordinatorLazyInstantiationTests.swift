//  VolumetricSceneCoordinatorLazyInstantiationTests.swift
//  MTK
//  Validates lazy coordinator controller creation for MPR-only layouts.
//  Thales Matheus Mendonca Santos - April 2026

import XCTest
@_spi(Testing) @testable import MTKUI
#if canImport(Metal)
import Metal
#endif

@MainActor
final class VolumetricSceneCoordinatorLazyInstantiationTests: XCTestCase {
    override func tearDown() async throws {
        VolumetricSceneCoordinator.shared.reset()
        try await super.tearDown()
    }

    func testTriplanarOnlyControllersDoNotInstantiateVolumeController() throws {
        try requireMetalDevice()

        let coordinator = VolumetricSceneCoordinator.shared
        coordinator.reset()

        _ = try coordinator.controller(for: .z)
        _ = try coordinator.controller(for: .y)
        _ = try coordinator.controller(for: .x)

        XCTAssertEqual(
            coordinator.debugControllerSurfaceIdentifiers,
            ["mpr.x", "mpr.y", "mpr.z"],
            "Tri-planar-only access should create only the three MPR controllers."
        )
        XCTAssertFalse(
            coordinator.debugControllerSurfaceIdentifiers.contains("volume"),
            "The volume controller should remain uninstantiated until coordinator.controller is accessed."
        )
    }

    func testVolumeControllerIsCreatedOnlyWhenPrimaryControllerIsRequested() throws {
        try requireMetalDevice()

        let coordinator = VolumetricSceneCoordinator.shared
        coordinator.reset()

        _ = try coordinator.controller(for: .z)
        XCTAssertEqual(coordinator.debugControllerSurfaceIdentifiers, ["mpr.z"])

        _ = try XCTUnwrap(coordinator.controller)
        XCTAssertEqual(
            coordinator.debugControllerSurfaceIdentifiers,
            ["mpr.z", "volume"]
        )
    }

    private func requireMetalDevice() throws {
#if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }
#else
        throw XCTSkip("Metal not available")
#endif
    }
}
