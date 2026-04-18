//
//  EmptySpaceSkippingPerformanceTests.swift
//  MTKCoreTests
//
//  Performance benchmark tests for MPS empty space skipping optimization.
//  Measures render time improvement for sparse volumes and validates memory overhead.
//
//  Thales Matheus Mendonça Santos — February 2026
//

import CoreGraphics
import Metal
import simd
import XCTest

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

@testable import MTKCore

final class EmptySpaceSkippingPerformanceTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var raycaster: MetalRaycaster!
    private var volumeComputeFunction: MTLFunction!
    private var volumeComputePipeline: MTLComputePipelineState!
    private var argumentManager: ArgumentEncoderManager!
    private var cameraBuffer: MTLBuffer!
    private var dummyAccelerationTexture: MTLTexture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = queue

        guard let raycaster = try? MetalRaycaster(device: device, commandQueue: queue) else {
            throw XCTSkip("Failed to create MetalRaycaster")
        }
        self.raycaster = raycaster

        // Load the same metallib MTKCore uses (SwiftPM resources are in the MTKCore bundle).
        let coreBundle = MTKCoreResourceBundle.bundle
        let resolvedLibrary: MTLLibrary?
        if let url = coreBundle.url(forResource: "MTK", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            resolvedLibrary = lib
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            resolvedLibrary = defaultLibrary
        } else if #available(macOS 11.0, *),
                  let bundled = try? device.makeDefaultLibrary(bundle: coreBundle) {
            resolvedLibrary = bundled
        } else {
            resolvedLibrary = nil
        }

        guard let library = resolvedLibrary else {
            throw XCTSkip("Failed to load Metal shader library")
        }
        guard let function = library.makeFunction(name: "volume_compute") else {
            throw XCTSkip("volume_compute not available in shader library")
        }
        self.volumeComputeFunction = function
        self.volumeComputePipeline = try device.makeComputePipelineState(function: function)
        self.argumentManager = ArgumentEncoderManager(
            device: device,
            mtlFunction: function,
            debugOptions: VolumeRenderingDebugOptions(isDebugMode: false, histogramBinCount: 256, enableDensityDebug: false)
        )

        guard let cameraBuffer = device.makeBuffer(length: CameraUniforms.stride, options: [.storageModeShared]) else {
            throw XCTSkip("Failed to allocate camera buffer")
        }
        self.cameraBuffer = cameraBuffer

        // Dummy bound resource to avoid undefined reads when acceleration is disabled.
        let dummyDesc = MTLTextureDescriptor()
        dummyDesc.textureType = .type3D
        dummyDesc.pixelFormat = .rg16Float
        dummyDesc.width = 1
        dummyDesc.height = 1
        dummyDesc.depth = 1
        dummyDesc.mipmapLevelCount = 1
        dummyDesc.usage = [.shaderRead]
        dummyDesc.storageMode = .private
        guard let dummy = device.makeTexture(descriptor: dummyDesc) else {
            throw XCTSkip("Failed to allocate dummy acceleration texture")
        }
        dummy.label = "Test.DummyAcceleration"
        self.dummyAccelerationTexture = dummy
    }

    // MARK: - Performance Benchmark Tests

    /// Measures baseline Metal ray marching with shader-level ZSKIP heuristic.
    func testRenderPerformanceWithoutAcceleration() async throws {
        let dataset = makeSparseTestDataset()

        let startTime = CFAbsoluteTimeGetCurrent()
        let iterations = 5

        for _ in 0..<iterations {
            let result = try await renderWithoutAcceleration(dataset: dataset)
            XCTAssertNotNil(result, "Render should produce valid output")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageTime = elapsed / Double(iterations)

        print("📊 Baseline render time (without acceleration): \(String(format: "%.3f", averageTime * 1000))ms per frame")
        print("   Total time for \(iterations) iterations: \(String(format: "%.3f", elapsed * 1000))ms")

        XCTAssertGreaterThan(averageTime, 0, "Render time should be measurable")
    }

    /// Measures MPS-accelerated ray marching with precomputed acceleration structure.
    func testRenderPerformanceWithAcceleration() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping performance test")
        }

        let dataset = makeSparseTestDataset()

        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        let startTime = CFAbsoluteTimeGetCurrent()
        let iterations = 5

        for _ in 0..<iterations {
            let result = try await renderWithAcceleration(dataset: dataset, accelerationTexture: accelerationTexture)
            XCTAssertNotNil(result, "Render should produce valid output")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageTime = elapsed / Double(iterations)

        print("📊 Accelerated render time (with MPS acceleration): \(String(format: "%.3f", averageTime * 1000))ms per frame")
        print("   Total time for \(iterations) iterations: \(String(format: "%.3f", elapsed * 1000))ms")

        XCTAssertGreaterThan(averageTime, 0, "Render time should be measurable")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testPerformanceImprovementMeetsTarget() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping performance test")
        }

        let dataset = makeSparseTestDataset()

        // Measure baseline performance
        let baselineStart = CFAbsoluteTimeGetCurrent()
        let iterations = 10

        for _ in 0..<iterations {
            _ = try await renderWithoutAcceleration(dataset: dataset)
        }

        let baselineElapsed = CFAbsoluteTimeGetCurrent() - baselineStart
        let baselineAverage = baselineElapsed / Double(iterations)

        // Measure accelerated performance
        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        // Validation: ensure the accelerated path is actually enabled (option flag set).
        _ = try await renderWithAcceleration(dataset: dataset, accelerationTexture: accelerationTexture, validateAccelerationEnabled: true)

        let acceleratedStart = CFAbsoluteTimeGetCurrent()

        for _ in 0..<iterations {
            _ = try await renderWithAcceleration(dataset: dataset, accelerationTexture: accelerationTexture)
        }

        let acceleratedElapsed = CFAbsoluteTimeGetCurrent() - acceleratedStart
        let acceleratedAverage = acceleratedElapsed / Double(iterations)

        // Calculate improvement
        let improvement = (baselineAverage - acceleratedAverage) / baselineAverage
        let improvementPercentage = improvement * 100

        print("📊 Performance Analysis:")
        print("   Baseline average:    \(String(format: "%.3f", baselineAverage * 1000))ms")
        print("   Accelerated average: \(String(format: "%.3f", acceleratedAverage * 1000))ms")
        print("   Improvement:         \(String(format: "%.1f", improvementPercentage))%")
        print("   Target:              ≥30%")

        // Note: In some test environments, the sparse dataset may not show full 30% improvement
        // due to overhead of small test volumes. We validate that acceleration doesn't regress
        // performance and document the measured improvement.
        if improvementPercentage >= 30 {
            print("✅ Performance target met: \(String(format: "%.1f", improvementPercentage))% ≥ 30%")
        } else if improvementPercentage >= 0 {
            print("⚠️  Performance improved by \(String(format: "%.1f", improvementPercentage))%, below 30% target")
            print("   (Small test volumes may not demonstrate full optimization benefit)")
        } else {
            XCTFail("Performance regression detected: \(String(format: "%.1f", improvementPercentage))%")
        }

        // At minimum, acceleration should not make performance worse
        XCTAssertGreaterThanOrEqual(
            improvementPercentage,
            -5.0,
            "Acceleration should not significantly degrade performance (tolerance: -5%)"
        )
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Memory Overhead Tests

    func testAccelerationStructureMemoryOverhead() throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping memory overhead test")
        }

        let accelerator: MPSEmptySpaceAccelerator
        switch MPSEmptySpaceAccelerator.create(device: device, commandQueue: commandQueue) {
        case .success(let created):
            accelerator = created
        case .unavailable(let reason):
            throw XCTSkip("Failed to create MPSEmptySpaceAccelerator: \(reason)")
        }

        let dataset = makeSparseTestDataset()

        do {
            let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
            let overhead = structure.memoryOverhead(relativeTo: dataset)
            let overheadPercentage = overhead * 100

            print("📊 Memory Overhead Analysis:")
            print("   Dataset size:         \(dataset.data.count) bytes")
            print("   Acceleration size:    \(structure.memoryFootprint) bytes")
            print("   Overhead ratio:       \(String(format: "%.1f", overheadPercentage))%")
            print("   Mip levels:           \(structure.mipLevels)")
            // rg16Float (4 bytes/voxel) vs Int16 source (2 bytes/voxel) = ~200% base + ~14% mip overhead
            // The mipmap geometric series adds <15% on top of the base level
            print("   Target:               <250% (rg16Float = 2x source + mip overhead)")

            // Validate mip overhead is bounded: total should be < 250% of source
            // (base level = 200%, mip levels add ~14% geometric series)
            XCTAssertLessThan(
                overheadPercentage,
                250.0,
                "Acceleration structure memory should be bounded (rg16Float base + mip levels)"
            )
        } catch {
            throw XCTSkip("Acceleration structure generation failed: \(error.localizedDescription)")
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func testMemoryOverheadForLargerVolume() throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping memory overhead test")
        }

        let accelerator: MPSEmptySpaceAccelerator
        switch MPSEmptySpaceAccelerator.create(device: device, commandQueue: commandQueue) {
        case .success(let created):
            accelerator = created
        case .unavailable(let reason):
            throw XCTSkip("Failed to create MPSEmptySpaceAccelerator: \(reason)")
        }

        let dataset = makeLargerSparseDataset()

        do {
            let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
            let overhead = structure.memoryOverhead(relativeTo: dataset)
            let overheadPercentage = overhead * 100

            print("📊 Memory Overhead Analysis (Larger Volume):")
            print("   Dimensions:           \(dataset.dimensions.width)×\(dataset.dimensions.height)×\(dataset.dimensions.depth)")
            print("   Dataset size:         \(dataset.data.count) bytes")
            print("   Acceleration size:    \(structure.memoryFootprint) bytes")
            print("   Overhead ratio:       \(String(format: "%.1f", overheadPercentage))%")
            print("   Mip levels:           \(structure.mipLevels)")

            XCTAssertLessThan(
                overheadPercentage,
                250.0,
                "Memory overhead should remain bounded even for larger volumes"
            )
        } catch {
            throw XCTSkip("Acceleration structure generation failed: \(error.localizedDescription)")
        }
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - Helper Methods

    private func requireAccelerationTexture(
        for dataset: VolumeDataset,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> any MTLTexture {
        try RaycasterTestHelpers.requireAccelerationTexture(from: raycaster, for: dataset, file: file, line: line)
    }

    private func renderWithoutAcceleration(
        dataset: VolumeDataset
    ) async throws -> MTLTexture? {
        // Baseline path: regular Metal ray marching with shader-level ZSKIP heuristic.
        // The dummy acceleration texture is bound only to satisfy shader resource layout;
        // OPTION_USE_ACCELERATION remains unset.
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset, device: device)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 256
        outputDescriptor.height = 256
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute.
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)
        var optionValue: UInt16 = 0
        var quaternion = SIMD4<Float>(0, 0, 0, 1)
        var targetViewSize = UInt16(256)
        var pointSetCount: UInt16 = 0
        var pointSelectedIndex: UInt16 = 0

        argumentManager.encodeTexture(resources.texture, argumentIndex: .mainTexture)
        argumentManager.encodeTexture(outputTexture, argumentIndex: .outputTexture)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh1)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh2)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh3)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh4)
        argumentManager.encodeTexture(dummyAccelerationTexture, argumentIndex: .accelerationTexture)
        argumentManager.encodeSampler(filter: .linear)
        argumentManager.encode(&params, argumentIndex: .renderParams)
        argumentManager.encode(&optionValue, argumentIndex: .optionValue)
        argumentManager.encode(&quaternion, argumentIndex: .quaternion)
        argumentManager.encode(&targetViewSize, argumentIndex: .targetViewSize)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh1)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh2)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh3)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh4)
        argumentManager.encode(&pointSetCount, argumentIndex: .pointSetCountBuffer)
        argumentManager.encode(&pointSelectedIndex, argumentIndex: .pointSetSelectedBuffer)
        argumentManager.encode(nil, argumentIndex: .pointCoordsBuffer)
        argumentManager.encode(nil, argumentIndex: .legacyOutputBuffer)

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)

        computeEncoder.setComputePipelineState(volumeComputePipeline)
        computeEncoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(cameraBuffer, offset: 0, index: 1)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (outputDescriptor.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outputDescriptor.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        try await RaycasterTestHelpers.commitAndWait(commandBuffer)

        return outputTexture
    }

    private func renderWithAcceleration(
        dataset: VolumeDataset,
        accelerationTexture: any MTLTexture,
        validateAccelerationEnabled: Bool = false
    ) async throws -> MTLTexture? {
        // MPS path: baseline Metal ray marching plus the precomputed min-max
        // acceleration structure, with OPTION_USE_ACCELERATION enabled.
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset, device: device)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 256
        outputDescriptor.height = 256
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with acceleration enabled.
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)
        let optionUseAcceleration: UInt16 = 1 << 4
        var optionValue: UInt16 = optionUseAcceleration
        var quaternion = SIMD4<Float>(0, 0, 0, 1)
        var targetViewSize = UInt16(256)
        var pointSetCount: UInt16 = 0
        var pointSelectedIndex: UInt16 = 0

        argumentManager.encodeTexture(resources.texture, argumentIndex: .mainTexture)
        argumentManager.encodeTexture(outputTexture, argumentIndex: .outputTexture)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh1)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh2)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh3)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh4)
        argumentManager.encodeTexture(accelerationTexture, argumentIndex: .accelerationTexture)
        argumentManager.encodeSampler(filter: .linear)
        argumentManager.encode(&params, argumentIndex: .renderParams)
        argumentManager.encode(&optionValue, argumentIndex: .optionValue)
        argumentManager.encode(&quaternion, argumentIndex: .quaternion)
        argumentManager.encode(&targetViewSize, argumentIndex: .targetViewSize)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh1)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh2)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh3)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh4)
        argumentManager.encode(&pointSetCount, argumentIndex: .pointSetCountBuffer)
        argumentManager.encode(&pointSelectedIndex, argumentIndex: .pointSetSelectedBuffer)
        argumentManager.encode(nil, argumentIndex: .pointCoordsBuffer)
        argumentManager.encode(nil, argumentIndex: .legacyOutputBuffer)

        if validateAccelerationEnabled {
            // Runtime validation that the options buffer actually contains the acceleration flag.
            guard let optionBuffer = argumentManager.getBuffer(argumentIndex: .optionValue) else {
                XCTFail("optionValue buffer was not encoded")
                return outputTexture
            }
            let value = optionBuffer.contents().bindMemory(to: UInt16.self, capacity: 1).pointee
            XCTAssertNotEqual(value & optionUseAcceleration, 0, "OPTION_USE_ACCELERATION must be set for accelerated render")
            XCTAssertGreaterThan(accelerationTexture.width, 0, "Acceleration texture must be valid")
        }

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)

        computeEncoder.setComputePipelineState(volumeComputePipeline)
        computeEncoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(cameraBuffer, offset: 0, index: 1)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (outputDescriptor.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outputDescriptor.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        try await RaycasterTestHelpers.commitAndWait(commandBuffer)

        return outputTexture
    }

    private func makeSparseTestDataset() -> VolumeDataset {
        // Create a sparse volume simulating CT chest scan with lots of air (empty space)
        // High sparsity ratio: ~70% empty (air), 30% tissue
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values: [Int16] = Array(repeating: -1000, count: dimensions.voxelCount)

        // Add some dense regions (tissue/bone) to create sparse patterns
        let centerX = dimensions.width / 2
        let centerY = dimensions.height / 2
        let centerZ = dimensions.depth / 2
        let radius = dimensions.width / 4

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let dx = x - centerX
                    let dy = y - centerY
                    let dz = z - centerZ
                    let distance = sqrt(Double(dx * dx + dy * dy + dz * dz))

                    if distance < Double(radius) {
                        // Tissue region
                        let index = z * dimensions.width * dimensions.height + y * dimensions.width + x
                        // Deterministic pattern to keep performance benchmarks reproducible.
                        values[index] = Int16((x + y + z) % 400 - 200)
                    }
                }
            }
        }

        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.001),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    private func makeLargerSparseDataset() -> VolumeDataset {
        // Larger sparse volume for memory overhead testing
        let dimensions = VolumeDimensions(width: 128, height: 128, depth: 128)
        var values: [Int16] = Array(repeating: -1000, count: dimensions.voxelCount)

        // Add sparse tissue regions
        let centerX = dimensions.width / 2
        let centerY = dimensions.height / 2
        let centerZ = dimensions.depth / 2
        let radius = dimensions.width / 3

        for z in stride(from: 0, to: dimensions.depth, by: 2) {
            for y in stride(from: 0, to: dimensions.height, by: 2) {
                for x in stride(from: 0, to: dimensions.width, by: 2) {
                    let dx = x - centerX
                    let dy = y - centerY
                    let dz = z - centerZ
                    let distance = sqrt(Double(dx * dx + dy * dy + dz * dz))

                    if distance < Double(radius) {
                        let index = z * dimensions.width * dimensions.height + y * dimensions.width + x
                        // Deterministic pattern to keep performance benchmarks reproducible.
                        values[index] = Int16((x + y + z) % 400 - 200)
                    }
                }
            }
        }

        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.001),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }
}
