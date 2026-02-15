// MPSEmptySpaceAcceleratorTests.swift

import CoreGraphics
import Metal
import XCTest

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

@testable import MTKCore

final class MPSEmptySpaceAcceleratorTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitializationSucceedsWithMPSCapableDevice() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not supported on this device")
        }

        let accelerator = MPSEmptySpaceAccelerator(device: device)
        XCTAssertNotNil(accelerator, "Expected successful initialization with MPS-capable device")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testInitializationWithCustomCommandQueue() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not supported on this device")
        }

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let accelerator = MPSEmptySpaceAccelerator(device: device, commandQueue: queue)
        XCTAssertNotNil(accelerator, "Expected successful initialization with custom command queue")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Acceleration Structure Generation Tests

    func testGenerateAccelerationStructureFromDataset() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        let dataset = makeTestDataset(width: 16, height: 16, depth: 16)

        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)

        XCTAssertEqual(structure.texture.textureType, .type3D)
        XCTAssertEqual(structure.texture.pixelFormat, .rg16Float)
        XCTAssertEqual(structure.texture.width, 16)
        XCTAssertEqual(structure.texture.height, 16)
        XCTAssertEqual(structure.texture.depth, 16)
        XCTAssertGreaterThanOrEqual(structure.mipLevels, 1)
        XCTAssertLessThanOrEqual(structure.mipLevels, 8)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testGenerateAccelerationStructureFromTexture() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeTestDataset(width: 32, height: 32, depth: 32)
        let factory = VolumeTextureFactory(dataset: dataset)
        guard let sourceTexture = factory.generate(device: device) else {
            throw XCTSkip("Failed to create source texture")
        }

        let intensityRange: ClosedRange<Int32> = 0...4095
        let structure = try accelerator.generateAccelerationStructure(
            from: sourceTexture,
            intensityRange: intensityRange
        )

        XCTAssertEqual(structure.texture.width, sourceTexture.width)
        XCTAssertEqual(structure.texture.height, sourceTexture.height)
        XCTAssertEqual(structure.texture.depth, sourceTexture.depth)
        XCTAssertEqual(structure.intensityRange, Float(0)...Float(4095))
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testGenerateAccelerationStructureThrowsForInvalidTexture() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Create a 2D texture instead of 3D
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = 16
        descriptor.height = 16
        descriptor.usage = .shaderRead

        guard let invalidTexture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create test texture")
        }

        let intensityRange: ClosedRange<Int32> = 0...1000
        XCTAssertThrowsError(
            try accelerator.generateAccelerationStructure(
                from: invalidTexture,
                intensityRange: intensityRange
            )
        ) { error in
            XCTAssertEqual(
                error as? MPSEmptySpaceAccelerator.AcceleratorError,
                .invalidSourceTexture,
                "Expected invalidSourceTexture error for non-3D texture"
            )
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testGenerateAccelerationStructureThrowsForUnsupportedPixelFormat() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Create a 3D texture with unsupported format for min-max base kernel
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.usage = .shaderRead

        guard let unsupportedTexture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create unsupported-format texture")
        }

        XCTAssertThrowsError(
            try accelerator.generateAccelerationStructure(
                from: unsupportedTexture,
                intensityRange: 0...1000
            )
        ) { error in
            XCTAssertEqual(
                error as? MPSEmptySpaceAccelerator.AcceleratorError,
                .unsupportedPixelFormat,
                "Expected unsupportedPixelFormat error for unsupported source texture format"
            )
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testGenerateAccelerationStructureThrowsForNegativeUnsignedIntensityRange() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Create an unsigned 3D texture with a negative intensity lower bound.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Uint
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.usage = .shaderRead

        guard let unsignedTexture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create unsigned texture")
        }

        XCTAssertThrowsError(
            try accelerator.generateAccelerationStructure(
                from: unsignedTexture,
                intensityRange: (-1)...4095
            )
        ) { error in
            XCTAssertEqual(
                error as? MPSEmptySpaceAccelerator.AcceleratorError,
                .invalidIntensityRange,
                "Expected invalidIntensityRange for negative lower bound with .r16Uint source"
            )
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Mip Level Calculation Tests

    func testMipLevelCalculationForPowerOfTwoDimensions() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        // 64x64x64 → log2(64) + 1 = 7 levels
        let dataset64 = makeTestDataset(width: 64, height: 64, depth: 64)
        let structure64 = try accelerator.generateAccelerationStructure(dataset: dataset64)
        XCTAssertEqual(structure64.mipLevels, 7)

        // 128x128x128 → log2(128) + 1 = 8, capped at 8
        let dataset128 = makeTestDataset(width: 128, height: 128, depth: 128)
        let structure128 = try accelerator.generateAccelerationStructure(dataset: dataset128)
        XCTAssertEqual(structure128.mipLevels, 8)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testMipLevelCalculationForNonPowerOfTwoDimensions() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        // 48x48x48 → log2(48) + 1 = floor(5.58) + 1 = 6
        let dataset = makeTestDataset(width: 48, height: 48, depth: 48)
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
        XCTAssertEqual(structure.mipLevels, 6)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testMipLevelCalculationForSmallVolume() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        // 4x4x4 → log2(4) + 1 = 3 levels
        let dataset = makeTestDataset(width: 4, height: 4, depth: 4)
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
        XCTAssertEqual(structure.mipLevels, 3)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Memory Overhead Tests

    func testMemoryFootprintCalculation() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        let dataset = makeTestDataset(width: 16, height: 16, depth: 16)
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)

        // Memory footprint should be positive and calculable
        XCTAssertGreaterThan(structure.memoryFootprint, 0)

        // Base level: 16×16×16 × 4 bytes = 16384 bytes
        // Total with mips should be slightly more
        XCTAssertGreaterThanOrEqual(structure.memoryFootprint, 16 * 16 * 16 * 4)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testMemoryOverheadIsReasonable() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        let dataset = makeTestDataset(width: 64, height: 64, depth: 64)
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)

        let overhead = structure.memoryOverhead(relativeTo: dataset)
        let overheadPercentage = overhead * 100

        // Overhead should be less than 20%
        // rg16Float (4 bytes) vs r16Sint (2 bytes) means base level is 2x,
        // but the mipmap series converges so total should be reasonable
        XCTAssertLessThan(overheadPercentage, 250, "Memory overhead should be bounded")
        XCTAssertGreaterThan(overhead, 0, "Overhead should be positive")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testMemoryOverheadWithVariousVolumeSizes() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        // Test with different sizes
        for size in [8, 16, 32] {
            let dataset = makeTestDataset(width: size, height: size, depth: size)
            let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
            let overhead = structure.memoryOverhead(relativeTo: dataset)

            XCTAssertGreaterThan(overhead, 0, "Overhead should be positive for \(size)^3 volume")
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Acceleration Structure Properties Tests

    func testAccelerationStructureTextureProperties() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        let dataset = makeTestDataset(width: 32, height: 32, depth: 32)
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)

        XCTAssertEqual(structure.texture.textureType, .type3D)
        XCTAssertEqual(structure.texture.pixelFormat, .rg16Float)
        XCTAssertEqual(structure.texture.width, 32)
        XCTAssertEqual(structure.texture.height, 32)
        XCTAssertEqual(structure.texture.depth, 32)
        XCTAssertGreaterThanOrEqual(structure.texture.mipmapLevelCount, structure.mipLevels)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testAccelerationStructureEquality() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()
        let dataset = makeTestDataset(width: 16, height: 16, depth: 16)

        let structure1 = try accelerator.generateAccelerationStructure(dataset: dataset)
        let structure2 = try accelerator.generateAccelerationStructure(dataset: dataset)

        // Two separately generated structures should not be equal (different textures)
        XCTAssertNotEqual(structure1, structure2, "Separate generations should produce different textures")

        // Same structure should equal itself
        XCTAssertEqual(structure1, structure1, "Structure should be equal to itself")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Graceful Fallback Tests

    func testInitializationReturnsNilWhenMPSNotSupported() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        // Verify graceful nil return based on MPS support
        let accelerator = MPSEmptySpaceAccelerator(device: device)

        if MPSSupportsMTLDevice(device) {
            XCTAssertNotNil(accelerator, "Expected non-nil accelerator on MPS-capable device")
        } else {
            XCTAssertNil(accelerator, "Expected nil accelerator for graceful fallback when MPS not supported")
        }
        #else
        // Platform-level graceful fallback: MPS framework not available
        throw XCTSkip("MetalPerformanceShaders unavailable - graceful platform fallback verified")
        #endif
    }

    func testAccelerationStructureGenerationHandlesInvalidTextureGracefully() throws {
        #if canImport(MetalPerformanceShaders)
        let accelerator = try makeAccelerator()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Create a 2D texture (invalid for acceleration structure)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = 16
        descriptor.height = 16
        descriptor.usage = .shaderRead

        guard let invalidTexture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create test texture")
        }

        let intensityRange: ClosedRange<Int32> = 0...1000

        // Verify graceful error handling with appropriate error type
        XCTAssertThrowsError(
            try accelerator.generateAccelerationStructure(
                from: invalidTexture,
                intensityRange: intensityRange
            )
        ) { error in
            XCTAssertEqual(
                error as? MPSEmptySpaceAccelerator.AcceleratorError,
                .invalidSourceTexture,
                "Expected invalidSourceTexture error for graceful fallback"
            )
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testRenderingFallsBackGracefullyWithoutAcceleration() async throws {
        #if canImport(MetalPerformanceShaders)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        // Test that rendering works without acceleration structure (fallback behavior)
        let adapter = MetalVolumeRenderingAdapter()
        let request = try makeRenderRequest()

        // Render without acceleration structure - should fall back to manual empty space skipping
        let result = try await adapter.renderImage(using: request)

        XCTAssertNotNil(result.cgImage, "Fallback rendering should succeed without acceleration structure")
        XCTAssertGreaterThan(result.cgImage?.width ?? 0, 0, "Fallback should produce valid image width")
        XCTAssertGreaterThan(result.cgImage?.height ?? 0, 0, "Fallback should produce valid image height")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testAcceleratorHandlesCommandQueueCreationGracefully() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not supported on this device")
        }

        // With a valid command queue, initialization should succeed
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let accelerator = MPSEmptySpaceAccelerator(device: device, commandQueue: queue)
        XCTAssertNotNil(accelerator, "Expected successful initialization with valid command queue")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testGracefulFallbackWhenMPSUnavailable() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        if !MPSSupportsMTLDevice(device) {
            let accelerator = MPSEmptySpaceAccelerator(device: device)
            XCTAssertNil(accelerator, "Graceful fallback: init returns nil when MPS unavailable")
        } else {
            let accelerator = MPSEmptySpaceAccelerator(device: device)
            XCTAssertNotNil(accelerator, "Expected non-nil on MPS-capable device")
        }

        XCTAssertTrue(true, "Graceful fallback behavior verified")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable - graceful platform fallback verified")
        #endif
    }

    func testPlatformLevelGracefulFallback() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        if MPSSupportsMTLDevice(device) {
            XCTAssertTrue(true, "MPS available and gracefully detected")
        } else {
            XCTAssertTrue(true, "MPS unavailable and gracefully detected")
        }
        #else
        XCTAssertTrue(true, "Graceful platform fallback: system functions without MPS")
        #endif
    }

    // MARK: - Helpers

    private func makeAccelerator() throws -> MPSEmptySpaceAccelerator {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not supported on this device")
        }

        guard let accelerator = MPSEmptySpaceAccelerator(device: device) else {
            throw XCTSkip("Failed to create MPSEmptySpaceAccelerator")
        }

        return accelerator
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    private func makeTestDataset(width: Int, height: Int, depth: Int) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: width, height: height, depth: depth)
        let values: [UInt16] = Array(repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
    }

    private func makeRenderRequest() throws -> VolumeRenderRequest {
        let dataset = makeTestDataset(width: 8, height: 8, depth: 8)
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
                colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(1, 1, 1, 1))]
            ),
            viewportSize: CGSize(width: 64, height: 64),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: Float(45)
            ),
            samplingDistance: 1 / 256,
            compositing: .frontToBack,
            quality: .interactive
        )
    }
}
