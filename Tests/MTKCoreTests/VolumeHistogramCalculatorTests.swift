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

    /// The threadgroup kernel spreads its bins across the threads of one threadgroup, so
    /// a grid far smaller than the threadgroup and far smaller than the bin count is the
    /// case where coverage can quietly go missing. Every voxel must still be counted.
    func testComputeHistogramCoversAGridSmallerThanOneThreadgroup() throws {
        let expectation = expectation(description: "4096-bin histogram over 4 voxels")
        let texture = try makeUnsignedTexture(values: [0, 32_768, 65_535, 65_535],
                                              width: 2,
                                              height: 2,
                                              depth: 1)

        calculator.computeHistogram(for: texture,
                                    channelCount: 1,
                                    voxelMin: 0,
                                    voxelMax: 65_535,
                                    bins: 4096) { result in
            switch result {
            case .success(let histograms):
                XCTAssertEqual(histograms[0].reduce(0, +), 4)
                XCTAssertEqual(histograms[0][0], 1)
                XCTAssertEqual(histograms[0][2048], 1)
                XCTAssertEqual(histograms[0][4095], 2)
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    /// A grid one thread past a threadgroup boundary leaves ragged threadgroups at the
    /// edges — one thread wide in places. Those must cover the bins too.
    func testComputeHistogramCoversRaggedEdgeThreadgroups() throws {
        let expectation = expectation(description: "histogram over a ragged grid")
        let side = 33
        var values = [UInt16](repeating: 0, count: side * side)
        values[values.count - 1] = 65_535
        let texture = try makeUnsignedTexture(values: values, width: side, height: side, depth: 1)

        calculator.computeHistogram(for: texture,
                                    channelCount: 1,
                                    voxelMin: 0,
                                    voxelMax: 65_535,
                                    bins: 4096) { result in
            switch result {
            case .success(let histograms):
                XCTAssertEqual(histograms[0].reduce(0, +), UInt32(side * side))
                XCTAssertEqual(histograms[0][0], UInt32(side * side - 1))
                XCTAssertEqual(histograms[0][4095], 1)
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
            }
            expectation.fulfill()
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
