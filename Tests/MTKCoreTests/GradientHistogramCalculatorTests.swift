//
//  GradientHistogramCalculatorTests.swift
//  MTK
//
//  Unit tests for GradientHistogramCalculator 2D gradient-intensity histogram computation.
//  Validates GPU calculations match expected values and error handling behavior.
//
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
import Metal
@_spi(Testing) import MTKCore

final class GradientHistogramCalculatorTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!
    private var calculator: GradientHistogramCalculator!

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

        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        self.library = library

        let featureFlags = FeatureFlags.evaluate(for: device)
        let debugOptions = VolumeRenderingDebugOptions()
        self.calculator = GradientHistogramCalculator(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: featureFlags,
            debugOptions: debugOptions
        )
    }

    // MARK: - Kernel Planning Tests - Pure Metal compute kernel selection based on device capabilities (no MPS dependency)

    func testKernelPlannerSelectsThreadgroupKernelForSmallBinCounts() {
        let maxMemory = device.maxThreadgroupMemoryLength
        let intensityBins = 256
        let gradientBins = 256
        let totalBins = intensityBins * gradientBins
        let bufferLength = totalBins * MemoryLayout<UInt32>.stride

        let plan = GradientHistogramKernelPlanner.makePlan(
            intensityBins: intensityBins,
            gradientBins: gradientBins,
            defaultIntensityBinCount: 256,
            defaultGradientBinCount: 256,
            maxThreadgroupMemoryLength: maxMemory
        )

        XCTAssertEqual(plan.intensityBins, 256)
        XCTAssertEqual(plan.gradientBins, 256)
        XCTAssertEqual(plan.bufferLength, bufferLength)

        if bufferLength <= maxMemory {
            XCTAssertTrue(plan.usesThreadgroupMemory, "Should use threadgroup memory for small bin counts")
            XCTAssertEqual(plan.kernelName, "computeGradientHistogramThreadgroup")
        } else {
            XCTAssertFalse(plan.usesThreadgroupMemory, "Should use device-memory kernel when threadgroup memory is insufficient")
            XCTAssertEqual(plan.kernelName, "computeGradientHistogramLegacy")
        }
    }

    func testKernelPlannerSelectsDeviceMemoryKernelForLargeBinCounts() {
        let maxMemory = device.maxThreadgroupMemoryLength
        let intensityBins = 4096
        let gradientBins = 4096
        let totalBins = intensityBins * gradientBins
        let bufferLength = totalBins * MemoryLayout<UInt32>.stride

        let plan = GradientHistogramKernelPlanner.makePlan(
            intensityBins: intensityBins,
            gradientBins: gradientBins,
            defaultIntensityBinCount: 256,
            defaultGradientBinCount: 256,
            maxThreadgroupMemoryLength: maxMemory
        )

        XCTAssertEqual(plan.intensityBins, 4096)
        XCTAssertEqual(plan.gradientBins, 4096)
        XCTAssertEqual(plan.bufferLength, bufferLength)

        // Large bin counts should exceed threadgroup memory
        XCTAssertGreaterThan(bufferLength, maxMemory, "Large bin count should exceed threadgroup memory")
        XCTAssertFalse(plan.usesThreadgroupMemory, "Should use device-memory kernel for large bin counts")
        XCTAssertEqual(plan.kernelName, "computeGradientHistogramLegacy")
    }

    func testKernelPlannerUsesDefaultsWhenRequestedBinsAreZero() {
        let plan = GradientHistogramKernelPlanner.makePlan(
            intensityBins: 0,
            gradientBins: 0,
            defaultIntensityBinCount: 512,
            defaultGradientBinCount: 512,
            maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength
        )

        XCTAssertEqual(plan.intensityBins, 512, "Should use default intensity bin count")
        XCTAssertEqual(plan.gradientBins, 512, "Should use default gradient bin count")
    }

    func testKernelPlannerClampsExcessiveBinCounts() {
        let plan = GradientHistogramKernelPlanner.makePlan(
            intensityBins: 100000,
            gradientBins: 100000,
            defaultIntensityBinCount: 256,
            defaultGradientBinCount: 256,
            maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength
        )

        // VolumetricMath.clampBinCount should limit to 4096
        XCTAssertLessThanOrEqual(plan.intensityBins, 4096, "Should clamp excessive intensity bins")
        XCTAssertLessThanOrEqual(plan.gradientBins, 4096, "Should clamp excessive gradient bins")
    }

    // MARK: - Basic Histogram Computation Tests

    func testComputeGradientHistogramWithUniformTexture() {
        let expectation = expectation(description: "Uniform texture histogram")

        // Create uniform 3D texture: all voxels have same intensity
        let texture = create3DTexture(width: 32, height: 32, depth: 32, fillValue: 1000)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 2000,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                XCTAssertEqual(histogram.count, 256, "Should have 256 intensity bins")
                XCTAssertEqual(histogram[0].count, 256, "Each intensity bin should have 256 gradient bins")

                // Uniform texture should have all samples in one intensity bin (around value 1000)
                // Expected bin: (1000 - 0) / (2000 - 0) * 256 ≈ bin 128
                let expectedIntensityBin = 128
                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                let expectedSamples = 32 * 32 * 32  // All voxels

                XCTAssertEqual(totalSamples, UInt32(expectedSamples), "Should count all voxels")

                // Most samples should be in low gradient bins (uniform = near-zero gradients)
                let lowGradientSamples = histogram[expectedIntensityBin][0..<10].reduce(0, +)
                XCTAssertGreaterThan(lowGradientSamples, UInt32(expectedSamples / 2),
                                     "Uniform texture should have most samples in low gradient bins")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithGradientTexture() {
        let expectation = expectation(description: "Gradient texture histogram")

        // Create texture with linear gradient along X axis
        let texture = createGradientTexture(width: 64, height: 64, depth: 64)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 100.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                XCTAssertEqual(histogram.count, 256, "Should have 256 intensity bins")

                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                let expectedSamples = 64 * 64 * 64

                XCTAssertEqual(totalSamples, UInt32(expectedSamples), "Should count all voxels")

                // Linear gradient should spread across intensity bins
                let nonZeroBins = histogram.filter { row in row.reduce(0, +) > 0 }.count
                XCTAssertGreaterThan(nonZeroBins, 10, "Gradient should spread across multiple intensity bins")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithSmallBinCounts() {
        let expectation = expectation(description: "Small bin counts")

        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 500)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 1000,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 64,
            gradientBins: 64
        ) { result in
            switch result {
            case .success(let histogram):
                XCTAssertEqual(histogram.count, 64, "Should have 64 intensity bins")
                XCTAssertEqual(histogram[0].count, 64, "Should have 64 gradient bins")

                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                XCTAssertEqual(totalSamples, UInt32(16 * 16 * 16), "Should count all voxels")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithLargeBinCounts() {
        let expectation = expectation(description: "Large bin counts")

        let texture = create3DTexture(width: 32, height: 32, depth: 32, fillValue: 2000)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 10.0,
            intensityBins: 512,
            gradientBins: 512
        ) { result in
            switch result {
            case .success(let histogram):
                XCTAssertEqual(histogram.count, 512, "Should have 512 intensity bins")
                XCTAssertEqual(histogram[0].count, 512, "Should have 512 gradient bins")

                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                XCTAssertEqual(totalSamples, UInt32(32 * 32 * 32), "Should count all voxels")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Boundary Condition Tests

    func testComputeGradientHistogramWithMinimumTextureDimensions() {
        let expectation = expectation(description: "Minimum dimensions")

        // 1x1x1 texture
        let texture = create3DTexture(width: 1, height: 1, depth: 1, fillValue: 1000)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 2000,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                XCTAssertEqual(totalSamples, 1, "Should count single voxel")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithMaxVoxelValue() {
        let expectation = expectation(description: "Max voxel value")

        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 4095)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                // All samples should be in highest intensity bin (bin 255)
                let highIntensityBinSamples = histogram[255].reduce(0, +)
                XCTAssertGreaterThan(highIntensityBinSamples, 0,
                                     "Max voxel values should be in highest intensity bin")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithMinVoxelValue() {
        let expectation = expectation(description: "Min voxel value")

        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 0)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                // All samples should be in lowest intensity bin (bin 0)
                let lowIntensityBinSamples = histogram[0].reduce(0, +)
                XCTAssertGreaterThan(lowIntensityBinSamples, 0,
                                     "Min voxel values should be in lowest intensity bin")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeGradientHistogramWithNegativeVoxelRange() {
        let expectation = expectation(description: "Negative voxel range")

        // CT data often has negative HU values
        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 500)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: -1024,
            voxelMax: 3071,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                XCTAssertEqual(totalSamples, UInt32(16 * 16 * 16), "Should count all voxels")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Consistency Tests

    func testComputeGradientHistogramConsistencyAcrossMultipleRuns() {
        let firstExpectation = expectation(description: "First histogram run")
        let secondExpectation = expectation(description: "Second histogram run")

        let texture = create3DTexture(width: 32, height: 32, depth: 32, fillValue: 1500)

        var firstHistogram: [[UInt32]]?
        var secondHistogram: [[UInt32]]?

        // First run
        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                firstHistogram = histogram
                firstExpectation.fulfill()
            case .failure(let error):
                XCTFail("First run failed: \(error)")
                firstExpectation.fulfill()
            }
        }

        wait(for: [firstExpectation], timeout: 5.0)

        // Second run with same data
        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 4095,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                secondHistogram = histogram
                secondExpectation.fulfill()
            case .failure(let error):
                XCTFail("Second run failed: \(error)")
                secondExpectation.fulfill()
            }
        }

        wait(for: [secondExpectation], timeout: 5.0)

        // Verify consistency
        XCTAssertNotNil(firstHistogram)
        XCTAssertNotNil(secondHistogram)

        if let first = firstHistogram, let second = secondHistogram {
            XCTAssertEqual(first.count, second.count, "Histogram dimensions should match")
            for i in 0..<first.count {
                XCTAssertEqual(first[i].count, second[i].count, "Row \(i) should have same length")
                for j in 0..<first[i].count {
                    XCTAssertEqual(first[i][j], second[i][j],
                                   "Bin [\(i)][\(j)] should be identical across runs")
                }
            }
        }
    }

    func testComputeGradientHistogramHandlesRapidSequentialCalls() {
        let expectations = (0..<5).map { expectation(description: "Sequential call \($0)") }

        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 1000)

        // Fire off multiple calls in quick succession
        for i in 0..<5 {
            calculator.computeGradientHistogram(
                for: texture,
                voxelMin: 0,
                voxelMax: 2000,
                gradientMin: 0.0,
                gradientMax: 1.0,
                intensityBins: 256,
                gradientBins: 256
            ) { result in
                switch result {
                case .success(let histogram):
                    XCTAssertEqual(histogram.count, 256)
                    let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                    XCTAssertEqual(totalSamples, UInt32(16 * 16 * 16))
                    expectations[i].fulfill()
                case .failure(let error):
                    XCTFail("Sequential call \(i) failed: \(error)")
                    expectations[i].fulfill()
                }
            }
        }

        wait(for: expectations, timeout: 10.0)
    }

    // MARK: - 2D Array Structure Tests

    func testHistogramReturns2DArrayStructure() {
        let expectation = expectation(description: "2D array structure")

        let texture = create3DTexture(width: 16, height: 16, depth: 16, fillValue: 1000)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 2000,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 128,
            gradientBins: 64
        ) { result in
            switch result {
            case .success(let histogram):
                // Outer array: intensity bins
                XCTAssertEqual(histogram.count, 128, "Should have 128 intensity bins")

                // Inner arrays: gradient bins
                for (i, gradientRow) in histogram.enumerated() {
                    XCTAssertEqual(gradientRow.count, 64,
                                   "Intensity bin \(i) should have 64 gradient bins")
                }

                // Verify access pattern: histogram[intensityBin][gradientBin]
                let sampleValue = histogram[64][32]
                XCTAssertGreaterThanOrEqual(sampleValue, 0, "Should be able to access histogram[64][32]")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testHistogramPreservesTotalSampleCount() {
        let expectation = expectation(description: "Total sample count preservation")

        let width = 32
        let height = 32
        let depth = 32
        let texture = create3DTexture(width: width, height: height, depth: depth, fillValue: 1000)

        calculator.computeGradientHistogram(
            for: texture,
            voxelMin: 0,
            voxelMax: 2000,
            gradientMin: 0.0,
            gradientMax: 1.0,
            intensityBins: 256,
            gradientBins: 256
        ) { result in
            switch result {
            case .success(let histogram):
                let totalSamples = histogram.flatMap { $0 }.reduce(0, +)
                let expectedSamples = width * height * depth

                XCTAssertEqual(totalSamples, UInt32(expectedSamples),
                               "Total histogram samples should equal total voxels")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Helper Methods

    private func create3DTexture(width: Int, height: Int, depth: Int, fillValue: UInt16) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create test texture")
        }

        // Fill texture with uniform value
        let totalVoxels = width * height * depth
        var data = [Int16](repeating: Int16(clamping: Int(fillValue)), count: totalVoxels)

        data.withUnsafeMutableBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: width, height: height, depth: depth)),
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * MemoryLayout<UInt16>.stride,
                bytesPerImage: width * height * MemoryLayout<UInt16>.stride
            )
        }

        return texture
    }

    private func createGradientTexture(width: Int, height: Int, depth: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create gradient texture")
        }

        // Create linear gradient along X axis
        var data = [Int16]()
        data.reserveCapacity(width * height * depth)
        let safeDenominator = Float(max(width - 1, 1))

        for _ in 0..<depth {
            for _ in 0..<height {
                for x in 0..<width {
                    let value = Int16((Float(x) / safeDenominator) * 4095.0)
                    data.append(value)
                }
            }
        }

        data.withUnsafeMutableBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: width, height: height, depth: depth)),
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * MemoryLayout<UInt16>.stride,
                bytesPerImage: width * height * MemoryLayout<UInt16>.stride
            )
        }

        return texture
    }
}
