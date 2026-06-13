//
//  VolumeHistogramCalculatorTests.swift
//  MTK
//
//  Unit tests for GPU-backed volume histogram calculation.
//

import Metal
@_spi(Testing) import MTKCore
import XCTest

final class VolumeHistogramCalculatorTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!
    private var calculator: VolumeHistogramCalculator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        self.library = try ShaderLibraryLoader.loadLibrary(for: device)

        calculator = VolumeHistogramCalculator(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: FeatureFlags.evaluate(for: device),
            debugOptions: VolumeRenderingDebugOptions()
        )
    }

    func testComputeHistogramAcceptsUnsigned16BitFullRange() throws {
        let expectation = expectation(description: "Unsigned 16-bit histogram")
        let texture = try makeUnsignedTexture(values: [0, 32_768, 65_535, 65_535],
                                              width: 2,
                                              height: 2,
                                              depth: 1)

        calculator.computeHistogram(for: texture,
                                    channelCount: 1,
                                    voxelMin: 0,
                                    voxelMax: 65_535,
                                    bins: 64) { result in
            switch result {
            case .success(let histograms):
                XCTAssertEqual(histograms.count, 1)
                XCTAssertEqual(histograms[0].count, 64)
                XCTAssertEqual(histograms[0].reduce(0, +), 4)
                XCTAssertEqual(histograms[0][0], 1)
                XCTAssertEqual(histograms[0][32], 1)
                XCTAssertEqual(histograms[0][63], 2)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeHistogramPreservesSigned16BitRange() throws {
        let expectation = expectation(description: "Signed 16-bit histogram")
        let texture = try makeSignedTexture(values: [-1024, 0, 3071, 3071],
                                            width: 2,
                                            height: 2,
                                            depth: 1)

        calculator.computeHistogram(for: texture,
                                    channelCount: 1,
                                    voxelMin: -1024,
                                    voxelMax: 3071,
                                    bins: 64) { result in
            switch result {
            case .success(let histograms):
                XCTAssertEqual(histograms.count, 1)
                XCTAssertEqual(histograms[0].count, 64)
                XCTAssertEqual(histograms[0].reduce(0, +), 4)
                XCTAssertEqual(histograms[0][0], 1)
                XCTAssertEqual(histograms[0][16], 1)
                XCTAssertEqual(histograms[0][63], 2)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    private func makeUnsignedTexture(values: [UInt16],
                                     width: Int,
                                     height: Int,
                                     depth: Int) throws -> any MTLTexture {
        try makeTexture(values, width: width, height: height, depth: depth, pixelFormat: .r16Uint)
    }

    private func makeSignedTexture(values: [Int16],
                                   width: Int,
                                   height: Int,
                                   depth: Int) throws -> any MTLTexture {
        try makeTexture(values, width: width, height: height, depth: depth, pixelFormat: .r16Sint)
    }

    private func makeTexture<T>(_ values: [T],
                                width: Int,
                                height: Int,
                                depth: Int,
                                pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        XCTAssertEqual(values.count, width * height * depth)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { pointer in
            texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                             size: MTLSize(width: width, height: height, depth: depth)),
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: pointer.baseAddress!,
                            bytesPerRow: width * MemoryLayout<T>.stride,
                            bytesPerImage: width * height * MemoryLayout<T>.stride)
        }
        return texture
    }
}
