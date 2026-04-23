import CoreGraphics
import Metal
import XCTest

@testable import MTKCore

final class ResourceMemoryEstimatorTests: XCTestCase {
    func test_datasetEstimate_usesVoxelCountAndBytesPerVoxel() {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 5, depth: 6),
            pixelFormat: .int16Unsigned
        )

        XCTAssertEqual(ResourceMemoryEstimator.estimate(for: dataset), 4 * 5 * 6 * 2)
    }

    func test_outputTextureEstimate_roundsUpSizeAndUsesPixelFormatCost() {
        let size = CGSize(width: 10.2, height: 20.1)

        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: size, pixelFormat: .bgra8Unorm),
            11 * 21 * 4
        )
    }

    func test_outputTextureEstimate_returnsZeroForInvalidPixelFormat() {
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: CGSize(width: 10, height: 10), pixelFormat: .invalid),
            0
        )
    }

    func test_outputTextureEstimate_returnsZeroForNonFiniteSize() {
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: CGSize(width: CGFloat.nan, height: 10),
                                             pixelFormat: .bgra8Unorm),
            0
        )
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: CGSize(width: 10, height: CGFloat.infinity),
                                             pixelFormat: .bgra8Unorm),
            0
        )
    }

    func test_outputTextureEstimate_saturatesHugeFiniteSize() {
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1),
                                             pixelFormat: .bgra8Unorm),
            Int.max
        )
    }

    func test_outputTextureEstimate_usesCorrectDepthStencilPixelFormatCosts() {
        let size = CGSize(width: 10, height: 10)

        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: size, pixelFormat: .stencil8),
            10 * 10
        )
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: size, pixelFormat: .x24_stencil8),
            10 * 10 * 4
        )
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: size, pixelFormat: .x32_stencil8),
            10 * 10 * 8
        )
        XCTAssertEqual(
            ResourceMemoryEstimator.estimate(forOutputTexture: size, pixelFormat: .depth32Float_stencil8),
            10 * 10 * 8
        )
    }

    func test_textureEstimate_countsCubeFaces() throws {
        let device = try makeDevice()
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba8Unorm,
            size: 4,
            mipmapped: false
        )
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        XCTAssertEqual(ResourceMemoryEstimator.estimate(for: texture), 4 * 4 * 6 * 4)
    }

    func test_textureEstimate_countsCubeArrayFaces() throws {
        let device = try makeDevice()
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .typeCubeArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 4
        descriptor.height = 4
        descriptor.depth = 1
        descriptor.arrayLength = 2
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        XCTAssertEqual(ResourceMemoryEstimator.estimate(for: texture), 4 * 4 * 2 * 6 * 4)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }
}
