//  VolumeViewportCoordinatorLazyInstantiationTests.swift
//  MTK
//  Validates lazy coordinator controller creation for MPR-only layouts.
//  Thales Matheus Mendonca Santos - April 2026

import XCTest
import MTKCore
@_spi(Testing) @testable import MTKUI
#if canImport(Metal)
import Metal
#endif

@MainActor
final class VolumeViewportCoordinatorLazyInstantiationTests: XCTestCase {
    private struct MPRVolumeTextureIdentifierTimeout: LocalizedError {
        let expectedCount: Int
        let actualCount: Int

        var errorDescription: String? {
            "Timed out waiting for all MPR controllers to publish shared volume texture identifiers; got \(actualCount) of \(expectedCount)."
        }
    }

    override func tearDown() async throws {
        VolumeViewportCoordinator.shared.reset()
        try await super.tearDown()
    }

    func testTriplanarOnlyControllersDoNotInstantiateVolumeController() throws {
        try requireMetalDevice()

        let coordinator = VolumeViewportCoordinator.shared
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

        let coordinator = VolumeViewportCoordinator.shared
        coordinator.reset()

        _ = try coordinator.controller(for: .z)
        XCTAssertEqual(coordinator.debugControllerSurfaceIdentifiers, ["mpr.z"])

        _ = try XCTUnwrap(coordinator.controller)
        XCTAssertEqual(
            coordinator.debugControllerSurfaceIdentifiers,
            ["mpr.z", "volume"]
        )
    }

    func testMPRControllersShareVolumeTextureCache() async throws {
        try requireMetalDevice()

        let coordinator = VolumeViewportCoordinator.shared
        coordinator.reset()

        let sagittal = try coordinator.controller(for: .x)
        let coronal = try coordinator.controller(for: .y)
        let axial = try coordinator.controller(for: .z)

        coordinator.apply(dataset: makeSyntheticDataset())
        coordinator.configureMPRDisplay(axis: .x)
        coordinator.configureMPRDisplay(axis: .y)
        coordinator.configureMPRDisplay(axis: .z)

        let textureIDs = try await waitForMPRVolumeTextureIdentifiers([sagittal, coronal, axial])
        XCTAssertEqual(textureIDs.count, 3)
        XCTAssertEqual(Set(textureIDs).count, 1)
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

    private func makeSyntheticDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        var voxels = [Int16]()
        voxels.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    voxels.append(Int16(-1_000 + x + y * 10 + z * 100))
                }
            }
        }
        return VolumeDataset(
            data: voxels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: -1_000...(-223),
            recommendedWindow: -1_000...(-223)
        )
    }

    private func waitForMPRVolumeTextureIdentifiers(_ controllers: [VolumeViewportController]) async throws -> [ObjectIdentifier] {
        for _ in 0..<80 {
            let identifiers = controllers.compactMap { $0.debugCachedMPRVolumeTextureIdentifier }
            if identifiers.count == controllers.count {
                return identifiers
            }
            for controller in controllers {
                if let error = controller.lastRenderError {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let identifiers = controllers.compactMap { $0.debugCachedMPRVolumeTextureIdentifier }
        throw MPRVolumeTextureIdentifierTimeout(expectedCount: controllers.count,
                                                actualCount: identifiers.count)
    }
}
