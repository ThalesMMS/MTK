//
//  ClinicalViewportGridTypesTests.swift
//  MTKUITests
//
//  Tests for ClinicalViewportGridTypes.swift: pure value types, enums, and extensions.
//

import CoreGraphics
import XCTest
import MTKCore
@testable import MTKUI

// MARK: - WindowLevelShift range extension

final class WindowLevelShiftRangeExtensionTests: XCTestCase {

    /// Round-trip: range -> WindowLevelShift -> range should be identity.
    func testRangeInitAndRangeRoundtrip() {
        let range: ClosedRange<Int32> = (-100)...300
        let shift = WindowLevelShift(range: range)
        XCTAssertEqual(shift.range, range)
    }

    func testRangeInitComputesWindowAsUpperMinusLower() {
        let lower: Int32 = 0
        let upper: Int32 = 400
        let shift = WindowLevelShift(range: lower...upper)
        XCTAssertEqual(shift.window, Double(upper - lower), accuracy: 0.001)
    }

    func testRangeInitComputesLevelAsMidpoint() {
        let lower: Int32 = -100
        let upper: Int32 = 300
        let shift = WindowLevelShift(range: lower...upper)
        // level = (lower + upper) / 2 = 100
        XCTAssertEqual(shift.level, Double(lower + upper) / 2, accuracy: 0.001)
    }

    func testRangePropertyProducesOrderedRange() {
        let shift = WindowLevelShift(window: 200, level: 40)
        let range = shift.range
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
    }

    func testSymmetricRangeAroundZero() {
        let range: ClosedRange<Int32> = (-200)...200
        let shift = WindowLevelShift(range: range)
        XCTAssertEqual(shift.level, 0, accuracy: 0.001)
        XCTAssertEqual(shift.window, 400, accuracy: 0.001)
        XCTAssertEqual(shift.range, range)
    }

    func testZeroWidthRangeEnforcesMinimumWindowOfOne() {
        // When lowerBound == upperBound, window should be max(upper - lower, 1) = 1
        let range: ClosedRange<Int32> = 100...100
        let shift = WindowLevelShift(range: range)
        XCTAssertEqual(shift.window, 1, accuracy: 0.001)
        XCTAssertEqual(shift.level, 100, accuracy: 0.001)
    }

    func testLargePositiveRange() {
        let range: ClosedRange<Int32> = 0...3071
        let shift = WindowLevelShift(range: range)
        XCTAssertEqual(shift.window, 3071, accuracy: 0.001)
        XCTAssertEqual(shift.level, 1535.5, accuracy: 0.001)
    }

    func testNegativeOnlyRange() {
        let range: ClosedRange<Int32> = (-1024)...(-500)
        let shift = WindowLevelShift(range: range)
        XCTAssertEqual(shift.window, 524, accuracy: 0.001)
        XCTAssertEqual(shift.level, -762, accuracy: 0.001)
        XCTAssertEqual(shift.range, range)
    }

    func testRangePropertyClampsValuesOutsideInt32Bounds() {
        let shift = WindowLevelShift(window: Double(Int32.max) * 4,
                                     level: 0)
        XCTAssertEqual(shift.range, Int32.min...Int32.max)
    }
}

// MARK: - ClinicalVolumeViewportMode

final class ClinicalVolumeViewportModeTests: XCTestCase {

    func testDVRModeHasVolume3DViewportType() {
        XCTAssertEqual(ClinicalVolumeViewportMode.dvr.viewportType, .volume3D)
    }

    func testMIPModeHasProjectionMIPViewportType() {
        XCTAssertEqual(ClinicalVolumeViewportMode.mip.viewportType, .projection(mode: .mip))
    }

    func testMinIPModeHasProjectionMinIPViewportType() {
        XCTAssertEqual(ClinicalVolumeViewportMode.minip.viewportType, .projection(mode: .minip))
    }

    func testAIPModeHasProjectionAIPViewportType() {
        XCTAssertEqual(ClinicalVolumeViewportMode.aip.viewportType, .projection(mode: .aip))
    }

    func testDVRDisplayName() {
        XCTAssertEqual(ClinicalVolumeViewportMode.dvr.displayName, "3D")
    }

    func testMIPDisplayName() {
        XCTAssertEqual(ClinicalVolumeViewportMode.mip.displayName, "MIP")
    }

    func testMinIPDisplayName() {
        XCTAssertEqual(ClinicalVolumeViewportMode.minip.displayName, "MinIP")
    }

    func testAIPDisplayName() {
        XCTAssertEqual(ClinicalVolumeViewportMode.aip.displayName, "AIP")
    }

    func testDVRCompositing() {
        XCTAssertEqual(ClinicalVolumeViewportMode.dvr.compositing, .frontToBack)
    }

    func testMIPCompositing() {
        XCTAssertEqual(ClinicalVolumeViewportMode.mip.compositing, .maximumIntensity)
    }

    func testMinIPCompositing() {
        XCTAssertEqual(ClinicalVolumeViewportMode.minip.compositing, .minimumIntensity)
    }

    func testAIPCompositing() {
        XCTAssertEqual(ClinicalVolumeViewportMode.aip.compositing, .averageIntensity)
    }

    func testCaseIterableContainsAllFourCases() {
        let cases = ClinicalVolumeViewportMode.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.dvr))
        XCTAssertTrue(cases.contains(.mip))
        XCTAssertTrue(cases.contains(.minip))
        XCTAssertTrue(cases.contains(.aip))
    }

    func testRawValueMatchesCaseName() {
        XCTAssertEqual(ClinicalVolumeViewportMode.dvr.rawValue, "dvr")
        XCTAssertEqual(ClinicalVolumeViewportMode.mip.rawValue, "mip")
        XCTAssertEqual(ClinicalVolumeViewportMode.minip.rawValue, "minip")
        XCTAssertEqual(ClinicalVolumeViewportMode.aip.rawValue, "aip")
    }
}

// MARK: - ClinicalViewportTimingSnapshot

final class ClinicalViewportTimingSnapshotTests: XCTestCase {

    func testDefaultInitializationHasNilFields() {
        let snapshot = ClinicalViewportTimingSnapshot()
        XCTAssertNil(snapshot.renderTime)
        XCTAssertNil(snapshot.presentationTime)
        XCTAssertNil(snapshot.uploadTime)
    }

    func testInitializationWithAllFields() {
        let render: CFAbsoluteTime = 1000
        let presentation: CFAbsoluteTime = 2000
        let upload: CFAbsoluteTime = 500

        let snapshot = ClinicalViewportTimingSnapshot(renderTime: render,
                                                      presentationTime: presentation,
                                                      uploadTime: upload)

        XCTAssertEqual(snapshot.renderTime, render)
        XCTAssertEqual(snapshot.presentationTime, presentation)
        XCTAssertEqual(snapshot.uploadTime, upload)
    }

    func testTwoIdenticalSnapshotsAreEqual() {
        let snap1 = ClinicalViewportTimingSnapshot(renderTime: 100, presentationTime: 200, uploadTime: 50)
        let snap2 = ClinicalViewportTimingSnapshot(renderTime: 100, presentationTime: 200, uploadTime: 50)
        XCTAssertEqual(snap1, snap2)
    }

    func testSnapshotsWithDifferentTimesAreNotEqual() {
        let snap1 = ClinicalViewportTimingSnapshot(renderTime: 100)
        let snap2 = ClinicalViewportTimingSnapshot(renderTime: 200)
        XCTAssertNotEqual(snap1, snap2)
    }

    func testPartialInitializationOnlyRenderTime() {
        let snapshot = ClinicalViewportTimingSnapshot(renderTime: 42.5)
        XCTAssertEqual(snapshot.renderTime, 42.5)
        XCTAssertNil(snapshot.presentationTime)
        XCTAssertNil(snapshot.uploadTime)
    }
}

// MARK: - ClinicalSlabConfiguration

final class ClinicalSlabConfigurationTests: XCTestCase {

    func testDefaultInitializationUsesThicknessThree() {
        let config = ClinicalSlabConfiguration()
        XCTAssertEqual(config.thickness, 3)
    }

    func testOddThicknessIsUnchanged() {
        let config = ClinicalSlabConfiguration(thickness: 5)
        XCTAssertEqual(config.thickness, 5)
    }

    func testEvenThicknessIsSnappedToNextOdd() {
        let config = ClinicalSlabConfiguration(thickness: 4)
        XCTAssertEqual(config.thickness, 5)
    }

    func testEvenThicknessTwo() {
        let config = ClinicalSlabConfiguration(thickness: 2)
        XCTAssertEqual(config.thickness, 3)
    }

    func testThicknessOneStaysOne() {
        let config = ClinicalSlabConfiguration(thickness: 1)
        XCTAssertEqual(config.thickness, 1)
    }

    func testNonPositiveThicknessClampedToOne() {
        let config = ClinicalSlabConfiguration(thickness: 0)
        XCTAssertEqual(config.thickness, 1)
    }

    func testNegativeThicknessClampedToOne() {
        let config = ClinicalSlabConfiguration(thickness: -10)
        XCTAssertEqual(config.thickness, 1)
    }

    func testStepsDefaultDerivesFromThickness() {
        // steps default: max(resolvedThickness * 2, 6), snapped to odd
        let config = ClinicalSlabConfiguration(thickness: 3)
        // resolvedThickness = 3, steps = max(3*2, 6) = 6 -> snap(6) = 7
        XCTAssertEqual(config.steps, 7)
    }

    func testExplicitStepsPreservesOddValue() {
        let config = ClinicalSlabConfiguration(thickness: 3, steps: 9)
        XCTAssertEqual(config.steps, 9)
    }

    func testExplicitEvenStepsSnappedToOdd() {
        let config = ClinicalSlabConfiguration(thickness: 3, steps: 8)
        XCTAssertEqual(config.steps, 9)
    }

    func testStepsMinimumIsOne() {
        let config = ClinicalSlabConfiguration(thickness: 1, steps: 0)
        XCTAssertGreaterThanOrEqual(config.steps, 1)
    }

    func testEquatableConformance() {
        let a = ClinicalSlabConfiguration(thickness: 3, steps: 7)
        let b = ClinicalSlabConfiguration(thickness: 3, steps: 7)
        XCTAssertEqual(a, b)
    }

    func testInequalityForDifferentConfigurations() {
        let a = ClinicalSlabConfiguration(thickness: 3, steps: 7)
        let b = ClinicalSlabConfiguration(thickness: 5, steps: 7)
        XCTAssertNotEqual(a, b)
    }

    func testStepsAlwaysOdd() {
        for thickness in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
            let config = ClinicalSlabConfiguration(thickness: thickness)
            XCTAssertEqual(config.thickness % 2, 1,
                           "thickness=\(config.thickness) should be odd (input: \(thickness))")
            XCTAssertEqual(config.steps % 2, 1,
                           "steps=\(config.steps) should be odd (thickness: \(thickness))")
        }
    }

    func testBoundaryEvenThicknessIntMax() {
        // When value == Int.max, snapToOddVoxelCount returns value - 1
        // But Int.max is an even number only on some platforms; use a large even value instead
        let largeEven = 1_000_000
        let config = ClinicalSlabConfiguration(thickness: largeEven)
        XCTAssertEqual(config.thickness % 2, 1)
    }

    func testDefaultStepsForMaximumThicknessDoesNotOverflow() {
        let config = ClinicalSlabConfiguration(thickness: Int.max)
        XCTAssertEqual(config.thickness, Int.max)
        XCTAssertEqual(config.steps, Int.max)
    }
}

// MARK: - ClinicalViewportGridControllerError

final class ClinicalViewportGridControllerErrorTests: XCTestCase {

    func testMetalUnavailableDescription() {
        let error = ClinicalViewportGridControllerError.metalUnavailable
        XCTAssertEqual(error.errorDescription, "Metal device unavailable")
    }

    func testNoDatasetAppliedDescription() {
        let error = ClinicalViewportGridControllerError.noDatasetApplied
        XCTAssertEqual(error.errorDescription, "No dataset is loaded in the clinical viewport grid")
    }

    func testViewportSurfaceNotFoundDescription() {
        let error = ClinicalViewportGridControllerError.viewportSurfaceNotFound
        XCTAssertEqual(error.errorDescription, "Viewport surface not found")
    }

    func testEquatableConformance() {
        XCTAssertEqual(ClinicalViewportGridControllerError.metalUnavailable,
                       ClinicalViewportGridControllerError.metalUnavailable)
        XCTAssertNotEqual(ClinicalViewportGridControllerError.metalUnavailable,
                          ClinicalViewportGridControllerError.noDatasetApplied)
    }

    func testConformsToLocalizedError() {
        let error: LocalizedError = ClinicalViewportGridControllerError.metalUnavailable
        XCTAssertNotNil(error.errorDescription)
    }
}

// MARK: - Debug Name Extensions (ViewportType, ProjectionMode, Axis)

final class DebugNameExtensionTests: XCTestCase {

    func testVolume3DDebugName() {
        XCTAssertEqual(ViewportType.volume3D.debugName, "volume3D")
    }

    func testMPRAxialDebugName() {
        XCTAssertEqual(ViewportType.mpr(axis: .axial).debugName, "mpr(axial)")
    }

    func testMPRCoronalDebugName() {
        XCTAssertEqual(ViewportType.mpr(axis: .coronal).debugName, "mpr(coronal)")
    }

    func testMPRSagittalDebugName() {
        XCTAssertEqual(ViewportType.mpr(axis: .sagittal).debugName, "mpr(sagittal)")
    }

    func testProjectionMIPDebugName() {
        XCTAssertEqual(ViewportType.projection(mode: .mip).debugName, "projection(mip)")
    }

    func testProjectionMinIPDebugName() {
        XCTAssertEqual(ViewportType.projection(mode: .minip).debugName, "projection(minip)")
    }

    func testProjectionAIPDebugName() {
        XCTAssertEqual(ViewportType.projection(mode: .aip).debugName, "projection(aip)")
    }

    func testProjectionModesMIPDebugName() {
        XCTAssertEqual(ProjectionMode.mip.debugName, "mip")
    }

    func testProjectionModesMinIPDebugName() {
        XCTAssertEqual(ProjectionMode.minip.debugName, "minip")
    }

    func testProjectionModesAIPDebugName() {
        XCTAssertEqual(ProjectionMode.aip.debugName, "aip")
    }

    func testAxisAxialDebugName() {
        XCTAssertEqual(MTKCore.Axis.axial.debugName, "axial")
    }

    func testAxisCoronalDebugName() {
        XCTAssertEqual(MTKCore.Axis.coronal.debugName, "coronal")
    }

    func testAxisSagittalDebugName() {
        XCTAssertEqual(MTKCore.Axis.sagittal.debugName, "sagittal")
    }
}

// MARK: - clinicalPlaneAxis and clinicalFallbackPlaneGeometry

final class ClinicalAxisMappingTests: XCTestCase {

    func testAxialMapsToZPlaneAxis() {
        XCTAssertEqual(clinicalPlaneAxis(for: .axial), .z)
    }

    func testCoronalMapsToYPlaneAxis() {
        XCTAssertEqual(clinicalPlaneAxis(for: .coronal), .y)
    }

    func testSagittalMapsToXPlaneAxis() {
        XCTAssertEqual(clinicalPlaneAxis(for: .sagittal), .x)
    }

    func testAxialFallbackGeometryIsCanonicalZ() {
        let geometry = clinicalFallbackPlaneGeometry(for: .axial)
        XCTAssertEqual(geometry, .canonical(axis: .z))
    }

    func testCoronalFallbackGeometryIsCanonicalY() {
        let geometry = clinicalFallbackPlaneGeometry(for: .coronal)
        XCTAssertEqual(geometry, .canonical(axis: .y))
    }

    func testSagittalFallbackGeometryIsCanonicalX() {
        let geometry = clinicalFallbackPlaneGeometry(for: .sagittal)
        XCTAssertEqual(geometry, .canonical(axis: .x))
    }

    func testDefaultClinicalMPRDisplayTransformIsNonNil() {
        // All three axes should produce a valid display transform
        for axis in MTKCore.Axis.allCases {
            let transform = defaultClinicalMPRDisplayTransform(for: axis)
            XCTAssertNotNil(transform)
            // The transform exists; verify it maps known axis correctly
            _ = transform.leadingLabel
        }
    }
}

// MARK: - ClinicalViewportDebugSnapshot

final class ClinicalViewportDebugSnapshotTests: XCTestCase {

    func testSnapshotIdentifiableByViewportID() {
        let id = ViewportID()
        let snapshot = ClinicalViewportDebugSnapshot(viewportID: id,
                                                     viewportName: "Axial",
                                                     viewportType: "mpr(axial)",
                                                     renderMode: "single")
        XCTAssertEqual(snapshot.id, id)
    }

    func testSnapshotDefaultPresentationStatusIsIdle() {
        let id = ViewportID()
        let snapshot = ClinicalViewportDebugSnapshot(viewportID: id,
                                                     viewportName: "Volume",
                                                     viewportType: "volume3D",
                                                     renderMode: "dvr")
        XCTAssertEqual(snapshot.presentationStatus, "idle")
    }

    func testSnapshotOptionalFieldsDefaultToNil() {
        let id = ViewportID()
        let snapshot = ClinicalViewportDebugSnapshot(viewportID: id,
                                                     viewportName: "Coronal",
                                                     viewportType: "mpr(coronal)",
                                                     renderMode: "single")
        XCTAssertNil(snapshot.datasetHandle)
        XCTAssertNil(snapshot.volumeTextureLabel)
        XCTAssertNil(snapshot.outputTextureLabel)
        XCTAssertNil(snapshot.lastPassExecuted)
        XCTAssertNil(snapshot.lastError)
        XCTAssertNil(snapshot.lastRenderRequestTime)
        XCTAssertNil(snapshot.lastRenderCompletionTime)
        XCTAssertNil(snapshot.lastPresentationTime)
    }

    func testSnapshotEquatable() {
        let id = ViewportID()
        let snap1 = ClinicalViewportDebugSnapshot(viewportID: id, viewportName: "Axial",
                                                   viewportType: "mpr(axial)", renderMode: "single")
        let snap2 = ClinicalViewportDebugSnapshot(viewportID: id, viewportName: "Axial",
                                                   viewportType: "mpr(axial)", renderMode: "single")
        XCTAssertEqual(snap1, snap2)
    }
}

// MARK: - ClinicalMPRDisplayContract (deprecated)

final class ClinicalMPRDisplayContractTests: XCTestCase {

    @available(*, deprecated)
    func testEquatableContractsWithSameLabelsMustBeEqual() {
        let contract1 = ClinicalMPRDisplayContract(
            flipHorizontal: false,
            flipVertical: true,
            labels: (leading: "R", trailing: "L", top: "A", bottom: "P")
        )
        let contract2 = ClinicalMPRDisplayContract(
            flipHorizontal: false,
            flipVertical: true,
            labels: (leading: "R", trailing: "L", top: "A", bottom: "P")
        )
        XCTAssertEqual(contract1, contract2)
    }

    @available(*, deprecated)
    func testDifferentFlipValuesMakeContractsUnequal() {
        let contract1 = ClinicalMPRDisplayContract(
            flipHorizontal: true,
            flipVertical: false,
            labels: (leading: "R", trailing: "L", top: "S", bottom: "I")
        )
        let contract2 = ClinicalMPRDisplayContract(
            flipHorizontal: false,
            flipVertical: false,
            labels: (leading: "R", trailing: "L", top: "S", bottom: "I")
        )
        XCTAssertNotEqual(contract1, contract2)
    }

    @available(*, deprecated)
    func testDefaultForAxialAxis() {
        let contract = ClinicalMPRDisplayContract.default(for: .axial)
        // Default transform for axial should have R as leading label
        XCTAssertEqual(contract.labels.leading, "R")
    }

    @available(*, deprecated)
    func testDefaultForCoronalAxis() {
        let contract = ClinicalMPRDisplayContract.default(for: .coronal)
        XCTAssertFalse(contract.labels.leading.isEmpty)
    }

    @available(*, deprecated)
    func testDefaultForSagittalAxis() {
        let contract = ClinicalMPRDisplayContract.default(for: .sagittal)
        XCTAssertFalse(contract.labels.leading.isEmpty)
    }
}
