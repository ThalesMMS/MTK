import XCTest
import simd

@_spi(Testing) @testable import MTKCore

final class RegisteredVolumeLayerResamplerTests: XCTestCase {
    func testLayerTransformClassifiesSupportedAndUnsupportedTransforms() {
        XCTAssertEqual(matrix_identity_float4x4.mtkLayerTransformClassification, .identity)
        XCTAssertEqual(translation(x: 1).mtkLayerTransformClassification, .translation)
        XCTAssertEqual(scale(x: 0.5).mtkLayerTransformClassification, .axisAlignedScale)
        XCTAssertEqual((translation(x: 1) * scale(x: 0.5)).mtkLayerTransformClassification,
                       .translatedAxisAlignedScale)
        XCTAssertEqual(rotationZ90().mtkLayerTransformClassification, .unsupportedAffine)

        var nonAffine = matrix_identity_float4x4
        nonAffine.columns.0.w = 0.5
        XCTAssertEqual(nonAffine.mtkLayerTransformClassification, .nonAffine)
    }

    func testTranslatedScalarLayerIsResampledIntoBaseGeometry() throws {
        let base = makeDataset(values: [0, 0, 0],
                               dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let source = makeDataset(values: [10, 20, 30],
                                 dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let layer = makeLayer(dataset: source,
                              transform: translation(x: 1))

        let resampled = try RegisteredVolumeLayerResampler.resampledLayer(
            layer,
            into: base,
            interpolation: .nearest,
            fillValue: -1
        )

        XCTAssertEqual(signedValues(from: try XCTUnwrap(resampled.scalarVolume?.dataset)), [20, 30, -1])
        XCTAssertEqual(resampled.scalarVolume?.dataset.spacing, base.spacing)
        XCTAssertEqual(resampled.scalarVolume?.dataset.imageData.origin, base.imageData.origin)
        XCTAssertEqual(resampled.scalarVolume?.dataset.intensityRange, -1...30)
        XCTAssertEqual(resampled.baseWorldToLayerWorld, matrix_identity_float4x4)
    }

    func testScaledScalarLayerUsesTrilinearSampling() throws {
        let base = makeDataset(values: [0, 0, 0],
                               dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let source = makeDataset(values: [0, 10, 20],
                                 dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let layer = makeLayer(dataset: source,
                              transform: scale(x: 0.5))

        let resampled = try RegisteredVolumeLayerResampler.resampledLayer(
            layer,
            into: base,
            interpolation: .trilinear,
            fillValue: -1
        )

        XCTAssertEqual(signedValues(from: try XCTUnwrap(resampled.scalarVolume?.dataset)), [0, 5, 10])
    }

    func testUnsupportedTransformFailsExplicitly() throws {
        let base = makeDataset(values: [0, 0, 0],
                               dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let source = makeDataset(values: [10, 20, 30],
                                 dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let layer = makeLayer(id: "rotated-pet",
                              dataset: source,
                              transform: rotationZ90())

        XCTAssertThrowsError(try RegisteredVolumeLayerResampler.resampledLayer(layer, into: base)) { error in
            XCTAssertEqual(error as? RegisteredVolumeLayerResamplingError,
                           .unsupportedTransform(layerID: "rotated-pet", classification: .unsupportedAffine))
        }
    }

    private func makeLayer(id: String = "pet",
                           dataset: VolumeDataset,
                           transform: simd_float4x4) -> VolumeLayer {
        VolumeLayer(id: id,
                    dataset: dataset,
                    transferFunction: .defaultGrayscale(for: dataset),
                    opacity: 0.5,
                    blendMode: .additive,
                    baseWorldToLayerWorld: transform)
    }

    private func makeDataset(values: [Int16],
                             dimensions: VolumeDimensions,
                             spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1)) -> VolumeDataset {
        VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: Int32(values.min() ?? 0)...Int32(values.max() ?? 0)
        )
    }

    private func signedValues(from dataset: VolumeDataset) -> [Int32] {
        dataset.data.withUnsafeBytes { buffer in
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: Int16.self)
            return UnsafeBufferPointer(start: pointer, count: dataset.voxelCount).map(Int32.init)
        }
    }

    private func translation(x: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3.x = x
        return transform
    }

    private func scale(x: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.0.x = x
        return transform
    }

    private func rotationZ90() -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
