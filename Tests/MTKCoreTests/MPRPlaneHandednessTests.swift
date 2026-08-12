// -----------------------------------------------------------------------------
// Summary: An MPR plane's basis keeps its handedness and its viewing side when a
//          rotation is applied.
// Context: The rotated coronal plane was built from a reference whose `axisU`
//          had been negated, with the normal recomputed to match. The triad
//          stayed right-handed, so nothing looked wrong locally — but the plane
//          was viewed from the opposite side of the patient. The coronal image
//          mirrored horizontally the instant the crosshair was first tilted, and
//          rotations about the longitudinal axis read backwards (issue #1657).
// Scope: MPRGeometryDisplayMapper.makePlane across all three plane axes.
// Purpose: Assert the sign, not the picture. A mirrored coronal is a laterality
//          error, and it is invisible to anyone not reading the R/L markers.
// -----------------------------------------------------------------------------

import XCTest
import simd

@testable import MTKCore

final class MPRPlaneHandednessTests: XCTestCase {

    /// The determinant of `[U, V, N]` is what a mirror flips — but on its own it
    /// would **not** have caught issue #1657, and that is worth knowing. The
    /// defect negated `axisU` and then recomputed the normal from the new
    /// `U × V`, so the triad stayed right-handed and the determinant kept its
    /// sign the whole time. That is exactly what made the mirror hard to see.
    /// Kept as the floor: a basis that loses handedness is broken in a way no
    /// other assertion here would name.
    func test_planeBasisKeepsItsHandednessAcrossTheFirstRotation() {
        for axis in [MPRPlaneAxis.x, .y, .z] {
            let unrotated = plane(axis: axis, rotation: nil)
            let rotated = plane(axis: axis, rotation: smallRotation)

            let before = signedVolume(of: unrotated)
            let after = signedVolume(of: rotated)

            XCTAssertGreaterThan(
                abs(before), 1e-6,
                "\(axis) starts with a degenerate basis, so the comparison proves nothing"
            )
            XCTAssertEqual(
                before > 0, after > 0,
                "\(axis) changes handedness when a rotation is applied: "
                    + "det went from \(before) to \(after)"
            )
        }
    }

    /// A rotation of a few degrees cannot move the normal to the other side of
    /// the plane. If it does, the basis was rebuilt rather than rotated.
    func test_everyPlaneKeepsItsViewingSideThroughASmallRotation() {
        for axis in [MPRPlaneAxis.x, .y, .z] {
            let unrotated = plane(axis: axis, rotation: nil)
            let rotated = plane(axis: axis, rotation: smallRotation)

            XCTAssertGreaterThan(
                simd_dot(simd_normalize(unrotated.normalWorld),
                         simd_normalize(rotated.normalWorld)),
                0.9,
                "\(axis) is viewed from the other side after a 6° rotation"
            )
            XCTAssertGreaterThan(
                simd_dot(simd_normalize(unrotated.axisUWorld),
                         simd_normalize(rotated.axisUWorld)),
                0.9,
                "\(axis) reverses its horizontal direction after a 6° rotation — "
                    + "left and right swap sides"
            )
        }
    }

    /// The coronal plane is the one that carried the defect, and the one where
    /// it matters most: its horizontal direction *is* patient left/right.
    func test_coronalHorizontalDirectionIsUnchangedByRotation() {
        let unrotated = plane(axis: .y, rotation: nil)
        let rotated = plane(axis: .y, rotation: simd_quatf(angle: 0.1,
                                                           axis: SIMD3<Float>(1, 0, 0)))

        XCTAssertEqual(unrotated.axisUWorld.x, rotated.axisUWorld.x, accuracy: 1e-5)
        XCTAssertLessThan(
            unrotated.axisUWorld.x, 0,
            "The coronal plane runs its horizontal axis toward −x. Losing that sign mirrors the image."
        )
    }

    /// The second symptom: tilting about the patient's longitudinal axis turned
    /// the coronal image the wrong way. A basis viewed from the far side turns
    /// backwards, so this is the same sign expressed as a direction of travel.
    func test_rotatingAboutTheLongitudinalAxisTurnsCoronalTheWayItWasAsked() {
        let axisOfRotation = SIMD3<Float>(0, 0, 1)
        let before = plane(axis: .y, rotation: nil)
        let after = plane(axis: .y,
                          rotation: simd_quatf(angle: 0.1, axis: axisOfRotation))

        let turn = simd_cross(simd_normalize(before.axisUWorld),
                              simd_normalize(after.axisUWorld))

        XCTAssertGreaterThan(
            simd_dot(turn, axisOfRotation), 0,
            "A positive rotation about +z turned the coronal horizontal axis the other way"
        )
    }

    // MARK: - Fixtures

    /// Deliberately anisotropic: equal spacing would hide a sign error that only
    /// shows once the axes have different lengths.
    private func makeDataset() -> VolumeDataset {
        VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 5, height: 7, depth: 9),
            spacing: VolumeSpacing(x: 0.8, y: 1.2, z: 2.4),
            orientation: VolumeOrientation(row: SIMD3<Float>(1, 0, 0),
                                           column: SIMD3<Float>(0, 1, 0),
                                           origin: .zero)
        )
    }

    /// Small enough that no axis can legitimately cross into another octant.
    private var smallRotation: simd_quatf {
        simd_quatf(angle: 6 * .pi / 180, axis: simd_normalize(SIMD3<Float>(0.2, 0.3, 1)))
    }

    private func plane(axis: MPRPlaneAxis, rotation: simd_quatf?) -> MPRPlaneGeometry {
        MPRGeometryDisplayMapper.makePlane(for: makeDataset(),
                                           axis: axis,
                                           slicePosition: 0.5,
                                           rotation: rotation)
    }

    private func signedVolume(of plane: MPRPlaneGeometry) -> Float {
        simd_determinant(simd_float3x3(columns: (plane.axisUWorld,
                                                 plane.axisVWorld,
                                                 plane.normalWorld)))
    }
}
