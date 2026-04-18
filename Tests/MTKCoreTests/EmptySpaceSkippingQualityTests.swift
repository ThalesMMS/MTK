//
//  EmptySpaceSkippingQualityTests.swift
//  MTKCoreTests
//
//  Visual quality regression tests for MPS empty space skipping optimization.
//  Compares shader heuristic only against shader heuristic plus MPS precomputed structure.
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

final class EmptySpaceSkippingQualityTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var raycaster: MetalRaycaster!
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

    // MARK: - Visual Quality Regression Tests

    func testVisualQualityMaintainedWithAcceleration() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        let dataset = makeSparseTestDataset()

        // Render the reference Metal-only path with the shader-level ZSKIP heuristic only.
        guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 1) else {
            XCTFail("Failed to render reference Metal-only texture")
            return
        }

        // Render shader-level ZSKIP heuristic plus MPS precomputed acceleration structure.
        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 1, accelerationTexture: accelerationTexture) else {
            XCTFail("Failed to render accelerated texture")
            return
        }

        // Compare textures pixel-by-pixel
        let comparison = try compareTextures(
            baseline: baselineTexture,
            accelerated: acceleratedTexture,
            tolerance: 0.02 // 2% tolerance for floating-point differences
        )

        print("📊 Visual Quality Analysis (DVR):")
        print("   Total pixels:        \(comparison.totalPixels)")
        print("   Different pixels:    \(comparison.differentPixels)")
        print("   Difference ratio:    \(String(format: "%.2f", comparison.differenceRatio * 100))%")
        print("   Max pixel error:     \(String(format: "%.4f", comparison.maxPixelError))")
        print("   Average pixel error: \(String(format: "%.4f", comparison.averagePixelError))")
        print("   Tolerance:           2%")

        // Visual quality is maintained if difference ratio is low
        XCTAssertLessThan(
            comparison.differenceRatio,
            0.05, // Allow up to 5% of pixels to differ slightly
            "Visual quality should be maintained (difference ratio < 5%)"
        )

        XCTAssertLessThan(
            comparison.maxPixelError,
            0.1, // Max error per pixel should be small
            "Maximum pixel error should be below 10% per channel"
        )

        if comparison.differenceRatio < 0.01 {
            print("✅ Excellent visual quality preservation: \(String(format: "%.2f", comparison.differenceRatio * 100))% difference")
        } else if comparison.differenceRatio < 0.05 {
            print("✅ Good visual quality preserved: \(String(format: "%.2f", comparison.differenceRatio * 100))% difference")
        } else {
            print("⚠️  Visual quality degradation detected: \(String(format: "%.2f", comparison.differenceRatio * 100))% difference")
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
    }

    func testVisualQualityWithMIPRendering() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        let dataset = makeSparseTestDataset()

        // Render the reference Metal-only path with the shader-level ZSKIP heuristic only.
        guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 2) else {
            XCTFail("Failed to render reference Metal-only texture")
            return
        }

        // Render shader-level ZSKIP heuristic plus MPS precomputed acceleration structure.
        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 2, accelerationTexture: accelerationTexture) else {
            XCTFail("Failed to render accelerated texture")
            return
        }

        let comparison = try compareTextures(
            baseline: baselineTexture,
            accelerated: acceleratedTexture,
            tolerance: 0.02
        )

        print("📊 Visual Quality Analysis (MIP):")
        print("   Difference ratio:    \(String(format: "%.2f", comparison.differenceRatio * 100))%")
        print("   Max pixel error:     \(String(format: "%.4f", comparison.maxPixelError))")

        XCTAssertLessThan(
            comparison.differenceRatio,
            0.05,
            "MIP rendering quality should be maintained"
        )

        XCTAssertLessThan(
            comparison.maxPixelError,
            0.1,
            "Maximum pixel error should be minimal for MIP"
        )
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
    }

    func testNoVisibleArtifactsIntroduced() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        let dataset = makeComplexTestDataset()

        guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 1) else {
            XCTFail("Failed to render reference Metal-only texture")
            return
        }

        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 1, accelerationTexture: accelerationTexture) else {
            XCTFail("Failed to render accelerated texture")
            return
        }

        let comparison = try compareTextures(
            baseline: baselineTexture,
            accelerated: acceleratedTexture,
            tolerance: 0.02
        )

        print("📊 Artifact Detection Analysis:")
        print("   Different pixels:    \(comparison.differentPixels) / \(comparison.totalPixels)")
        print("   Max pixel error:     \(String(format: "%.4f", comparison.maxPixelError))")
        print("   Clustered errors:    \(comparison.hasClusteredErrors ? "Yes ⚠️" : "No ✅")")

        // Large clustered errors indicate visible artifacts
        XCTAssertFalse(
            comparison.hasClusteredErrors,
            "Acceleration should not introduce visible artifacts"
        )

        // Spot check: ensure large errors are isolated, not clustered
        if comparison.maxPixelError > 0.05 {
            print("⚠️  Significant pixel errors detected, checking for clustering...")
            XCTAssertFalse(
                comparison.hasClusteredErrors,
                "Large errors should be isolated, not clustered (indicating artifacts)"
            )
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
    }

    func testEdgeCaseVolumeQuality() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        // Test with a volume that has sharp transitions (edge case for acceleration)
        let dataset = makeSharpTransitionDataset()

        guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 1) else {
            XCTFail("Failed to render reference Metal-only texture")
            return
        }

        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 1, accelerationTexture: accelerationTexture) else {
            XCTFail("Failed to render accelerated texture")
            return
        }

        let comparison = try compareTextures(
            baseline: baselineTexture,
            accelerated: acceleratedTexture,
            tolerance: 0.03 // Slightly higher tolerance for edge cases
        )

        print("📊 Edge Case Quality Analysis:")
        print("   Difference ratio:    \(String(format: "%.2f", comparison.differenceRatio * 100))%")
        print("   Max pixel error:     \(String(format: "%.4f", comparison.maxPixelError))")

        // Sharp transitions are more challenging, but quality should still be preserved
        XCTAssertLessThan(
            comparison.differenceRatio,
            0.1, // Allow slightly higher difference for edge cases
            "Quality should be maintained even with sharp transitions"
        )
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
    }

    func testConsistentQualityAcrossMultipleRenders() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        let dataset = makeSparseTestDataset()

        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        // Render multiple times and ensure consistency
        var comparisons: [TextureComparison] = []
        let iterations = 3

        for i in 0..<iterations {
            guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 1) else {
                XCTFail("Failed to render reference Metal-only texture at iteration \(i)")
                continue
            }

            guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 1, accelerationTexture: accelerationTexture) else {
                XCTFail("Failed to render accelerated texture at iteration \(i)")
                continue
            }

            let comparison = try compareTextures(
                baseline: baselineTexture,
                accelerated: acceleratedTexture,
                tolerance: 0.02
            )
            comparisons.append(comparison)
        }

        XCTAssertEqual(comparisons.count, iterations, "All iterations should complete")

        // Check that quality is consistent across renders
        let differenceRatios = comparisons.map { $0.differenceRatio }
        let minRatio = differenceRatios.min() ?? 0
        let maxRatio = differenceRatios.max() ?? 0
        let variance = maxRatio - minRatio

        print("📊 Consistency Analysis:")
        print("   Iterations:          \(iterations)")
        print("   Min difference:      \(String(format: "%.2f", minRatio * 100))%")
        print("   Max difference:      \(String(format: "%.2f", maxRatio * 100))%")
        print("   Variance:            \(String(format: "%.2f", variance * 100))%")

        XCTAssertLessThan(
            variance,
            0.01, // Variance should be small
            "Quality should be consistent across multiple renders"
        )

        for comparison in comparisons {
            XCTAssertLessThan(
                comparison.differenceRatio,
                0.05,
                "Each render should maintain quality"
            )
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
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
        dataset: VolumeDataset,
        method: Int32
    ) async throws -> MTLTexture? {
        // Reference path: shader-level ZSKIP heuristic only. The dummy acceleration
        // texture is bound for layout completeness, but acceleration is not enabled.
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
        outputDescriptor.storageMode = .shared // Shared for CPU readback

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute.
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: method)
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
        method: Int32,
        accelerationTexture: any MTLTexture
    ) async throws -> MTLTexture? {
        // Accelerated path: shader-level ZSKIP heuristic plus MPS precomputed
        // min-max structure, with OPTION_USE_ACCELERATION enabled.
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
        outputDescriptor.storageMode = .shared // Shared for CPU readback

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with acceleration enabled.
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: method)
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

        // Runtime sanity: option buffer must carry the acceleration flag for this render.
        if let optionBuffer = argumentManager.getBuffer(argumentIndex: .optionValue) {
            let value = optionBuffer.contents().bindMemory(to: UInt16.self, capacity: 1).pointee
            XCTAssertNotEqual(value & optionUseAcceleration, 0, "OPTION_USE_ACCELERATION must be set for accelerated render")
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

    private struct TextureComparison {
        let totalPixels: Int
        let differentPixels: Int
        let maxPixelError: Float
        let averagePixelError: Float
        let hasClusteredErrors: Bool

        var differenceRatio: Float {
            Float(differentPixels) / Float(totalPixels)
        }
    }

    private func compareTextures(
        baseline: any MTLTexture,
        accelerated: any MTLTexture,
        tolerance: Float
    ) throws -> TextureComparison {
        guard baseline.width == accelerated.width,
              baseline.height == accelerated.height,
              baseline.pixelFormat == accelerated.pixelFormat else {
            throw XCTestError(.failureWhileWaiting)
        }

        let width = baseline.width
        let height = baseline.height
        let bytesPerPixel = 4 // RGBA8
        let bytesPerRow = bytesPerPixel * width
        let totalBytes = bytesPerRow * height

        var baselineData = [UInt8](repeating: 0, count: totalBytes)
        var acceleratedData = [UInt8](repeating: 0, count: totalBytes)

        baseline.getBytes(
            &baselineData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0
        )

        accelerated.getBytes(
            &acceleratedData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0
        )

        var differentPixels = 0
        var maxPixelError: Float = 0
        var totalPixelError: Float = 0
        var errorMap = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel

                let r1 = Float(baselineData[offset]) / 255.0
                let g1 = Float(baselineData[offset + 1]) / 255.0
                let b1 = Float(baselineData[offset + 2]) / 255.0
                let a1 = Float(baselineData[offset + 3]) / 255.0

                let r2 = Float(acceleratedData[offset]) / 255.0
                let g2 = Float(acceleratedData[offset + 1]) / 255.0
                let b2 = Float(acceleratedData[offset + 2]) / 255.0
                let a2 = Float(acceleratedData[offset + 3]) / 255.0

                // Calculate per-channel error
                let rError = abs(r1 - r2)
                let gError = abs(g1 - g2)
                let bError = abs(b1 - b2)
                let aError = abs(a1 - a2)

                let maxChannelError = max(rError, gError, bError, aError)

                if maxChannelError > tolerance {
                    differentPixels += 1
                    errorMap[y][x] = true
                }

                maxPixelError = max(maxPixelError, maxChannelError)
                totalPixelError += maxChannelError
            }
        }

        let totalPixels = width * height
        let averagePixelError = totalPixelError / Float(totalPixels)

        // Check for clustered errors (indicate visible artifacts)
        let hasClusteredErrors = detectClusteredErrors(errorMap: errorMap, threshold: 5)

        return TextureComparison(
            totalPixels: totalPixels,
            differentPixels: differentPixels,
            maxPixelError: maxPixelError,
            averagePixelError: averagePixelError,
            hasClusteredErrors: hasClusteredErrors
        )
    }

    private func detectClusteredErrors(errorMap: [[Bool]], threshold: Int) -> Bool {
        let height = errorMap.count
        guard height > 0 else { return false }
        let width = errorMap[0].count

        // Simple clustering detection: check if any error pixel has multiple error neighbors
        for y in 0..<height {
            for x in 0..<width {
                guard errorMap[y][x] else { continue }

                var neighborCount = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let ny = y + dy
                        let nx = x + dx
                        if ny >= 0 && ny < height && nx >= 0 && nx < width {
                            if errorMap[ny][nx] && !(dy == 0 && dx == 0) {
                                neighborCount += 1
                            }
                        }
                    }
                }

                if neighborCount >= threshold {
                    return true
                }
            }
        }

        return false
    }

    private func makeSparseTestDataset() -> VolumeDataset {
        // Create a sparse volume simulating CT chest scan with lots of air (empty space)
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values: [Int16] = Array(repeating: -1000, count: dimensions.voxelCount)
        let sparsePatternSeed: UInt32 = 0xC0FFEE

        func deterministicSparseValue(x: Int, y: Int, z: Int) -> Int16 {
            let mixed = (UInt32(x) &* 73_856_093)
                ^ (UInt32(y) &* 19_349_663)
                ^ (UInt32(z) &* 83_492_791)
                ^ sparsePatternSeed
            return Int16(Int32(mixed % 401) - 200)
        }

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
                        let index = z * dimensions.width * dimensions.height + y * dimensions.width + x
                        values[index] = deterministicSparseValue(x: x, y: y, z: z)
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

    private func makeComplexTestDataset() -> VolumeDataset {
        // Create a more complex volume with varied densities
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values: [Int16] = Array(repeating: -1000, count: dimensions.voxelCount)

        let centerX = dimensions.width / 2
        let centerY = dimensions.height / 2
        let centerZ = dimensions.depth / 2

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let dx = x - centerX
                    let dy = y - centerY
                    let dz = z - centerZ
                    let distance = sqrt(Double(dx * dx + dy * dy + dz * dz))

                    let index = z * dimensions.width * dimensions.height + y * dimensions.width + x

                    // Create multiple shells with different densities
                    if distance < 8 {
                        values[index] = 1000 // Dense core
                    } else if distance < 16 {
                        values[index] = -900 // Air gap
                    } else if distance < 20 {
                        values[index] = 200 // Tissue layer
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

    private func makeSharpTransitionDataset() -> VolumeDataset {
        // Create a volume with sharp transitions (challenging for acceleration)
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values: [Int16] = Array(repeating: -1000, count: dimensions.voxelCount)

        let centerX = dimensions.width / 2

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = z * dimensions.width * dimensions.height + y * dimensions.width + x

                    // Sharp transition at center
                    if x < centerX {
                        values[index] = -1000 // Air
                    } else {
                        values[index] = 500 // Dense tissue
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