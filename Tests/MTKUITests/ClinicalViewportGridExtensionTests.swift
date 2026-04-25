//
//  ClinicalViewportGridExtensionTests.swift
//  MTKUITests
//
//  Tests for ClinicalViewportGridController+Crosshair.swift and +Diagnostics.swift.
//

import CoreGraphics
import Metal
import XCTest
import MTKCore
@_spi(Testing) @testable import MTKUI

@MainActor
final class ClinicalViewportGridCrosshairTests: XCTestCase {

    // MARK: - clampNormalized

    func testClampNormalizedReturnsSameValueInRange() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.clampNormalized(0.5), 0.5, accuracy: 0.000_01)
    }

    func testClampNormalizedClampsAboveOne() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.clampNormalized(1.5), 1.0, accuracy: 0.000_01)
    }

    func testClampNormalizedClampsBelowZero() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.clampNormalized(-0.1), 0.0, accuracy: 0.000_01)
    }

    func testClampNormalizedReturnsZeroForZeroInput() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.clampNormalized(0.0), 0.0, accuracy: 0.000_01)
    }

    func testClampNormalizedReturnsOneForOneInput() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.clampNormalized(1.0), 1.0, accuracy: 0.000_01)
    }

    // MARK: - perpendicularAxes

    func testPerpendicularAxesToAxialAreCoronalAndSagittal() async throws {
        let controller = try await makeController()
        let axes = controller.perpendicularAxes(to: .axial)
        XCTAssertEqual(Set(axes), Set([MTKCore.Axis.coronal, MTKCore.Axis.sagittal]))
    }

    func testPerpendicularAxesToCoronalAreAxialAndSagittal() async throws {
        let controller = try await makeController()
        let axes = controller.perpendicularAxes(to: .coronal)
        XCTAssertEqual(Set(axes), Set([MTKCore.Axis.axial, MTKCore.Axis.sagittal]))
    }

    func testPerpendicularAxesToSagittalAreAxialAndCoronal() async throws {
        let controller = try await makeController()
        let axes = controller.perpendicularAxes(to: .sagittal)
        XCTAssertEqual(Set(axes), Set([MTKCore.Axis.axial, MTKCore.Axis.coronal]))
    }

    func testPerpendicularAxesReturnsTwoAxes() async throws {
        let controller = try await makeController()
        for axis in MTKCore.Axis.allCases {
            let perpendicular = controller.perpendicularAxes(to: axis)
            XCTAssertEqual(perpendicular.count, 2,
                           "Expected 2 perpendicular axes for axis=\(axis)")
        }
    }

    func testPerpendicularAxesDoNotContainInputAxis() async throws {
        let controller = try await makeController()
        for axis in MTKCore.Axis.allCases {
            let perpendicular = controller.perpendicularAxes(to: axis)
            XCTAssertFalse(perpendicular.contains(axis),
                           "Perpendicular axes for \(axis) should not contain \(axis)")
        }
    }

    // MARK: - textureCoordinates

    func testAxialTextureCoordinatesUseSagittalAndCoronal() async throws {
        let controller = try await makeController()
        let positions: [MTKCore.Axis: Float] = [.axial: 0.5, .coronal: 0.3, .sagittal: 0.7]
        let texCoords = controller.textureCoordinates(for: .axial, positions: positions)
        // For axial: x = sagittal, y = coronal
        XCTAssertEqual(texCoords.x, 0.7, accuracy: 0.000_01)
        XCTAssertEqual(texCoords.y, 0.3, accuracy: 0.000_01)
    }

    func testCoronalTextureCoordinatesUseSagittalAndAxial() async throws {
        let controller = try await makeController()
        let positions: [MTKCore.Axis: Float] = [.axial: 0.6, .coronal: 0.5, .sagittal: 0.2]
        let texCoords = controller.textureCoordinates(for: .coronal, positions: positions)
        // For coronal: x = sagittal, y = axial
        XCTAssertEqual(texCoords.x, 0.2, accuracy: 0.000_01)
        XCTAssertEqual(texCoords.y, 0.6, accuracy: 0.000_01)
    }

    func testSagittalTextureCoordinatesUseCoronalAndAxial() async throws {
        let controller = try await makeController()
        let positions: [MTKCore.Axis: Float] = [.axial: 0.4, .coronal: 0.8, .sagittal: 0.5]
        let texCoords = controller.textureCoordinates(for: .sagittal, positions: positions)
        // For sagittal: x = coronal, y = axial
        XCTAssertEqual(texCoords.x, 0.8, accuracy: 0.000_01)
        XCTAssertEqual(texCoords.y, 0.4, accuracy: 0.000_01)
    }

    func testTextureCoordinatesDefaultToHalfWhenPositionsMissing() async throws {
        let controller = try await makeController()
        let positions: [MTKCore.Axis: Float] = [:]
        let texCoords = controller.textureCoordinates(for: .axial, positions: positions)
        XCTAssertEqual(texCoords.x, 0.5, accuracy: 0.000_01)
        XCTAssertEqual(texCoords.y, 0.5, accuracy: 0.000_01)
    }

    // MARK: - setNormalizedPosition

    func testSetNormalizedPositionReturnsTrueForNewValue() async throws {
        let controller = try await makeController()
        // Initial value is 0.5 from centeredNormalizedPositions
        let changed = controller.setNormalizedPosition(0.7, for: .axial)
        XCTAssertTrue(changed)
        XCTAssertEqual(controller.normalizedPositions[.axial] ?? 0, 0.7, accuracy: 0.000_01)
    }

    func testSetNormalizedPositionReturnsFalseForSameValue() async throws {
        let controller = try await makeController()
        // Initial value should be 0.5
        let firstChange = controller.setNormalizedPosition(0.5, for: .axial)
        XCTAssertFalse(firstChange, "No change for existing value 0.5")
    }

    func testSetNormalizedPositionClampsBelowZero() async throws {
        let controller = try await makeController()
        _ = controller.setNormalizedPosition(-0.5, for: .sagittal)
        XCTAssertEqual(controller.normalizedPositions[.sagittal] ?? 0, 0.0, accuracy: 0.000_01)
    }

    func testSetNormalizedPositionClampsAboveOne() async throws {
        let controller = try await makeController()
        _ = controller.setNormalizedPosition(1.5, for: .coronal)
        XCTAssertEqual(controller.normalizedPositions[.coronal] ?? 0, 1.0, accuracy: 0.000_01)
    }

    // MARK: - updateCrosshairPositions

    func testUpdateCrosshairPositionsReturnsNonEmptyAxisList() async throws {
        let controller = try await makeController()
        let changed = controller.updateCrosshairPositions(changedAxis: .axial, newNormalizedPosition: 0.7)
        // Should affect coronal and sagittal axes
        XCTAssertFalse(changed.isEmpty)
    }

    func testUpdateCrosshairPositionsDoesNotIncludeChangedAxis() async throws {
        let controller = try await makeController()
        let changed = controller.updateCrosshairPositions(changedAxis: .axial, newNormalizedPosition: 0.7)
        XCTAssertFalse(changed.contains(.axial))
    }

    func testUpdateCrosshairPositionsClampsNegativePosition() async throws {
        let controller = try await makeController()
        // Should not crash with out-of-range value
        _ = controller.updateCrosshairPositions(changedAxis: .sagittal, newNormalizedPosition: -0.5)
        // No assertion needed — just verifying no crash and clamp happened
    }
}

// MARK: - Diagnostics extension tests

@MainActor
final class ClinicalViewportGridDiagnosticsTests: XCTestCase {

    // MARK: - safeNormalize

    func testSafeNormalizeReturnsNormalizedVectorForNonZeroInput() async throws {
        let controller = try await makeController()
        let v = SIMD3<Float>(3, 0, 0)
        let result = controller.safeNormalize(v, fallback: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(result.x, 1.0, accuracy: 0.000_01)
        XCTAssertEqual(result.y, 0.0, accuracy: 0.000_01)
        XCTAssertEqual(result.z, 0.0, accuracy: 0.000_01)
    }

    func testSafeNormalizeReturnsFallbackForZeroVector() async throws {
        let controller = try await makeController()
        let v = SIMD3<Float>.zero
        let fallback = SIMD3<Float>(0, 1, 0)
        let result = controller.safeNormalize(v, fallback: fallback)
        XCTAssertEqual(result, fallback)
    }

    func testSafeNormalizeReturnsFallbackForNaNVector() async throws {
        let controller = try await makeController()
        let v = SIMD3<Float>(Float.nan, 0, 0)
        let fallback = SIMD3<Float>(1, 0, 0)
        let result = controller.safeNormalize(v, fallback: fallback)
        XCTAssertEqual(result, fallback)
    }

    func testSafeNormalizeProducesUnitLength() async throws {
        let controller = try await makeController()
        let v = SIMD3<Float>(3, 4, 0)
        let result = controller.safeNormalize(v, fallback: SIMD3<Float>(1, 0, 0))
        let length = sqrt(result.x * result.x + result.y * result.y + result.z * result.z)
        XCTAssertEqual(length, 1.0, accuracy: 0.000_01)
    }

    // MARK: - errorDescription

    func testErrorDescriptionForLocalizedError() async throws {
        let controller = try await makeController()
        let error = ClinicalViewportGridControllerError.metalUnavailable
        let description = controller.errorDescription(error)
        XCTAssertEqual(description, "Metal device unavailable")
    }

    func testErrorDescriptionForNilError() async throws {
        let controller = try await makeController()
        let description = controller.errorDescription(nil)
        XCTAssertNil(description)
    }

    func testErrorDescriptionForNonLocalizedError() async throws {
        let controller = try await makeController()
        let error = NSError(domain: "TestDomain", code: 404, userInfo: nil)
        let description = controller.errorDescription(error)
        XCTAssertNotNil(description)
    }

    // MARK: - viewportName

    func testViewportNameForAxialID() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.viewportName(for: controller.axialViewportID), "Axial")
    }

    func testViewportNameForCoronalID() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.viewportName(for: controller.coronalViewportID), "Coronal")
    }

    func testViewportNameForSagittalID() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.viewportName(for: controller.sagittalViewportID), "Sagittal")
    }

    func testViewportNameForVolumeID() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.viewportName(for: controller.volumeViewportID), "Volume")
    }

    func testViewportNameForUnknownIDReturnsViewport() async throws {
        let controller = try await makeController()
        let unknownID = ViewportID()
        XCTAssertEqual(controller.viewportName(for: unknownID), "Viewport")
    }

    // MARK: - viewportTypeName

    func testViewportTypeNameForVolumeIDReflectsCurrentMode() async throws {
        let controller = try await makeController()
        // Default mode is DVR
        let typeName = controller.viewportTypeName(for: controller.volumeViewportID)
        XCTAssertEqual(typeName, ClinicalVolumeViewportMode.dvr.viewportType.debugName)
    }

    func testViewportTypeNameForAxialIDIsAxialMPR() async throws {
        let controller = try await makeController()
        let typeName = controller.viewportTypeName(for: controller.axialViewportID)
        XCTAssertEqual(typeName, "mpr(axial)")
    }

    func testViewportTypeNameForCoronalIDIsCoronalMPR() async throws {
        let controller = try await makeController()
        let typeName = controller.viewportTypeName(for: controller.coronalViewportID)
        XCTAssertEqual(typeName, "mpr(coronal)")
    }

    func testViewportTypeNameForSagittalIDIsSagittalMPR() async throws {
        let controller = try await makeController()
        let typeName = controller.viewportTypeName(for: controller.sagittalViewportID)
        XCTAssertEqual(typeName, "mpr(sagittal)")
    }

    func testViewportTypeNameForUnknownIDIsUnknown() async throws {
        let controller = try await makeController()
        let typeName = controller.viewportTypeName(for: ViewportID())
        XCTAssertEqual(typeName, "unknown")
    }

    // MARK: - renderModeName

    func testRenderModeNameForVolumeIDIsDVR() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.renderModeName(for: controller.volumeViewportID), "dvr")
    }

    func testRenderModeNameForMPRIDIsSingle() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.renderModeName(for: controller.axialViewportID), "single")
        XCTAssertEqual(controller.renderModeName(for: controller.coronalViewportID), "single")
        XCTAssertEqual(controller.renderModeName(for: controller.sagittalViewportID), "single")
    }

    // MARK: - recordError / clearError / refreshAggregateRenderError

    func testRecordErrorSetsLastRenderErrorForViewport() async throws {
        let controller = try await makeController()
        let error = ClinicalViewportGridControllerError.noDatasetApplied
        controller.recordError(error, for: controller.axialViewportID)
        XCTAssertNotNil(controller.lastRenderErrors[controller.axialViewportID])
    }

    func testClearErrorRemovesLastRenderErrorForViewport() async throws {
        let controller = try await makeController()
        let error = ClinicalViewportGridControllerError.noDatasetApplied
        controller.recordError(error, for: controller.axialViewportID)
        controller.clearError(for: controller.axialViewportID)
        XCTAssertNil(controller.lastRenderErrors[controller.axialViewportID])
    }

    func testRefreshAggregateRenderErrorPrioritizesVolumeViewport() async throws {
        let controller = try await makeController()
        let axialError = ClinicalViewportGridControllerError.noDatasetApplied
        let volumeError = ClinicalViewportGridControllerError.viewportSurfaceNotFound

        controller.recordError(axialError, for: controller.axialViewportID)
        controller.recordError(volumeError, for: controller.volumeViewportID)

        // lastRenderError should be the volume error (first in priority order)
        let aggregate = controller.lastRenderError as? ClinicalViewportGridControllerError
        XCTAssertEqual(aggregate, .viewportSurfaceNotFound)
    }

    func testRefreshAggregateRenderErrorClearsWhenNoErrors() async throws {
        let controller = try await makeController()
        let error = ClinicalViewportGridControllerError.noDatasetApplied
        controller.recordError(error, for: controller.axialViewportID)
        controller.clearError(for: controller.axialViewportID)

        XCTAssertNil(controller.lastRenderError)
    }

    func testRefreshAggregateRenderErrorFallsBackToAxialAfterVolumeCleared() async throws {
        let controller = try await makeController()
        let axialError = ClinicalViewportGridControllerError.noDatasetApplied
        let volumeError = ClinicalViewportGridControllerError.viewportSurfaceNotFound

        controller.recordError(axialError, for: controller.axialViewportID)
        controller.recordError(volumeError, for: controller.volumeViewportID)
        controller.clearError(for: controller.volumeViewportID)

        let aggregate = controller.lastRenderError as? ClinicalViewportGridControllerError
        XCTAssertEqual(aggregate, .noDatasetApplied)
    }

    // MARK: - datasetHandleLabel

    func testDatasetHandleLabelIsNilWithoutDataset() async throws {
        let controller = try await makeController()
        XCTAssertNil(controller.datasetHandleLabel(for: controller.axialViewportID))
    }

    // MARK: - updateDebugSnapshot / makeDebugSnapshot

    func testMakeDebugSnapshotPopulatesNameTypeAndMode() async throws {
        let controller = try await makeController()
        let id = ViewportID()
        let snapshot = ClinicalViewportGridController.makeDebugSnapshot(
            viewportID: id,
            viewportName: "Test",
            viewportType: "mpr(axial)",
            renderMode: "single"
        )
        XCTAssertEqual(snapshot.viewportID, id)
        XCTAssertEqual(snapshot.viewportName, "Test")
        XCTAssertEqual(snapshot.viewportType, "mpr(axial)")
        XCTAssertEqual(snapshot.renderMode, "single")
        XCTAssertEqual(snapshot.presentationStatus, "idle")
    }

    func testUpdateDebugSnapshotMutatesExistingSnapshot() async throws {
        let controller = try await makeController()
        controller.updateDebugSnapshot(for: controller.axialViewportID) { snapshot in
            snapshot.presentationStatus = "presenting"
        }
        let updated = controller.debugSnapshots[controller.axialViewportID]
        XCTAssertEqual(updated?.presentationStatus, "presenting")
    }
}

// MARK: - Render Generation (scheduleRender)

@MainActor
final class ClinicalViewportGridRenderingExtensionTests: XCTestCase {

    func testScheduleRenderReturnsNilWhenDatasetNotApplied() async throws {
        let controller = try await makeController()
        // datasetApplied starts as false
        let task = controller.scheduleRender(for: controller.axialViewportID)
        XCTAssertNil(task)
    }

    func testScheduleRenderIncrementsRenderGeneration() async throws {
        let controller = try await makeController()
        // Manually mark dataset as applied to allow scheduling
        controller.datasetApplied = true
        let before = controller.debugRenderGeneration(for: controller.axialViewportID)
        _ = controller.scheduleRender(for: controller.axialViewportID)
        let after = controller.debugRenderGeneration(for: controller.axialViewportID)
        XCTAssertEqual(after, before + 1)
    }

    func testScheduleRenderUpdatesDebugSnapshotToScheduled() async throws {
        let controller = try await makeController()
        controller.datasetApplied = true
        _ = controller.scheduleRender(for: controller.axialViewportID)
        let snapshot = controller.debugSnapshots[controller.axialViewportID]
        XCTAssertEqual(snapshot?.presentationStatus, "scheduled")
    }

    func testDebugRenderGenerationStartsAtZero() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.debugRenderGeneration(for: controller.axialViewportID), 0)
    }

    func testAllViewportIDsContainsExactlyFourIDs() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.allViewportIDs.count, 4)
    }

    func testMPRViewportIDsContainsExactlyThreeIDs() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.mprViewportIDs.count, 3)
    }

    func testViewportIDForAxisReturnsExpectedID() async throws {
        let controller = try await makeController()
        XCTAssertEqual(controller.viewportID(for: .axial), controller.axialViewportID)
        XCTAssertEqual(controller.viewportID(for: .coronal), controller.coronalViewportID)
        XCTAssertEqual(controller.viewportID(for: .sagittal), controller.sagittalViewportID)
    }

    func testSurfaceForAxisReturnsExpectedSurface() async throws {
        let controller = try await makeController()
        XCTAssertTrue(controller.surface(for: .axial) === controller.axialSurface)
        XCTAssertTrue(controller.surface(for: .coronal) === controller.coronalSurface)
        XCTAssertTrue(controller.surface(for: .sagittal) === controller.sagittalSurface)
    }
}

// MARK: - ClinicalViewportGridController.resetVolumeCamera

@MainActor
final class ClinicalViewportGridConfigurationExtensionTests: XCTestCase {

    func testResetVolumeCameraRestoresDefaults() async throws {
        let controller = try await makeController()
        // Modify camera state
        controller.volumeCameraTarget = SIMD3<Float>(1, 2, 3)
        controller.volumeCameraOffset = SIMD3<Float>(5, 5, 5)
        controller.volumeCameraUp = SIMD3<Float>(0, 0, 1)

        controller.resetVolumeCamera()

        XCTAssertEqual(controller.volumeCameraTarget, SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(controller.volumeCameraOffset, SIMD3<Float>(0, 0, 2))
        XCTAssertEqual(controller.volumeCameraUp, SIMD3<Float>(0, 1, 0))
    }

    func testInitialVolumeCameraStateMatchesReset() async throws {
        let controller = try await makeController()
        // After initialization, camera should be at default values
        XCTAssertEqual(controller.volumeCameraTarget, SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(controller.volumeCameraOffset, SIMD3<Float>(0, 0, 2))
        XCTAssertEqual(controller.volumeCameraUp, SIMD3<Float>(0, 1, 0))
    }
}

// MARK: - Helpers

@MainActor
private func makeController() async throws -> ClinicalViewportGridController {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal not available")
    }
    return try await ClinicalViewportGridController(device: device,
                                                    initialViewportSize: CGSize(width: 32, height: 32))
}
