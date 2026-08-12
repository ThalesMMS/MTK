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
    private var visibilityCache: EmptySpaceVisibilityCache!
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
        self.volumeComputePipeline = try device.makeComputePipelineState(function: function)
        self.argumentManager = ArgumentEncoderManager(
            device: device,
            mtlFunction: function,
            debugOptions: VolumeRenderingDebugOptions(isDebugMode: false, histogramBinCount: 256, enableDensityDebug: false)
        )
        self.visibilityCache = try EmptySpaceVisibilityCache(device: device, library: library)

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

    // MARK: - What the Comparison Is Comparing

    /// #1692 asked whether declaring residency was itself the thing that moved the pixels,
    /// because the maximum error went from exactly 0.0000 to 1.0000 the moment the line
    /// was added. It is not, and this holds that answer.
    ///
    /// Two frames, differing in everything except the flag. The reference binds a 1×1
    /// dummy in the acceleration slot; the control binds the real visibility pyramid and
    /// goes through the accelerated encoder — same residency declaration, same pyramid on
    /// the GPU — with OPTION_USE_ACCELERATION cleared. They must come back bit for bit
    /// identical. Everything the accelerated frames in the tests below do differently,
    /// they do because rays skipped blocks.
    func testOnlyTheSkippingFlagChangesTheFrame() async throws {
        #if canImport(MetalPerformanceShaders)
        guard raycaster.isMetalPerformanceShadersAvailable else {
            throw XCTSkip("MPS acceleration is unavailable for this Metal runtime; prepareAccelerationStructure(dataset:) would return .unavailable")
        }

        let dataset = makeSparseTestDataset()
        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let reference = try await renderWithoutAcceleration(dataset: dataset, method: 1),
              let control = try await renderWithAcceleration(dataset: dataset,
                                                             method: 1,
                                                             accelerationTexture: accelerationTexture,
                                                             accelerationEnabled: false) else {
            XCTFail("Failed to render the reference and control frames")
            return
        }

        let residencyOnly = try compareTextures(baseline: reference, accelerated: control, tolerance: 0.0)

        print("📊 Flag Isolation Analysis:")
        print("   Reference vs control: \(residencyOnly.differentPixels) pixels, max \(String(format: "%.4f", residencyOnly.maxPixelError))")

        XCTAssertEqual(
            residencyOnly.maxPixelError,
            0,
            "Binding the visibility pyramid and declaring residency moved \(residencyOnly.differentPixels) "
            + "pixels on their own, so the accelerated frame cannot be read as the cost of skipping"
        )
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
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

    /// MIP is the one mode where the two frames are expected to match exactly, and it is
    /// worth saying why so the zero is not read as the #1686 smell again: `volume_compute`
    /// gates empty-space skipping on `isDVR`, so `method: 2` ignores
    /// `OPTION_USE_ACCELERATION` and the accelerated encoding is the same render. What
    /// this asserts is that enabling acceleration does not leak into a projection mode.
    /// `compareTextures` refuses two blank frames, so the zero can no longer be the
    /// agreement of two dispatches that never ran.
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

        // Both shapes, because a hole needs geometry to hide behind: the shells of the
        // complex volume never lost more than 6% to the #1692 defect, while the sparse
        // one lost entire rays to it.
        for (name, dataset) in [("shells", makeComplexTestDataset()), ("sparse", makeSparseTestDataset())] {
            try await assertNoClusteredHoles(in: dataset, named: name)
        }
        #else
        throw XCTSkip("MPS acceleration is unavailable for this platform; prepareAccelerationStructure(dataset:) would return .unavailable")
        #endif
    }

    #if canImport(MetalPerformanceShaders)
    private func assertNoClusteredHoles(in dataset: VolumeDataset,
                                        named name: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async throws {
        guard let baselineTexture = try await renderWithoutAcceleration(dataset: dataset, method: 1) else {
            XCTFail("Failed to render reference Metal-only texture", file: file, line: line)
            return
        }

        let accelerationTexture = try requireAccelerationTexture(for: dataset)

        guard let acceleratedTexture = try await renderWithAcceleration(dataset: dataset, method: 1, accelerationTexture: accelerationTexture) else {
            XCTFail("Failed to render accelerated texture", file: file, line: line)
            return
        }

        // #1692: the clustering map is built at 10%, not at the 2% used for the
        // difference *ratio* elsewhere, and the difference matters.
        //
        // Skipping a block moves the ray to the block's exit face, so every sample after
        // it lands off the uniform step grid the reference marched on. That perturbation
        // is real but bounded, and it concentrates where rays graze the object — which is
        // to say it is always contiguous. At 2% the detector fires on it every time and
        // says "artifact" about a resampling phase. Measured on the sparse volume it is
        // under 7% per channel and it shrinks with the step: 405 pixels over a 2%
        // tolerance at quality 256, 119 at 1024, 9 at 4096.
        //
        // Content the skipping *removed* does not behave that way. It does not shrink
        // with the step and it is not small: before the pyramid was made conservative
        // (see `computeMinMaxDownsample`) rays tangent to a block face lost everything
        // they should have accumulated, and the same band of pixels differed by a full
        // 1.0000. A cluster above 10% is that; a cluster below it is the grid.
        let comparison = try compareTextures(
            baseline: baselineTexture,
            accelerated: acceleratedTexture,
            tolerance: 0.1
        )

        print("📊 Artifact Detection Analysis (\(name)):")
        print("   Pixels over 10%:     \(comparison.differentPixels) / \(comparison.totalPixels)")
        print("   Max pixel error:     \(String(format: "%.4f", comparison.maxPixelError))")
        print("   Clustered errors:    \(comparison.hasClusteredErrors ? "Yes ⚠️" : "No ✅")")

        // A cluster of pixels that lost more than 10% is a hole, not a resampling shift.
        XCTAssertFalse(
            comparison.hasClusteredErrors,
            "Acceleration skipped a block of the \(name) volume that was carrying visible "
            + "content: \(comparison.differentPixels) pixels differ by more than 10%, worst "
            + "\(String(format: "%.4f", comparison.maxPixelError)), and they are contiguous",
            file: file,
            line: line
        )
    }
    #endif

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

        // #1692: the ratio alone let this dataset report a worst pixel of 0.9529 and still
        // pass — a wall of tissue vanishing from a handful of rays does not move a
        // percentage of the frame. The magnitude is the part that says "hole".
        XCTAssertLessThan(
            comparison.maxPixelError,
            0.1,
            "A pixel changed by \(String(format: "%.4f", comparison.maxPixelError)) across the "
            + "sharp transition: acceleration dropped content the reference march composited"
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
        // block without it, the writes to the output texture went nowhere, and both sides
        // of every comparison below read back an all-zero frame.
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
        method: Int32,
        accelerationTexture: any MTLTexture,
        accelerationEnabled: Bool = true
    ) async throws -> MTLTexture? {
        // Accelerated path: shader-level ZSKIP heuristic plus precomputed
        // visibility, with OPTION_USE_ACCELERATION enabled.
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset, device: device)
        var params = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: method)
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
        outputDescriptor.storageMode = .shared // Shared for CPU readback

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with acceleration enabled.
        let optionUseAcceleration: UInt16 = 1 << 4
        var optionValue: UInt16 = accelerationEnabled ? optionUseAcceleration : 0
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

        // Runtime sanity: option buffer must carry the acceleration flag for this render.
        if let optionBuffer = argumentManager.getBuffer(argumentIndex: .optionValue) {
            let value = optionBuffer.contents().bindMemory(to: UInt16.self, capacity: 1).pointee
            XCTAssertEqual(value & optionUseAcceleration,
                           accelerationEnabled ? optionUseAcceleration : 0,
                           "OPTION_USE_ACCELERATION must match the requested mode for this render")
        }

        // #1692: and that the flag had something to act on. Every comparison in this file
        // ends in "the accelerated frame matches the reference", which is also what comes
        // out when the pyramid marks nothing skippable and the two encodings run the same
        // ray march. The cache raises this flag while baking the level the raycast reads.
        XCTAssertTrue(visibilityCache.isSkippingUseful,
                      "No block of this dataset is skippable, so the accelerated render is "
                      + "the reference render and comparing them measures nothing")

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)

        computeEncoder.setComputePipelineState(volumeComputePipeline)
        computeEncoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(cameraBuffer, offset: 0, index: 1)
        // #1692: every texture this kernel touches — the volume, the four transfer LUTs,
        // the visibility pyramid and the output — is reached through the argument buffer,
        // so binding the argument buffer makes none of them resident. VolumeRaycastPass
        // calls this at all three of its dispatch sites; this suite copied the encoding
        // block without it, the writes to the output texture went nowhere, and both sides
        // of every comparison below read back an all-zero frame.
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

    private func assertFrameIsNotBlank(_ bytes: [UInt8],
                                       label: String,
                                       file: StaticString,
                                       line: UInt) {
        var brightest: UInt8 = 0
        for byte in bytes where byte > brightest {
            brightest = byte
        }
        XCTAssertGreaterThan(brightest,
                             0,
                             "The \(label) render is an all-zero frame: the dispatch wrote nothing, "
                             + "so comparing it proves nothing",
                             file: file,
                             line: line)
    }

    private func compareTextures(
        baseline: any MTLTexture,
        accelerated: any MTLTexture,
        tolerance: Float,
        file: StaticString = #filePath,
        line: UInt = #line
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

        // Intentional test-only readback for pixel-diff quality assertions.
        // Production snapshot/export readback must go through TextureSnapshotExporter.
        let baselineData = MPRTextureReadbackHelper.readBytes(from: baseline,
                                                              bytesPerRow: bytesPerRow,
                                                              byteCount: totalBytes)
        let acceleratedData = MPRTextureReadbackHelper.readBytes(from: accelerated,
                                                                 bytesPerRow: bytesPerRow,
                                                                 byteCount: totalBytes)

        // #1692: the comparison this method performs is only worth anything if both
        // frames were rendered. Undeclared residency made both dispatches write nowhere,
        // and two all-zero frames agree bit for bit — which is how every assertion in
        // this file reported a maximum pixel error of exactly 0.0000 for months while
        // measuring nothing at all. A blank frame is not a quality result.
        assertFrameIsNotBlank(baselineData, label: "reference", file: file, line: line)
        assertFrameIsNotBlank(acceleratedData, label: "accelerated", file: file, line: line)

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
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
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
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
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
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }
}
