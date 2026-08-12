//
//  StackAnatomicalOrientationTests.swift
//  MTKCoreTests
//
//  Issue #1840: the stack axes are acquisition-relative, so the plane a
//  stack axis shows must be classified from its world-space normal — a
//  coronal acquisition's `.axial` axis IS the coronal plane.
//

import simd
import XCTest
@testable import MTKCore

final class StackAnatomicalOrientationTests: XCTestCase {

    func test_axialAcquisition_isTheIdentityMapping() {
        let imageData = makeImageData(
            row: SIMD3<Float>(1, 0, 0),
            column: SIMD3<Float>(0, 1, 0)
        )

        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .axial, in: imageData), .axial)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .coronal, in: imageData), .coronal)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .sagittal, in: imageData), .sagittal)
    }

    func test_coronalAcquisition_swapsAxialAndCoronal() {
        // BRAINIX "T1/3D/FFE/C": rows run left, columns run inferior, so the
        // in-plane axis shows the coronal plane and sweeping the columns
        // shows the axial plane.
        let imageData = makeImageData(
            row: SIMD3<Float>(1, 0, 0),
            column: SIMD3<Float>(0, 0, -1)
        )

        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .axial, in: imageData), .coronal)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .coronal, in: imageData), .axial)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .sagittal, in: imageData), .sagittal)
    }

    func test_sagittalAcquisition_mapsEveryAxisToItsPlane() {
        let imageData = makeImageData(
            row: SIMD3<Float>(0, 1, 0),
            column: SIMD3<Float>(0, 0, -1)
        )

        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .axial, in: imageData), .sagittal)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .coronal, in: imageData), .axial)
        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .sagittal, in: imageData), .coronal)
    }

    func test_obliqueAcquisition_isNamedObliqueRatherThanGuessed() {
        // 40 degrees off axial: below the 0.8 dominance threshold.
        let angle = Float(40.0 * .pi / 180.0)
        let imageData = makeImageData(
            row: SIMD3<Float>(1, 0, 0),
            column: SIMD3<Float>(0, cos(angle), sin(angle))
        )

        XCTAssertEqual(StackAnatomicalOrientation.plane(for: .axial, in: imageData), .oblique)
    }

    func test_degenerateNormal_isOblique() {
        XCTAssertEqual(StackAnatomicalOrientation.anatomicalPlane(forNormal: .zero), .oblique)
        XCTAssertEqual(
            StackAnatomicalOrientation.anatomicalPlane(forNormal: SIMD3<Float>(.nan, 0, 0)),
            .oblique
        )
    }

    func test_unverifiedOrientation_refusesToClassify() {
        let imageData = makeImageData(
            row: SIMD3<Float>(1, 0, 0),
            column: SIMD3<Float>(0, 1, 0),
            isOrientationVerified: false
        )

        XCTAssertNil(StackAnatomicalOrientation.plane(for: .axial, in: imageData))
    }

    func test_axisShowingPlane_invertsTheMapping() {
        let dataset = makeDataset(
            row: SIMD3<Float>(1, 0, 0),
            column: SIMD3<Float>(0, 0, -1)
        )

        XCTAssertEqual(StackAnatomicalOrientation.axis(showing: .coronal, in: dataset), .axial)
        XCTAssertEqual(StackAnatomicalOrientation.axis(showing: .axial, in: dataset), .coronal)
        XCTAssertEqual(StackAnatomicalOrientation.axis(showing: .sagittal, in: dataset), .sagittal)
        XCTAssertNil(StackAnatomicalOrientation.axis(showing: .oblique, in: dataset))
    }

    // MARK: - Harness

    private func makeImageData(
        row: SIMD3<Float>,
        column: SIMD3<Float>,
        isOrientationVerified: Bool = true
    ) -> ImageData3D {
        let normal = simd_normalize(simd_cross(row, column))
        return ImageData3D(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            isInPlaneSpacingCalibrated: true,
            isOrientationVerified: isOrientationVerified,
            origin: .zero,
            direction: simd_float3x3(columns: (row, column, normal)),
            pixelFormat: .int16Signed,
            componentsPerVoxel: 1,
            intensityRange: -1024...3071,
            recommendedWindow: nil,
            clinicalMetadata: nil
        )
    }

    private func makeDataset(
        row: SIMD3<Float>,
        column: SIMD3<Float>
    ) -> VolumeDataset {
        VolumeDataset(
            data: Data(count: 4 * 4 * 4 * 2),
            imageData: makeImageData(row: row, column: column)
        )
    }
}
