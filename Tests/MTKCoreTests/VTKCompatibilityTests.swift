import XCTest
import simd
@testable import MTKCore

final class CompatibilityTests: XCTestCase {

    // MARK: - Opacity correction

    func testCorrectedOpacityMatchesCalculationFormula() {
        let factor: Float = 2.0
        let corrected = OpacityCorrection.correctedOpacity(0.5, factor: factor)
        XCTAssertEqual(corrected, 0.75, accuracy: 1e-5)
    }

    func testScalarOpacityUnitDistanceFromDataset() {
        // 2x2x2 volume, spacing 1mm, diagonal = sqrt(3), maxDim = 2
        // Expected unit distance = sqrt(3) / 2 ≈ 0.8660
        let dataset = makeCanonicalDataset(dim: 2, spacing: 1.0)
        let unitDistance = OpacityCorrection.scalarOpacityUnitDistance(for: dataset)
        XCTAssertEqual(unitDistance, 0.8660, accuracy: 1e-3)
    }

    // MARK: - Sample distance

    func testSampleDistanceIsotropicHighQuality() {
        let distance = SampleDistanceCalculator.sampleDistance(
            spacing: (1.0, 1.0, 1.0),
            quality: .high
        )
        XCTAssertEqual(distance, 0.7 * sqrt(3.0) / 2.5, accuracy: 1e-5)
    }

    func testSampleDistanceAnisotropicHighQuality() {
        // spacing 0.5, 0.5, 2.5 → sqrt(0.25+0.25+6.25)=2.598076
        let distance = SampleDistanceCalculator.sampleDistance(
            spacing: (0.5, 0.5, 2.5),
            quality: .high
        )
        XCTAssertEqual(distance, 0.7 * 2.598076211 / 2.5, accuracy: 1e-4)
    }

    func testVolumeRenderRequestDefaultsSamplingDistanceWhenNil() {
        let dataset = makeCanonicalDataset(dim: 2, spacing: 1.0)
        let request = VolumeRenderRequest(dataset: dataset,
                                          transferFunction: VolumeTransferFunction(opacityPoints: [], colourPoints: []),
                                          viewportSize: .init(width: 256, height: 256),
                                          camera: VolumeRenderRequest.Camera(position: .zero,
                                                                             target: SIMD3<Float>(0, 0, -1),
                                                                             up: SIMD3<Float>(0, 1, 0),
                                                                             fieldOfView: 45),
                                          samplingDistance: nil,
                                          compositing: .frontToBack,
                                          quality: .production)
        let expected = dataset.CompatibleSampleDistance(quality: .high)
        XCTAssertEqual(request.samplingDistance, expected, accuracy: 1e-5)
    }

    func testVolumeRenderRequestDefaultsMatchJs() {
        let dataset = makeCanonicalDataset(dim: 2, spacing: 1.0)
        let request = VolumeRenderRequest(dataset: dataset,
                                          transferFunction: VolumeTransferFunction(opacityPoints: [], colourPoints: []),
                                          viewportSize: .init(width: 256, height: 256),
                                          camera: VolumeRenderRequest.Camera(position: .zero,
                                                                             target: SIMD3<Float>(0, 0, -1),
                                                                             up: SIMD3<Float>(0, 1, 0),
                                                                             fieldOfView: 45),
                                          compositing: .frontToBack,
                                          quality: .production)

        XCTAssertEqual(request.reconstructionKernel, .linear, "Default reconstruction kernel should be Linear")

        XCTAssertEqual(request.gradientSmoothness, 0.0, accuracy: 1e-5)

        XCTAssertFalse(request.useLightOcclusion)
    }

    // MARK: - SCTC matrix

    func testWorldToTextureRoundTripCanonical() {
        let dataset = makeCanonicalDataset(dim: 2, spacing: 1.0)
        let geometry = dataset.dicomGeometry
        let world = SIMD4<Float>(1, 1, 1, 1) // center of voxel (1,1,1)
        let tex = geometry.worldToTex * world
        let worldBack = geometry.worldToVoxel * (geometry.textureToWorldMatrix * tex)
        // worldToVoxel should bring back to voxel space coordinates (i,j,k,1)
        XCTAssertEqual(worldBack.x, 1, accuracy: 1e-4)
        XCTAssertEqual(worldBack.y, 1, accuracy: 1e-4)
        XCTAssertEqual(worldBack.z, 1, accuracy: 1e-4)
    }

    private func makeCanonicalDataset(dim: Int, spacing: Double) -> VolumeDataset {
        let voxelCount = dim * dim * dim
        let data = Data(count: voxelCount * MemoryLayout<UInt16>.size)
        let dimensions = VolumeDimensions(width: dim, height: dim, depth: dim)
        let spacing = VolumeSpacing(x: spacing, y: spacing, z: spacing)
        return VolumeDataset(data: data,
                             dimensions: dimensions,
                             spacing: spacing,
                             pixelFormat: .int16Signed,
                             intensityRange: (Int32(-1024)...Int32(3071)),
                             orientation: .canonical,
                             recommendedWindow: nil)
    }
}
