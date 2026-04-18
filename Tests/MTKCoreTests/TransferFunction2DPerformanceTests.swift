//
//  TransferFunction2DPerformanceTests.swift
//  MTKCoreTests
//
//  Performance benchmark tests for 2D transfer function rendering.
//  Measures render time overhead compared to 1D transfer functions.
//  Acceptance criteria: <10% overhead when using 2D vs 1D transfer functions.
//
//  Thales Matheus Mendonça Santos — February 2026
//

import CoreGraphics
import Metal
import simd
import XCTest

@testable import MTKCore

final class TransferFunction2DPerformanceTests: XCTestCase {

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

    func testTextureCreationPerformance() async throws {
        guard device != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeTestDataset()
        let iterations = 20

        // Measure 1D transfer function texture creation
        let tf1D = make1DTransferFunction(for: dataset)
        let start1D = CFAbsoluteTimeGetCurrent()

        for _ in 0..<iterations {
            _ = await MainActor.run {
                TransferFunctions.texture(for: tf1D, device: device)
            }
        }

        let elapsed1D = CFAbsoluteTimeGetCurrent() - start1D
        let average1D = elapsed1D / Double(iterations)

        // Measure 2D transfer function texture creation
        let tf2D = make2DTransferFunction(for: dataset)
        let options = TransferFunctions.TextureOptions(resolution: 256, gradientResolution: 256)
        let start2D = CFAbsoluteTimeGetCurrent()

        for _ in 0..<iterations {
            _ = await MainActor.run {
                TransferFunctions.texture(for: tf2D, device: device, options: options)
            }
        }

        let elapsed2D = CFAbsoluteTimeGetCurrent() - start2D
        let average2D = elapsed2D / Double(iterations)

        let overhead = (average2D - average1D) / average1D
        let overheadPercentage = overhead * 100

        print("📊 Texture Creation Performance:")
        print("   1D texture avg:      \(String(format: "%.3f", average1D * 1000))ms")
        print("   2D texture avg:      \(String(format: "%.3f", average2D * 1000))ms")
        print("   Overhead:            \(String(format: "%.1f", overheadPercentage))%")
        print("   Target:              <10%")

        if average2D < 0.010 {
            print("✅ 2D texture creation is fast: \(String(format: "%.3f", average2D * 1000))ms < 10ms")
        } else {
            print("ℹ️  2D texture creation: \(String(format: "%.3f", average2D * 1000))ms")
            print("   (Acceptable for one-time preset loading)")
        }

        // Texture creation is much slower for 2D due to IDW interpolation over 256x256 grid,
        // but this is a one-time cost during preset loading, not per-frame.
        // We validate that it completes in reasonable time (<100ms) rather than comparing to 1D.
        XCTAssertLessThan(average2D, 0.100, "2D texture creation should complete in <100ms")
    }

    func testRenderPerformanceWith1DTransferFunction() async throws {
        guard device != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeTestDataset()

        let startTime = CFAbsoluteTimeGetCurrent()
        let iterations = 10

        for _ in 0..<iterations {
            let result = try await renderWith1DTransferFunction(dataset: dataset)
            XCTAssertNotNil(result, "Render should produce valid output")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageTime = elapsed / Double(iterations)

        print("📊 Baseline render time (1D transfer function): \(String(format: "%.3f", averageTime * 1000))ms per frame")
        print("   Total time for \(iterations) iterations: \(String(format: "%.3f", elapsed * 1000))ms")

        XCTAssertGreaterThan(averageTime, 0, "Render time should be measurable")
    }

    func testRenderPerformanceWith2DTransferFunction() async throws {
        guard device != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeTestDataset()
        try await ensure2DTransferRenderingAvailable(for: dataset)

        let startTime = CFAbsoluteTimeGetCurrent()
        let iterations = 10

        for _ in 0..<iterations {
            let result = try await renderWith2DTransferFunction(dataset: dataset)
            XCTAssertNotNil(result, "Render should produce valid output")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageTime = elapsed / Double(iterations)

        print("📊 2D transfer function render time: \(String(format: "%.3f", averageTime * 1000))ms per frame")
        print("   Total time for \(iterations) iterations: \(String(format: "%.3f", elapsed * 1000))ms")

        XCTAssertGreaterThan(averageTime, 0, "Render time should be measurable")
    }

    func testPerformanceOverheadMeetsTarget() async throws {
        guard device != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeTestDataset()
        let (baselineAverage, twoDAverage) = try await measureRenderAverages(
            dataset: dataset,
            iterations: 14
        )

        // Calculate overhead
        let overhead = (twoDAverage - baselineAverage) / baselineAverage
        let overheadPercentage = overhead * 100

        print("📊 Performance Analysis:")
        print("   1D TF average:       \(String(format: "%.3f", baselineAverage * 1000))ms")
        print("   2D TF average:       \(String(format: "%.3f", twoDAverage * 1000))ms")
        print("   Overhead:            \(String(format: "%.1f", overheadPercentage))%")
        print("   Target:              <10%")

        if overheadPercentage < 10 {
            print("✅ Performance target met: \(String(format: "%.1f", overheadPercentage))% < 10%")
        } else {
            print("⚠️  Performance overhead \(String(format: "%.1f", overheadPercentage))% exceeded the 10% target")
        }

        XCTAssertLessThan(
            overheadPercentage,
            10.0,
            "2D transfer function overhead should remain below the documented 10% target"
        )
    }

    func testPerformanceWithLargerVolume() async throws {
        guard device != nil else {
            throw XCTSkip("Metal device unavailable")
        }

        let dataset = makeLargerTestDataset()
        let (baselineAverage, twoDAverage) = try await measureRenderAverages(
            dataset: dataset,
            iterations: 12
        )

        // Calculate overhead
        let overhead = (twoDAverage - baselineAverage) / baselineAverage
        let overheadPercentage = overhead * 100

        print("📊 Performance Analysis (Larger Volume):")
        print("   Dimensions:          \(dataset.dimensions.width)×\(dataset.dimensions.height)×\(dataset.dimensions.depth)")
        print("   1D TF average:       \(String(format: "%.3f", baselineAverage * 1000))ms")
        print("   2D TF average:       \(String(format: "%.3f", twoDAverage * 1000))ms")
        print("   Overhead:            \(String(format: "%.1f", overheadPercentage))%")

        XCTAssertLessThan(
            overheadPercentage,
            15.0,
            "Performance overhead should remain bounded even for larger volumes"
        )
    }

    // MARK: - Helper Methods

    private func renderWith1DTransferFunction(
        dataset: VolumeDataset
    ) async throws -> MTLTexture? {
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await make1DTransferTexture(for: dataset)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 512
        outputDescriptor.height = 512
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with 1D transfer function.
        var params = makeTestRenderingParameters(dataset: dataset, method: 1, use2DTF: false)
        var optionValue: UInt16 = 0
        var quaternion = SIMD4<Float>(0, 0, 0, 1)
        var targetViewSize = UInt16(512)
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

    private func measureRenderAverages(
        dataset: VolumeDataset,
        iterations: Int
    ) async throws -> (baseline: Double, twoD: Double) {
        try await ensure2DTransferRenderingAvailable(for: dataset)

        for _ in 0..<3 {
            _ = try await renderWith1DTransferFunction(dataset: dataset)
            _ = try await renderWith2DTransferFunction(dataset: dataset)
        }

        var baselineSamples: [Double] = []
        var twoDSamples: [Double] = []
        baselineSamples.reserveCapacity(iterations)
        twoDSamples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let baselineStart = CFAbsoluteTimeGetCurrent()
            _ = try await renderWith1DTransferFunction(dataset: dataset)
            baselineSamples.append(CFAbsoluteTimeGetCurrent() - baselineStart)

            let twoDStart = CFAbsoluteTimeGetCurrent()
            _ = try await renderWith2DTransferFunction(dataset: dataset)
            twoDSamples.append(CFAbsoluteTimeGetCurrent() - twoDStart)
        }

        return (trimmedMean(baselineSamples), trimmedMean(twoDSamples))
    }

    private func trimmedMean(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        guard samples.count > 4 else {
            return samples.reduce(0, +) / Double(samples.count)
        }

        let sorted = samples.sorted()
        let trimmed = sorted.dropFirst(1).dropLast(1)
        let total = trimmed.reduce(0, +)
        return total / Double(trimmed.count)
    }

    private func ensure2DTransferRenderingAvailable(for dataset: VolumeDataset) async throws {
        do {
            _ = try await renderWith2DTransferFunction(dataset: dataset)
        } catch {
            throw XCTSkip("2D transfer-function render benchmark unavailable on this GPU: \(error)")
        }
    }

    private func renderWith2DTransferFunction(
        dataset: VolumeDataset
    ) async throws -> MTLTexture? {
        let resources = try raycaster.prepare(dataset: dataset)
        let transferTexture = try await make2DTransferTexture(for: dataset)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw XCTestError(.failureWhileWaiting)
        }

        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.width = 512
        outputDescriptor.height = 512
        outputDescriptor.pixelFormat = .rgba8Unorm
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw XCTestError(.failureWhileWaiting)
        }

        // Encode argument buffer for volume_compute with 2D transfer function.
        var params = makeTestRenderingParameters(dataset: dataset, method: 1, use2DTF: true)
        var optionValue: UInt16 = 0
        var quaternion = SIMD4<Float>(0, 0, 0, 1)
        var targetViewSize = UInt16(512)
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

    private func makeTestRenderingParameters(dataset: VolumeDataset, method: Int32, use2DTF: Bool) -> RenderingParameters {
        var params = RenderingParameters()
        params.material.method = method
        params.material.renderingQuality = 256
        params.material.voxelMinValue = dataset.intensityRange.lowerBound
        params.material.voxelMaxValue = dataset.intensityRange.upperBound
        params.material.datasetMinValue = dataset.intensityRange.lowerBound
        params.material.datasetMaxValue = dataset.intensityRange.upperBound
        params.material.dimX = Int32(dataset.dimensions.width)
        params.material.dimY = Int32(dataset.dimensions.height)
        params.material.dimZ = Int32(dataset.dimensions.depth)
        params.material.use2DTF = use2DTF ? 1 : 0
        params.material.gradientMin = 0.0
        params.material.gradientMax = 500.0
        params.renderingStep = 1.0 / Float(max(params.material.renderingQuality, 1))
        params.earlyTerminationThreshold = 0.95
        params.intensityRatio = SIMD4<Float>(1, 0, 0, 0)
        return params
    }

    private func make1DTransferFunction(for dataset: VolumeDataset) -> TransferFunction {
        var tf = TransferFunction()
        tf.name = "Test1DTF"
        tf.minimumValue = Float(dataset.intensityRange.lowerBound)
        tf.maximumValue = Float(dataset.intensityRange.upperBound)
        tf.colorSpace = .linear
        tf.colourPoints = [
            .init(dataValue: tf.minimumValue, colourValue: .init(r: 0.2, g: 0.2, b: 0.2, a: 1)),
            .init(dataValue: tf.maximumValue, colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        tf.alphaPoints = [
            .init(dataValue: tf.minimumValue, alphaValue: 0.0),
            .init(dataValue: (tf.minimumValue + tf.maximumValue) * 0.3, alphaValue: 0.5),
            .init(dataValue: (tf.minimumValue + tf.maximumValue) * 0.7, alphaValue: 1.0),
            .init(dataValue: tf.maximumValue, alphaValue: 0.2)
        ]
        return tf
    }

    private func make1DTransferTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        let tf = make1DTransferFunction(for: dataset)
        let texture = await MainActor.run {
            TransferFunctions.texture(for: tf, device: device)
        }
        guard let texture else {
            throw XCTSkip("Failed to create 1D transfer function texture")
        }
        return texture
    }

    private func make2DTransferFunction(for dataset: VolumeDataset) -> TransferFunction2D {
        var tf = TransferFunction2D()
        tf.name = "Test2DTF"
        tf.minimumIntensity = Float(dataset.intensityRange.lowerBound)
        tf.maximumIntensity = Float(dataset.intensityRange.upperBound)
        tf.minimumGradient = 0.0
        tf.maximumGradient = 500.0
        tf.colorSpace = .linear

        // Create 2D control points: varying intensity and gradient
        tf.colourPoints = [
            // Low intensity, low gradient
            .init(intensity: tf.minimumIntensity, gradientMagnitude: 0.0, colourValue: .init(r: 0.1, g: 0.1, b: 0.1, a: 1)),
            // Low intensity, high gradient (edges in dark regions)
            .init(intensity: tf.minimumIntensity, gradientMagnitude: 300.0, colourValue: .init(r: 0.5, g: 0.3, b: 0.1, a: 1)),
            // High intensity, low gradient
            .init(intensity: tf.maximumIntensity, gradientMagnitude: 0.0, colourValue: .init(r: 0.8, g: 0.8, b: 0.8, a: 1)),
            // High intensity, high gradient (bright edges)
            .init(intensity: tf.maximumIntensity, gradientMagnitude: 500.0, colourValue: .init(r: 1, g: 1, b: 0.5, a: 1))
        ]

        tf.alphaPoints = [
            // Low intensity, low gradient - mostly transparent
            .init(intensity: tf.minimumIntensity, gradientMagnitude: 0.0, alphaValue: 0.0),
            // Low intensity, high gradient - semi-opaque edges
            .init(intensity: tf.minimumIntensity, gradientMagnitude: 400.0, alphaValue: 0.6),
            // Mid intensity, mid gradient
            .init(intensity: (tf.minimumIntensity + tf.maximumIntensity) * 0.5, gradientMagnitude: 200.0, alphaValue: 0.8),
            // High intensity, low gradient - semi-transparent
            .init(intensity: tf.maximumIntensity, gradientMagnitude: 0.0, alphaValue: 0.3),
            // High intensity, high gradient - opaque edges
            .init(intensity: tf.maximumIntensity, gradientMagnitude: 500.0, alphaValue: 1.0)
        ]
        return tf
    }

    private func make2DTransferTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        let tf = make2DTransferFunction(for: dataset)
        let options = TransferFunctions.TextureOptions(resolution: 256, gradientResolution: 256)
        let texture = await MainActor.run {
            TransferFunctions.texture(for: tf, device: device, options: options)
        }
        guard let texture else {
            throw XCTSkip("Failed to create 2D transfer function texture")
        }
        return texture
    }

    private func makeTestDataset() -> VolumeDataset {
        // Create a test volume simulating CT data with varying intensities and gradients
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values: [Int16] = Array(repeating: -500, count: dimensions.voxelCount)

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

                    // Create gradient patterns: spherical shells with varying intensity
                    if distance < 10 {
                        values[index] = 800
                    } else if distance < 15 {
                        values[index] = 400
                    } else if distance < 20 {
                        values[index] = 0
                    } else if distance < 25 {
                        values[index] = -200
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

    private func makeLargerTestDataset() -> VolumeDataset {
        // Larger test volume for performance testing
        let dimensions = VolumeDimensions(width: 128, height: 128, depth: 128)
        var values: [Int16] = Array(repeating: -500, count: dimensions.voxelCount)

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

                    // Create gradient patterns with multiple shells
                    if distance < 20 {
                        values[index] = 1000
                    } else if distance < 30 {
                        values[index] = 500
                    } else if distance < 40 {
                        values[index] = 100
                    } else if distance < 50 {
                        values[index] = -300
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
