// -----------------------------------------------------------------------------
// Summary: The crop box carries an orientation, and it survives persistence.
// Context: Issue #1672. `Cropping box tilt` turns the box inside a still
//          volume. The shader has always rotated the sample into box space —
//          `prepareClipSample` — but nothing on the Swift side ever wrote
//          `clipBoxQuaternion`, so the box was axis-aligned by omission.
// Scope: VolumeCropBox's rotation, its normalization, and its coding.
// Purpose: A degenerate quaternion reaching the shader rotates every sample
//          into nothing and blanks the render, which reads as a broken volume
//          rather than as a tilted crop. And a saved crop that decodes with a
//          different orientation is a study that looks cut in the wrong place.
// -----------------------------------------------------------------------------

import XCTest
import simd
@testable import MTKCore

final class VolumeCropBoxRotationTests: XCTestCase {

    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    func test_aBoxIsAxisAlignedUnlessToldOtherwise() throws {
        let box = try VolumeCropBox(textureMin: .zero, textureMax: SIMD3<Float>(repeating: 1))

        XCTAssertEqual(box.rotation, identity)
    }

    func test_aRotationIsKeptNormalized() throws {
        let box = try VolumeCropBox(
            textureMin: .zero,
            textureMax: SIMD3<Float>(repeating: 1),
            rotation: simd_quatf(vector: SIMD4<Float>(0, 0, 3, 3))
        )

        XCTAssertEqual(simd_length(box.rotation.vector), 1, accuracy: 1e-5)
    }

    /// Identity is the honest fallback: it is what the box means when nobody
    /// has tilted it, and it is the one value that cannot blank the render.
    func test_aDegenerateRotationFallsBackToIdentity() throws {
        for degenerate in [
            simd_quatf(vector: .zero),
            simd_quatf(vector: SIMD4<Float>(.nan, 0, 0, 1)),
            simd_quatf(vector: SIMD4<Float>(0, .infinity, 0, 1))
        ] {
            let box = try VolumeCropBox(
                textureMin: .zero,
                textureMax: SIMD3<Float>(repeating: 1),
                rotation: degenerate
            )
            XCTAssertEqual(
                box.rotation,
                identity,
                "A box must never carry the unusable rotation \(degenerate.vector)"
            )
        }
    }

    /// CPU picking must test the same oriented box the shader renders.
    func test_rotatedBox_containsCoordinatesInRotatedBoxSpace() throws {
        let box = try VolumeCropBox(
            textureMin: SIMD3<Float>(0.1, 0.4, 0.4),
            textureMax: SIMD3<Float>(0.4, 0.6, 0.6),
            rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        )

        XCTAssertTrue(box.contains(textureCoordinate: SIMD3<Float>(0.5, 0.25, 0.5)))
        XCTAssertFalse(box.contains(textureCoordinate: SIMD3<Float>(0.25, 0.5, 0.5)))
    }

    // MARK: - Persistence

    /// The field is new, so everything written before it decodes as
    /// axis-aligned — which is exactly what those boxes were.
    func test_aBoxSavedBeforeTheRotationExistedDecodesAxisAligned() throws {
        let legacy = Data("""
        {"xMin":0.1,"xMax":0.9,"yMin":0.2,"yMax":0.8,"zMin":0.3,"zMax":0.7}
        """.utf8)

        let box = try JSONDecoder().decode(VolumeCropBox.self, from: legacy)

        XCTAssertEqual(box.rotation, identity)
        XCTAssertEqual(box.textureMin.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(box.textureMax.z, 0.7, accuracy: 1e-6)
    }

    func test_aRotatedBoxSurvivesARoundTrip() throws {
        let rotation = simd_quatf(angle: .pi / 5, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.4)))
        let box = try VolumeCropBox(
            textureMin: SIMD3<Float>(repeating: 0.1),
            textureMax: SIMD3<Float>(repeating: 0.9),
            rotation: rotation
        )

        let decoded = try JSONDecoder().decode(
            VolumeCropBox.self,
            from: try JSONEncoder().encode(box)
        )

        XCTAssertEqual(decoded.rotation.vector.x, box.rotation.vector.x, accuracy: 1e-6)
        XCTAssertEqual(decoded.rotation.vector.y, box.rotation.vector.y, accuracy: 1e-6)
        XCTAssertEqual(decoded.rotation.vector.z, box.rotation.vector.z, accuracy: 1e-6)
        XCTAssertEqual(decoded.rotation.vector.w, box.rotation.vector.w, accuracy: 1e-6)
    }

    // MARK: - Reaching the shader

    /// The assertion the whole issue turns on: the clipping state hands the
    /// rotation to the parameter writer. Before this it was never written, so
    /// `clipBoxQuaternion` sat at identity no matter what the box said.
    func test_theClippingStateCarriesTheRotationToTheShader() throws {
        let rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 0, 1))
        let state = try VolumeClippingState(
            cropBox: VolumeCropBox(
                textureMin: .zero,
                textureMax: SIMD3<Float>(repeating: 1),
                rotation: rotation
            ),
            clipPlanes: []
        )

        let carried = state.shaderCropRotation()

        XCTAssertEqual(carried.x, rotation.vector.x, accuracy: 1e-6)
        XCTAssertEqual(carried.y, rotation.vector.y, accuracy: 1e-6)
        XCTAssertEqual(carried.z, rotation.vector.z, accuracy: 1e-6)
        XCTAssertEqual(carried.w, rotation.vector.w, accuracy: 1e-6)
    }

    /// No crop box means no rotation — the shader must get identity, not the
    /// last box's orientation.
    func test_noCropBoxMeansIdentityAtTheShader() throws {
        let carried = try VolumeClippingState(cropBox: nil, clipPlanes: []).shaderCropRotation()

        XCTAssertEqual(carried, identity.vector)
    }
}
