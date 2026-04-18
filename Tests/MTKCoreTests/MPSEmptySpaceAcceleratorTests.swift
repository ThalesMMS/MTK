// MPSEmptySpaceAcceleratorTests.swift

import CoreGraphics
import Metal
import OSLog
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
            throw XCTSkip("MPS acceleration is unsupported on this device; shared generation APIs should report .unavailable(.mpsUnsupportedOnDevice)")
        }

        switch MPSEmptySpaceAccelerator.create(device: device) {
        case .success:
            break
        case .unavailable(let reason):
            throw XCTSkip("Accelerator setup unavailable on this device: \(reason)")
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
        #endif
    }

    func testInitializationWithCustomCommandQueue() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS acceleration is unsupported on this device; shared generation APIs should report .unavailable(.mpsUnsupportedOnDevice)")
        }

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        switch MPSEmptySpaceAccelerator.create(device: device, commandQueue: queue) {
        case .success:
            break
        case .unavailable(let reason):
            throw XCTSkip("Accelerator setup unavailable with custom command queue: \(reason)")
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
        #endif
    }

    // MARK: - MPS Availability Contract Tests

    func testGenerateTextureUsesExplicitAvailabilityResult() throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let result = MPSEmptySpaceAccelerator.generateTexture(
            device: device,
            commandQueue: commandQueue,
            dataset: makeTestDataset(width: 8, height: 8, depth: 8),
            logger: Logger(subsystem: "MTKCoreTests", category: "MPSEmptySpaceAcceleratorTests")
        )

        if MPSSupportsMTLDevice(device) {
            guard case .success(let texture) = result else {
                XCTFail("Expected .success on an MPS-capable device, got \(String(describing: result))")
                return
            }
            XCTAssertGreaterThan(texture.width, 0, "Expected a valid acceleration texture")
        } else {
            guard case .unavailable(let reason) = result else {
                XCTFail("Expected .unavailable when MPS is unsupported, got \(String(describing: result))")
                return
            }
            XCTAssertEqual(reason, .mpsUnsupportedOnDevice)
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
        #endif
    }

    func testRenderingSucceedsWithoutMPSAccelerationStructure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let request = try makeRenderRequest()

        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("Metal raycaster unavailable: \(error)")
        }

        let accelerationResult = raycaster.prepareAccelerationStructure(dataset: request.dataset)
        if raycaster.isMetalPerformanceShadersAvailable {
            guard case .success(let texture) = accelerationResult else {
                XCTFail("Expected .success when MPS is available, got \(String(describing: accelerationResult))")
                return
            }
            XCTAssertGreaterThan(texture.width, 0, "Expected a valid acceleration texture")
        } else {
            guard case .unavailable(let reason) = accelerationResult else {
                XCTFail("Expected .unavailable when MPS is unsupported, got \(String(describing: accelerationResult))")
                return
            }
            XCTAssertEqual(reason, .mpsUnsupportedOnDevice)
        }

        let resources = try raycaster.prepare(
            dataset: request.dataset,
            includeAccelerationStructure: false
        )
        XCTAssertNil(
            resources.accelerationTexture,
            "Expected no acceleration texture when MPS acceleration is not requested"
        )

        let adapter: MetalVolumeRenderingAdapter
        do {
            adapter = try MetalVolumeRenderingAdapter(device: device)
        } catch let error as MetalVolumeRenderingAdapter.InitializationError {
            throw XCTSkip("Metal volume renderer unavailable: \(error.localizedDescription)")
        }

        let result = try await adapter.renderImage(using: request)
        let cgImage = try XCTUnwrap(
            result.cgImage,
            "The Metal-only rendering path should still produce output when acceleration is not requested"
        )

        XCTAssertGreaterThan(
            cgImage.width,
            0,
            "The Metal-only rendering path should still produce output when acceleration is not requested"
        )
        XCTAssertGreaterThan(
            cgImage.height,
            0,
            "The Metal-only rendering path should still produce output when acceleration is not requested"
        )
    }

    // MARK: - Helpers

    private func makeAccelerator() throws -> MPSEmptySpaceAccelerator {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS acceleration is unsupported on this device; shared generation APIs should report .unavailable(.mpsUnsupportedOnDevice)")
        }

        switch MPSEmptySpaceAccelerator.create(device: device) {
        case .success(let accelerator):
            return accelerator
        case .unavailable(let reason):
            throw XCTSkip("Failed to create MPSEmptySpaceAccelerator: \(reason)")
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; shared generation APIs would report .unavailable")
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
            pixelFormat: .int16Unsigned,
            recommendedWindow: 0...4095
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
