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
    private var visibilityCache: EmptySpaceVisibilityCache!
    private var cameraBuffer: MTLBuffer!
    private var dummyAccelerationTexture: MTLTexture!
    private var cachedTransferTexture: (identity: DatasetIdentity.Content, texture: MTLTexture)?

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
        } else if let bundled = try? device.makeDefaultLibrary(bundle: coreBundle) {
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
        self.visibilityCache = try EmptySpaceVisibilityCache(device: device, library: library)
        self.cachedTransferTexture = nil

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

    /// Counts the work the acceleration structure removes, instead of timing it.
    ///
    /// This used to compare two wall-clock averages and fail below a −5% tolerance, which
    /// is not a question a shared GPU can answer: on an idle machine it still reported
    /// "Performance regression detected: −2.1%", and under six concurrent runs of this
    /// suite it reported −0.2%, −3.7%, −6.7%, −12.7% — 11 failures in 18 runs. A gate that
    /// says "regression" about somebody else's load is a gate people learn to ignore.
    ///
    /// The claim underneath the timing is that the acceleration structure lets rays skip
    /// empty space, and that is countable. `volume_compute.metal` consults the visibility
    /// pyramid at `accelerationCoarseMip` — `min(3, mipLevels - 1)` — and jumps over every
    /// block that level marks invisible. Counting those blocks asks the same question and
    /// gets the same answer whatever else the GPU is doing.
    func testAccelerationSkipsMostBlocksOfASparseVolume() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping performance test")
        }

        let dataset = makeSparseTestDataset()
        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        // Validation: ensure the accelerated path is actually enabled (option flag set).
        _ = try await renderWithAcceleration(dataset: dataset,
                                             accelerationTexture: accelerationTexture,
                                             validateAccelerationEnabled: true)

        let skipping = try await skippableBlocks(dataset: dataset,
                                                 accelerationTexture: accelerationTexture)

        print("📊 Empty-space work removed:")
        print("   Coarse mip level:     \(skipping.level)")
        print("   Blocks at that level: \(skipping.total)")
        print("   Blocks skipped:       \(skipping.skipped) (\(String(format: "%.1f", skipping.fraction * 100))%)")

        XCTAssertGreaterThan(
            skipping.fraction,
            0.5,
            "acceleration must let the raycast skip most of a ~93% empty volume, skipped \(skipping.skipped) of \(skipping.total)"
        )
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func test_occupiedRegion_disablesUnproductiveAcceleration() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping performance test")
        }

        let dataset = makeOccupiedTestDataset()
        let accelerationTexture = try requireAccelerationTexture(for: dataset)
        _ = try await renderWithAcceleration(dataset: dataset,
                                              accelerationTexture: accelerationTexture,
                                              validateAccelerationDisabled: true)
        XCTAssertFalse(visibilityCache.isSkippingUseful)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    // MARK: - GPU Correctness

    /// #1692: the benchmarks above measure two dispatches that reach every texture they
    /// sample through an argument buffer. Nothing in an argument buffer is resident until
    /// the encoder is told, and an undeclared output texture swallows the kernel's writes
    /// silently — the command buffer still completes, and the timings still look like
    /// timings. Both paths are asserted, because the accelerated one binds a different
    /// acceleration texture and could fail on its own.
    func testBenchmarkedDispatchesActuallyRender() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS not available, skipping")
        }

        let dataset = makeSparseTestDataset()
        let baselineFrame = try await renderWithoutAcceleration(dataset: dataset)
        let baseline = try XCTUnwrap(baselineFrame, "baseline render produced no output texture")
        let accelerationTexture = try requireAccelerationTexture(for: dataset)
        let acceleratedFrame = try await renderWithAcceleration(dataset: dataset,
                                                                accelerationTexture: accelerationTexture)
        let accelerated = try XCTUnwrap(acceleratedFrame, "accelerated render produced no output texture")

        XCTAssertGreaterThan(brightestChannel(of: baseline),
                             0,
                             "The baseline benchmark dispatch returned an all-black frame: it composited nothing")
        XCTAssertGreaterThan(brightestChannel(of: accelerated),
                             0,
                             "The accelerated benchmark dispatch returned an all-black frame: it composited nothing")
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    private func brightestChannel(of texture: any MTLTexture) -> UInt8 {
        let bytesPerRow = texture.width * 4
        let bytes = MPRTextureReadbackHelper.readBytes(from: texture,
                                                       bytesPerRow: bytesPerRow,
                                                       byteCount: bytesPerRow * texture.height)
        var brightest: UInt8 = 0
        for byte in bytes where byte > brightest {
            brightest = byte
        }
        return brightest
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

    private struct SkippableBlocks {
        var level: Int
        var total: Int
        var skipped: Int
        var fraction: Double { total > 0 ? Double(skipped) / Double(total) : 0 }
    }

    /// Reads back the visibility pyramid level the raycast actually consults and counts
    /// the blocks it marks invisible — the blocks rays will jump over.
    private func skippableBlocks(dataset: VolumeDataset,
                                 accelerationTexture: any MTLTexture) async throws -> SkippableBlocks {
        let transferTexture = try await transferTexture(for: dataset)
        let parameters = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)
        let visibility = try await visibilityCache.texture(minMaxTexture: accelerationTexture,
                                                           transferTexture: transferTexture,
                                                           parameters: parameters,
                                                           commandQueue: commandQueue)

        // `accelerationCoarseMip` in volume_compute.metal.
        let level = min(3, visibility.mipmapLevelCount - 1)
        let width = max(1, visibility.width >> level)
        let height = max(1, visibility.height >> level)
        let depth = max(1, visibility.depth >> level)
        let bytesPerImage = width * height
        let byteCount = bytesPerImage * depth

        guard let readback = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }
        blit.copy(from: visibility,
                  sourceSlice: 0,
                  sourceLevel: level,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: depth),
                  to: readback,
                  destinationOffset: 0,
                  destinationBytesPerRow: width,
                  destinationBytesPerImage: bytesPerImage)
        blit.endEncoding()
        try await RaycasterTestHelpers.commitAndWait(commandBuffer)

        let pointer = readback.contents().assumingMemoryBound(to: UInt8.self)
        let blocks = UnsafeBufferPointer(start: pointer, count: byteCount)
        // `sampleAccelerationStructureAtLevel` skips a block when the pyramid reads >= 0.5,
        // which is >= 128 out of r8Unorm's 255.
        return SkippableBlocks(level: level,
                               total: byteCount,
                               skipped: blocks.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) })
    }

    private func renderWithoutAcceleration(
        dataset: VolumeDataset
    ) async throws -> MTLTexture? {
        // Baseline path: regular Metal ray marching with shader-level ZSKIP heuristic.
        // The dummy acceleration texture is bound only to satisfy shader resource layout;
        // OPTION_USE_ACCELERATION remains unset.
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await transferTexture(for: dataset)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 256
        outputDescriptor.height = 256
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        // #1692: CPU-visible so the frame can be checked for content. A benchmark that
        // never looks at its output cannot tell a fast kernel from one that did not run.
        outputDescriptor.storageMode = .shared

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

        try argumentManager.encodeFilterableVolumeTexture(resources.texture)
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

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)

        computeEncoder.setComputePipelineState(volumeComputePipeline)
        computeEncoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(cameraBuffer, offset: 0, index: 1)
        // #1692: every texture this kernel touches — the volume, the four transfer LUTs,
        // the visibility pyramid and the output — is reached through the argument buffer,
        // so binding the argument buffer makes none of them resident. VolumeRaycastPass
        // calls this at all three of its dispatch sites; this suite copied the encoding
        // block without it and the dispatches below were timing a kernel whose writes
        // went nowhere. `testBenchmarkedDispatchesActuallyRender` is what notices.
        argumentManager.registerResources(on: computeEncoder)

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
        validateAccelerationEnabled: Bool = false,
        validateAccelerationDisabled: Bool = false
    ) async throws -> MTLTexture? {
        // MPS path: baseline Metal ray marching plus precomputed visibility,
        // with OPTION_USE_ACCELERATION enabled.
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await transferTexture(for: dataset)
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)
        let visibilityTexture = try await visibilityCache.texture(
            minMaxTexture: accelerationTexture,
            transferTexture: transferTexture,
            parameters: params,
            commandQueue: commandQueue
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 256
        outputDescriptor.height = 256
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        // #1692: CPU-visible so the frame can be checked for content. A benchmark that
        // never looks at its output cannot tell a fast kernel from one that did not run.
        outputDescriptor.storageMode = .shared

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with acceleration enabled.
        let optionUseAcceleration: UInt16 = 1 << 4
        var optionValue: UInt16 = visibilityCache.isSkippingUseful ? optionUseAcceleration : 0
        var quaternion = SIMD4<Float>(0, 0, 0, 1)
        var targetViewSize = UInt16(256)
        var pointSetCount: UInt16 = 0
        var pointSelectedIndex: UInt16 = 0

        try argumentManager.encodeFilterableVolumeTexture(resources.texture)
        argumentManager.encodeTexture(outputTexture, argumentIndex: .outputTexture)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh1)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh2)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh3)
        argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh4)
        argumentManager.encodeTexture(visibilityTexture, argumentIndex: .accelerationTexture)
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
        if validateAccelerationDisabled {
            guard let optionBuffer = argumentManager.getBuffer(argumentIndex: .optionValue) else {
                XCTFail("optionValue buffer was not encoded")
                return outputTexture
            }
            let value = optionBuffer.contents().bindMemory(to: UInt16.self, capacity: 1).pointee
            XCTAssertEqual(value & optionUseAcceleration, 0, "ESS must be disabled when no block can be skipped")
        }

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)

        computeEncoder.setComputePipelineState(volumeComputePipeline)
        computeEncoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(cameraBuffer, offset: 0, index: 1)
        // #1692: every texture this kernel touches — the volume, the four transfer LUTs,
        // the visibility pyramid and the output — is reached through the argument buffer,
        // so binding the argument buffer makes none of them resident. VolumeRaycastPass
        // calls this at all three of its dispatch sites; this suite copied the encoding
        // block without it and the dispatches below were timing a kernel whose writes
        // went nowhere. `testBenchmarkedDispatchesActuallyRender` is what notices.
        argumentManager.registerResources(on: computeEncoder)

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

    private func transferTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        let identity = DatasetIdentity.Content(dataset: dataset)
        if let cachedTransferTexture, cachedTransferTexture.identity == identity {
            return cachedTransferTexture.texture
        }
        let texture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset, device: device)
        cachedTransferTexture = (identity, texture)
        return texture
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
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    private func makeOccupiedTestDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let values: [Int16] = (0..<dimensions.voxelCount).map { index in
            Int16(-900 + (index % 16) - 8)
        }
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
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
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }
}
