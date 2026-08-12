import CoreGraphics
import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeRaycastPassTests: XCTestCase {
    func test_raycastDispatchConfiguration_pipelineLimits_usesDefaultConfiguration() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)

        let configuration = setup.pass.debugDispatchConfiguration
        let limits = setup.pass.debugPipelineLimits

        XCTAssertEqual(configuration, .default(for: limits))
        XCTAssertEqual(configuration.width, limits.threadExecutionWidth)
        XCTAssertLessThanOrEqual(configuration.threadCount,
                                 limits.maxTotalThreadsPerThreadgroup)
    }

    func test_accelerationCacheCreationFails_constructsPlainDVRPass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let library = try ShaderLibraryLoader.loadLibrary(for: device)

        let pass = try VolumeRaycastPass(
            device: device,
            library: library,
            makeEmptySpaceVisibilityCache: { _, _ in
                throw NSError(domain: "VolumeRaycastPassTests", code: 1)
            }
        )

        XCTAssertNotNil(pass)
    }

    private let debugDensityOptionBit: UInt16 = 1 << 3

    func test_raycast_filterableVolumeView_reusesBinding() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let setup = try await makeDirectPassSetup(device: device, compositing: .frontToBack)

        _ = try await setup.pass.execute(input: setup.input, commandQueue: setup.commandQueue)
        let firstView = try XCTUnwrap(setup.pass.argumentManager.debugBoundTexture(for: .mainTexture))
        _ = try await setup.pass.execute(input: setup.input, commandQueue: setup.commandQueue)
        let secondView = try XCTUnwrap(setup.pass.argumentManager.debugBoundTexture(for: .mainTexture))

        XCTAssertEqual(setup.input.volumeTexture.pixelFormat, .r16Sint)
        XCTAssertEqual(firstView.pixelFormat, .r16Snorm)
        XCTAssertEqual(ObjectIdentifier(firstView as AnyObject), ObjectIdentifier(secondView as AnyObject))
    }

    func test_raycast_unsignedNormalizedView_bindsFormatFlag() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values = [UInt16](repeating: 1_000, count: dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...4_095,
            recommendedWindow: 0...4_095
        )
        let setup = try await makeDirectPassSetup(
            device: device,
            compositing: .frontToBack,
            dataset: dataset
        )

        _ = try await setup.pass.execute(input: setup.input, commandQueue: setup.commandQueue)
        let view = try XCTUnwrap(setup.pass.argumentManager.debugBoundTexture(for: .mainTexture))
        let optionBuffer = try XCTUnwrap(setup.pass.argumentManager.getBuffer(argumentIndex: .optionValue))
        let optionValue = optionBuffer.contents().assumingMemoryBound(to: UInt16.self).pointee

        XCTAssertEqual(setup.input.volumeTexture.pixelFormat, .r16Uint)
        XCTAssertEqual(view.pixelFormat, .r16Unorm)
        XCTAssertNotEqual(optionValue & (1 << 5), 0)
    }

    func test_signedNormalizedVolumeView_clinicalHUValues_roundTrips() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let values: [Int16] = [.min, -32_000, -2_048, -1_024, -1, 0, 1, 2_048, 3_071, 32_767]
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: values.count, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: Int32(Int16.min)...Int32(Int16.max)
        )
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let source = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device,
                           commandQueue: queue,
                           usage: [.shaderRead, .pixelFormatView])
        let view = try XCTUnwrap(source.makeTextureView(pixelFormat: .r16Snorm))
        let output = try XCTUnwrap(device.makeBuffer(
            length: values.count * MemoryLayout<Int16>.stride,
            options: .storageModeShared
        ))
        let library = try await device.makeLibrary(source: Self.signedNormalizedRoundTripShader, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "roundTripSignedNormalizedVolume"))
        let pipeline = try await device.makeComputePipelineState(function: function)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(view, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: values.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(values.count, pipeline.maxTotalThreadsPerThreadgroup),
                                           height: 1,
                                           depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()

        XCTAssertEqual(commandBuffer.status, .completed)
        let decoded = Array(UnsafeBufferPointer(
            start: output.contents().assumingMemoryBound(to: Int16.self),
            count: values.count
        ))
        XCTAssertEqual(decoded, values)
    }

    func test_signedNormalizedVolumeView_manualTrilinearInterpolation_matches() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let values: [Int16] = [-2_000, -1_000, 0, 1_000, 2_000, 3_000, 4_000, 5_000]
        let coordinates: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 1, 1),
            SIMD3(0.5, 0.5, 0.5),
            SIMD3(0.25, 0.75, 0.5)
        ]
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = 2
        descriptor.height = 2
        descriptor.depth = 2
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .pixelFormatView]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { bytes in
            source.replace(
                region: MTLRegionMake3D(0, 0, 0, 2, 2, 2),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 2 * MemoryLayout<Int16>.stride,
                bytesPerImage: 4 * MemoryLayout<Int16>.stride
            )
        }
        let view = try XCTUnwrap(source.makeTextureView(pixelFormat: .r16Snorm))
        let coordinateBuffer = try XCTUnwrap(device.makeBuffer(
            bytes: coordinates,
            length: coordinates.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ))
        let output = try XCTUnwrap(device.makeBuffer(
            length: coordinates.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ))
        let library = try device.makeLibrary(source: Self.signedNormalizedRoundTripShader, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "sampleSignedNormalizedVolume"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(view, index: 0)
        encoder.setBuffer(coordinateBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: coordinates.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: coordinates.count, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        let sampled = Array(UnsafeBufferPointer(
            start: output.contents().assumingMemoryBound(to: Float.self),
            count: coordinates.count
        ))
        let expected: [Float] = [-2_000, 5_000, 1_500, 1_750]
        for (actual, expectedValue) in zip(sampled, expected) {
            XCTAssertEqual(actual, expectedValue, accuracy: 0.1)
        }
    }

    func test_densitySamplingShader_hardwareSampling_avoidsManualReads() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/MTKCore/Resources/Shaders/volume_shader_common.metal")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let functionStart = try XCTUnwrap(source.range(of: "static float sampleTrilinearDensity"))
        let functionEnd = try XCTUnwrap(
            source.range(of: "static float3 calGradient", range: functionStart.upperBound..<source.endIndex)
        )
        let functionSource = source[functionStart.lowerBound..<functionEnd.lowerBound]

        XCTAssertEqual(functionSource.components(separatedBy: ".sample(").count - 1, 1)
        XCTAssertFalse(functionSource.contains(".read("))
    }

    func test_transferFunctionSampling_uniformFlag_avoidsTextureHeightQuery() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/MTKCore/Resources/Shaders/volume_shader_common.metal")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let functionStart = try XCTUnwrap(source.range(of: "static float4 getTfColour"))
        let functionSource = source[functionStart.lowerBound..<source.endIndex]

        XCTAssertTrue(functionSource.contains("bool use2DTransferFunction"))
        XCTAssertFalse(functionSource.contains("tf.get_height()"))
    }

    func testDVRCompositingProducesValidOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        assertValidOutput(output,
                          compositing: .frontToBack,
                          viewportSize: setup.viewportSize)
    }

    func testMIPCompositingProducesValidOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .maximumIntensity)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        assertValidOutput(output,
                          compositing: .maximumIntensity,
                          viewportSize: setup.viewportSize)
    }

    func testMinIPCompositingProducesValidOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .minimumIntensity)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        assertValidOutput(output,
                          compositing: .minimumIntensity,
                          viewportSize: setup.viewportSize)
    }

    func testAIPCompositingProducesValidOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .averageIntensity)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        assertValidOutput(output,
                          compositing: .averageIntensity,
                          viewportSize: setup.viewportSize)
    }

    func testRaycastTimingMetricsAreCaptured() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        XCTAssertGreaterThan(output.timing.cpuDurationMilliseconds, 0)
        XCTAssertNotNil(output.timing.gpuStartTime)
        XCTAssertNotNil(output.timing.gpuEndTime)
        XCTAssertNotNil(output.timing.gpuDurationMilliseconds)
        XCTAssertNotNil(output.timing.kernelStartTime)
        XCTAssertNotNil(output.timing.kernelEndTime)
        XCTAssertNotNil(output.timing.kernelDurationMilliseconds)
    }

    func testDVRCompositingProducesVisiblePixels() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)
        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)
        let frame = makeTestVolumeRenderFrame(from: output)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let imageSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(image))
        let textureSummary = try XCTUnwrap(VolumeRenderRegressionFixture.texturePixelSummary(output.outputTexture))

        XCTAssertTrue(imageSummary.maxBlue > 0 || imageSummary.maxGreen > 0 || imageSummary.maxRed > 0,
                      "image summary: \(imageSummary), texture summary: \(textureSummary)")
        XCTAssertTrue(try VolumeRenderRegressionFixture.textureContainsVisiblePixels(output.outputTexture),
                      "texture summary: \(textureSummary), image summary: \(imageSummary)")
    }

    func test_nearestShadowSampling_keepsReadbackWithinTrilinearGoldenTolerance() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let camera = VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, -2.0),
                                                target: SIMD3<Float>(repeating: 0.5),
                                                up: SIMD3<Float>(0, 1, 0),
                                                fieldOfView: 45)
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 160, height: 160),
                                                  requestCamera: camera)
        var hardInput = setup.input
        hardInput.shaderParameters.material.isLightingOn = 1
        hardInput.shaderParameters.material.shadowMode = VolumeShadowMode.hard.shaderValue
        hardInput.shaderParameters.material.renderingQuality = 512
        hardInput.shaderParameters.renderingStep = 1.0 / 512.0
        hardInput.shaderParameters.light = 1.8
        hardInput.shaderParameters.shade = 0.15
        var softInput = hardInput
        softInput.shaderParameters.material.shadowMode = VolumeShadowMode.soft.shaderValue

        let hardOutput = try await setup.pass.execute(input: hardInput,
                                                      commandQueue: setup.commandQueue)
        let softOutput = try await setup.pass.execute(input: softInput,
                                                      commandQueue: setup.commandQueue)
        let hardEnergy = try await rgbEnergy(from: hardOutput)
        let softEnergy = try await rgbEnergy(from: softOutput)

        XCTAssertGreaterThan(hardEnergy, 0)
        XCTAssertGreaterThan(softEnergy, 0)
        XCTAssertGreaterThan(abs(hardEnergy - softEnergy),
                             10,
                             "hard and soft shadow readbacks should differ, got \(hardEnergy) and \(softEnergy)")
        // Re-recorded in #1679. `shadowSampleAlpha` used to return the raw
        // window density; since "Let the window index the transfer function in
        // DVR" it returns the same opacity the main path composites, so the
        // volume no longer casts shadows from an opacity it does not render and
        // both readbacks land roughly three times higher.
        XCTAssertEqual(Double(hardEnergy),
                       2_452_170,
                       accuracy: 2_452_170 * 0.02,
                       "hard-shadow readback drifted from the trilinear golden")
        XCTAssertEqual(Double(softEnergy),
                       2_894_040,
                       accuracy: 2_894_040 * 0.02,
                       "soft-shadow readback drifted from the trilinear golden")
    }

    func test_accelerationInput_buildsVisibilityAndPreservesDVRReadback() async throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dataset = VolumeRenderRegressionFixture.dataset()
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  dataset: dataset)
        guard case .success(let accelerator) = MPSEmptySpaceAccelerator.create(
            device: device,
            commandQueue: setup.commandQueue
        ) else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }
        let structure = try accelerator.generateAccelerationStructure(
            from: setup.input.volumeTexture,
            intensityRange: dataset.intensityRange
        )

        let baseline = try await executeAttributingGPUFaults(setup.input, setup: setup)
        var acceleratedInput = setup.input
        acceleratedInput.accelerationTexture = structure.texture
        acceleratedInput.optionValue |= VolumeRenderOptionBits.acceleration
        let accelerated = try await executeAttributingGPUFaults(acceleratedInput, setup: setup)

        let baselineEnergy = try await rgbEnergy(from: baseline)
        let acceleratedEnergy = try await rgbEnergy(from: accelerated)
        XCTAssertEqual(Double(acceleratedEnergy),
                       Double(baselineEnergy),
                       accuracy: Double(max(baselineEnergy, 1)) * 0.02)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func test_fullyOccupiedVisibility_disablesAccelerationBeforeDispatch() async throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let dataset = makeSolidSignedDataset(dimensions: dimensions,
                                             spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                                             value: 1_024,
                                             intensityRange: (-1024)...3071)
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 64, height: 64),
                                                  dataset: dataset)
        guard case .success(let accelerator) = MPSEmptySpaceAccelerator.create(
            device: device,
            commandQueue: setup.commandQueue
        ) else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }
        let structure = try accelerator.generateAccelerationStructure(
            from: setup.input.volumeTexture,
            intensityRange: dataset.intensityRange
        )
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset,
                                                                                      device: device)
        var input = setup.input
        input.transferFunctionTexture = transferTexture
        input.accelerationTexture = structure.texture
        input.optionValue |= VolumeRenderOptionBits.acceleration

        _ = try await setup.pass.execute(input: input,
                                         commandQueue: setup.commandQueue)

        let optionBuffer = try XCTUnwrap(
            setup.pass.argumentManager.getBuffer(argumentIndex: .optionValue)
        )
        let optionValue = optionBuffer.contents().bindMemory(to: UInt16.self, capacity: 1).pointee
        XCTAssertEqual(optionValue & VolumeRenderOptionBits.acceleration, 0)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func test_adaptiveStepping_matchesPreOptimizationGolden() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)
        var input = setup.input
        input.shaderParameters.material.isLightingOn = 0
        input.shaderParameters.adaptiveGradientThreshold = 100
        input.optionValue |= VolumeRenderOptionBits.adaptiveStepping

        let output = try await setup.pass.execute(input: input,
                                                  commandQueue: setup.commandQueue)
        let energy = try await rgbEnergy(from: output)

        // Re-recorded in #1679. The goldens in this file were recorded on 10 Jul
        // 2026 against the bundled `MTK.metallib`, which is a checked-in binary
        // and was not rebuilt when "Let the window index the transfer function
        // in DVR" changed `volume_compute.metal` on 26 Jul. The tests kept
        // running the old shader until "Correct MPR bounds handling and
        // crosshair rotation" rebuilt the metallib for an unrelated MPR change.
        // The windowed value now indexes the LUT directly instead of scaling the
        // preset's RGB and alpha by a second ramp, so the same fixture
        // composites more energy.
        XCTAssertEqual(
            Double(energy),
            1_978_146,
            accuracy: 1_978_146 * 0.02,
            "Adaptive DVR readback drifted from the pre-optimization golden"
        )
    }

    func test_adaptiveStepping_isNotSlowerThanFixedSteppingForSparseCT() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Kernel timing is validated only on stable local hardware")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dataset = makeSparseCTDataset()
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 1_024, height: 1_024),
                                                  dataset: dataset,
                                                  samplingDistance: 1.0 / 256.0)
        var fixedInput = setup.input
        fixedInput.shaderParameters.material.isLightingOn = 0
        fixedInput.shaderParameters.adaptiveGradientThreshold = 100
        var adaptiveInput = fixedInput
        adaptiveInput.optionValue |= VolumeRenderOptionBits.adaptiveStepping

        for iteration in 0..<4 {
            let firstInput = iteration.isMultiple(of: 2) ? fixedInput : adaptiveInput
            let secondInput = iteration.isMultiple(of: 2) ? adaptiveInput : fixedInput
            _ = try await kernelDuration(input: firstInput, setup: setup)
            _ = try await kernelDuration(input: secondInput, setup: setup)
        }

        let ratios = try await adaptiveToFixedKernelDurationRatios(
            fixedInput: fixedInput,
            adaptiveInput: adaptiveInput,
            setup: setup,
            batchCount: 7,
            executionsPerBatch: 32
        )

        // A measurement cannot settle a 5% question while its own batches disagree by more
        // than 5%, and these batches disagree a great deal: five consecutive runs on this
        // machine spread 21%, 39%, 40%, 54% and 72% between their cheapest and dearest
        // batch, with medians from 0.943 to 1.075 — one of the five would have failed the
        // assertion below on its own, with nothing else running. Under six concurrent runs
        // of this suite the medians reached 1.06, 1.08 and 1.36. Those numbers describe
        // what else the GPU was doing, and announcing them as a regression is how a gate
        // teaches people to ignore it. So the timing only gets to speak when it is steady
        // enough to be heard, which on a loaded machine is never — deliberately.
        let spread = (ratios[ratios.count - 1] - ratios[0]) / ratios[0]
        let tolerance = 0.05
        print("📊 Adaptive vs fixed kernel duration: median \(String(format: "%.4f", ratios[ratios.count / 2])), batch spread \(String(format: "%.1f", spread * 100))%")
        guard spread <= tolerance else {
            throw XCTSkip("Kernel timing is too noisy on this machine to resolve \(Int(tolerance * 100))%: batches spread \(String(format: "%.1f", spread * 100))% (\(ratios))")
        }

        XCTAssertLessThanOrEqual(ratios[ratios.count / 2],
                                 1 + tolerance,
                                 "Adaptive stepping should stay within the established 5% tolerance for sparse CT")
    }

    func testAnisotropicDatasetRendersWithPhysicalSideViewBounds() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let dataset = makeSolidSignedDataset(dimensions: dimensions,
                                             spacing: VolumeSpacing(x: 1, y: 1, z: 3),
                                             value: 500,
                                             intensityRange: 0...1000)
        let camera = VolumeRenderRequest.Camera(position: SIMD3<Float>(5, 0.5, 0.5),
                                                target: SIMD3<Float>(repeating: 0.5),
                                                up: SIMD3<Float>(0, 0, 1),
                                                fieldOfView: 50)
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 96, height: 96),
                                                  dataset: dataset,
                                                  requestCamera: camera)

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)
        let frame = makeTestVolumeRenderFrame(from: output)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let bounds = try XCTUnwrap(visiblePixelBounds(in: image))

        XCTAssertGreaterThan(bounds.height,
                             Int(Float(bounds.width) * 1.4),
                             "side-view visible bounds should reflect z spacing: \(bounds)")
    }

    func testDVRDoesNotDropEntryFacePixelsForSolidVolume() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let dataset = makeSolidSignedDataset(dimensions: VolumeDimensions(width: 64, height: 64, depth: 64),
                                             spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                                             value: 500,
                                             intensityRange: 0...1000)
        let camera = VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, -2.0, 0.5),
                                                target: SIMD3<Float>(repeating: 0.5),
                                                up: SIMD3<Float>(0, 0, 1),
                                                fieldOfView: 50)
        var setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 160, height: 160),
                                                  dataset: dataset,
                                                  requestCamera: camera)
        setup.input.shaderParameters.material.renderingQuality = 768
        setup.input.shaderParameters.material.isLightingOn = 0

        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)
        let frame = makeTestVolumeRenderFrame(from: output)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let fill = try XCTUnwrap(visiblePixelFill(in: image))

        XCTAssertGreaterThan(fill.bounds.width, 40)
        XCTAssertGreaterThan(fill.bounds.height, 40)
        XCTAssertGreaterThan(fill.ratio,
                             0.9,
                             "solid DVR entry face should not have a stippled hole pattern: \(fill)")
    }

    func testDVRCompositingDebugDensityProducesNonZeroOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        var setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)
        setup.input.optionValue = debugDensityOptionBit
        let output = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)
        let frame = makeTestVolumeRenderFrame(from: output)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        let imageSummary = try XCTUnwrap(VolumeRenderRegressionFixture.imagePixelSummary(image))
        let textureSummary = try XCTUnwrap(VolumeRenderRegressionFixture.texturePixelSummary(output.outputTexture))

        XCTAssertTrue(imageSummary.maxBlue > 0 || imageSummary.maxGreen > 0 || imageSummary.maxRed > 0,
                      "debug image summary: \(imageSummary), texture summary: \(textureSummary)")
        XCTAssertTrue(try VolumeRenderRegressionFixture.textureContainsVisiblePixels(output.outputTexture),
                      "debug texture summary: \(textureSummary), image summary: \(imageSummary)")
    }

    func test_executeReturnsDistinctStandaloneOutputTexturesAcrossInvocations() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)

        let first = try await setup.pass.execute(input: setup.input,
                                                 commandQueue: setup.commandQueue)
        let second = try await setup.pass.execute(input: setup.input,
                                                  commandQueue: setup.commandQueue)

        XCTAssertNotEqual(ObjectIdentifier(first.outputTexture as AnyObject),
                          ObjectIdentifier(second.outputTexture as AnyObject))
    }

    func test_prepareOutputTextureCreatesPrivateBGRAWriteTarget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let pass = try VolumeRaycastPass(device: device)

        let texture = try pass.prepareOutputTexture(width: 16, height: 12, device: device)

        XCTAssertEqual(texture.textureType, .type2D)
        XCTAssertEqual(texture.width, 16)
        XCTAssertEqual(texture.height, 12)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertTrue(texture.usage.contains(.shaderWrite))
    }

    func test_prepareOutputTextureDoesNotReuseEscapedTextureInstance() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let pass = try VolumeRaycastPass(device: device)

        let first = try pass.prepareOutputTexture(width: 16, height: 12, device: device)
        let second = try pass.prepareOutputTexture(width: 16, height: 12, device: device)

        XCTAssertNotEqual(ObjectIdentifier(first as AnyObject),
                          ObjectIdentifier(second as AnyObject))
    }

    func test_executeRejectsInvalidOutputTextureContract() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        var setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack)
        setup.input.outputTexture = try makeOutputTexture(device: device,
                                                          width: Int(setup.viewportSize.width),
                                                          height: Int(setup.viewportSize.height),
                                                          pixelFormat: .rgba8Unorm,
                                                          storageMode: .private,
                                                          usage: [.shaderWrite])

        do {
            _ = try await setup.pass.execute(input: setup.input,
                                             commandQueue: setup.commandQueue)
            XCTFail("Expected invalidOutputTexture error")
        } catch VolumeRaycastPassError.invalidOutputTexture(let message) {
            XCTAssertTrue(message.contains("pixel format"))
        } catch {
            XCTFail("Expected invalidOutputTexture error, got \(error)")
        }
    }

    func test_executeRejectsInvalidViewport() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  viewportSize: CGSize(width: 0, height: 10))

        do {
            _ = try await setup.pass.execute(input: setup.input,
                                             commandQueue: setup.commandQueue)
            XCTFail("Expected invalidDimensions error")
        } catch VolumeRaycastPassError.invalidDimensions(let width, let height) {
            XCTAssertEqual(width, 0)
            XCTAssertEqual(height, 10)
        } catch {
            XCTFail("Expected invalidDimensions error, got \(error)")
        }
    }

    func test_executeRejectsDegenerateCamera() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }

        var camera = RaycasterTestHelpers.makeTestCameraUniforms()
        camera.inverseViewProjectionMatrix.columns.0.x = .nan
        let setup = try await makeDirectPassSetup(device: device,
                                                  compositing: .frontToBack,
                                                  camera: camera)

        do {
            _ = try await setup.pass.execute(input: setup.input,
                                             commandQueue: setup.commandQueue)
            XCTFail("Expected degenerateCamera error")
        } catch VolumeRaycastPassError.degenerateCamera {
            // Expected.
        } catch {
            XCTFail("Expected degenerateCamera error, got \(error)")
        }
    }

    private func assertValidOutput(_ output: VolumeRaycastPassOutput,
                                   compositing: VolumeRenderRequest.Compositing,
                                   viewportSize: CGSize,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(output.outputTexture.textureType, .type2D, file: file, line: line)
        XCTAssertEqual(output.outputTexture.width, Int(viewportSize.width), file: file, line: line)
        XCTAssertEqual(output.outputTexture.height, Int(viewportSize.height), file: file, line: line)
        XCTAssertEqual(output.outputTexture.pixelFormat, .bgra8Unorm, file: file, line: line)
        XCTAssertEqual(output.outputTexture.storageMode, .private, file: file, line: line)
        XCTAssertEqual(output.compositingMode, compositing, file: file, line: line)
        XCTAssertEqual(output.quality, .interactive, file: file, line: line)
        XCTAssertEqual(output.viewportSize, viewportSize, file: file, line: line)
    }

    private func makeTestVolumeRenderFrame(from output: VolumeRaycastPassOutput) -> VolumeRenderFrame {
        VolumeRenderFrame(
            texture: output.outputTexture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: output.viewportSize,
                samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
                compositing: output.compositingMode,
                quality: output.quality,
                pixelFormat: output.outputTexture.pixelFormat
            )
        )
    }

    private func rgbEnergy(from output: VolumeRaycastPassOutput) async throws -> Int {
        let frame = makeTestVolumeRenderFrame(from: output)
        let image = try await TextureSnapshotExporter().makeCGImage(from: frame)
        return try XCTUnwrap(rgbEnergy(in: image))
    }

    private func makeDirectPassSetup(device: any MTLDevice,
                                     compositing: VolumeRenderRequest.Compositing,
                                     viewportSize: CGSize = VolumeRenderRegressionFixture.viewportSize,
                                     camera: CameraUniforms? = nil,
                                     dataset: VolumeDataset = VolumeRenderRegressionFixture.dataset(),
                                     requestCamera: VolumeRenderRequest.Camera = VolumeRenderRegressionFixture.camera(),
                                     samplingDistance: Float = VolumeRenderRegressionFixture.samplingDistance)
        async throws -> DirectPassSetup {
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        let pass = try VolumeRaycastPass(device: device)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device,
                           commandQueue: commandQueue,
                           usage: [.shaderRead, .pixelFormatView])
        let transferTextureOptional = await MainActor.run(body: {
            VolumeRenderRegressionFixture.transferTexture(for: dataset, device: device)
        })
        let transferTexture = try XCTUnwrap(transferTextureOptional, "Failed to create transfer function texture")

        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeRenderRegressionFixture.volumeTransferFunction(for: dataset),
            viewportSize: viewportSize,
            camera: requestCamera,
            samplingDistance: samplingDistance,
            compositing: compositing,
            quality: .interactive
        )
        let resolvedCamera: CameraUniforms
        if let camera {
            resolvedCamera = camera
        } else {
            let adapter = try MetalVolumeRenderingAdapter(device: device, commandQueue: commandQueue)
            resolvedCamera = try await adapter.makeCameraUniforms(for: request,
                                                                  viewportSize: (Int(viewportSize.width),
                                                                                 Int(viewportSize.height)),
                                                                  frameIndex: 0)
        }

        let shaderParameters = RaycasterTestHelpers.makeTestRenderingParameters(
            dataset: dataset,
            method: Self.shaderMethod(for: compositing)
        )
        let renderingParameters = VolumeRaycastPassRenderingParameters(
            quality: .interactive,
            samplingDistance: samplingDistance,
            compositingMode: compositing
        )
        let input = VolumeRaycastPassInput(
            volumeTexture: volumeTexture,
            transferFunctionTexture: transferTexture,
            cameraUniforms: resolvedCamera,
            renderingParameters: renderingParameters,
            shaderParameters: shaderParameters,
            viewportSize: viewportSize
        )

        return DirectPassSetup(pass: pass,
                               commandQueue: commandQueue,
                               input: input,
                               viewportSize: viewportSize)
    }

    private func rgbEnergy(in image: CGImage) -> Int? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var energy = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            energy += Int(pixels[index])
            energy += Int(pixels[index + 1])
            energy += Int(pixels[index + 2])
        }
        return energy
    }

    private func makeSolidSignedDataset(dimensions: VolumeDimensions,
                                        spacing: VolumeSpacing,
                                        value: Int16,
                                        intensityRange: ClosedRange<Int32>) -> VolumeDataset {
        let values = [Int16](repeating: value, count: dimensions.voxelCount)
        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             dimensions: dimensions,
                             spacing: spacing,
                             pixelFormat: .int16Signed,
                             intensityRange: intensityRange,
                             recommendedWindow: intensityRange)
    }

    private static let signedNormalizedRoundTripShader = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void roundTripSignedNormalizedVolume(
        texture3d<float, access::sample> volume [[texture(0)]],
        device short *output [[buffer(0)]],
        uint index [[thread_position_in_grid]])
    {
        constexpr sampler nearestSampler(coord::normalized,
                                         filter::nearest,
                                         address::clamp_to_edge);
        if (index >= volume.get_width()) {
            return;
        }
        const float x = (float(index) + 0.5f) / float(volume.get_width());
        const float sampleValue = volume.sample(nearestSampler, float3(x, 0.5f, 0.5f)).r;
        const float decoded = sampleValue <= -1.0f ? -32768.0f : sampleValue * 32767.0f;
        output[index] = short(round(clamp(decoded, -32768.0f, 32767.0f)));
    }

    kernel void sampleSignedNormalizedVolume(
        texture3d<float, access::sample> volume [[texture(0)]],
        device const float3 *coordinates [[buffer(0)]],
        device float *output [[buffer(1)]],
        uint index [[thread_position_in_grid]])
    {
        constexpr sampler linearSampler(coord::normalized,
                                        filter::linear,
                                        address::clamp_to_edge);
        const float3 dimension = float3(volume.get_width(), volume.get_height(), volume.get_depth());
        const float3 sampleCoordinate = (coordinates[index] * (dimension - 1.0f) + 0.5f) / dimension;
        const float sampleValue = volume.sample(linearSampler, sampleCoordinate).r;
        output[index] = sampleValue <= -1.0f ? -32768.0f : sampleValue * 32767.0f;
    }
    """

    private func makeSparseCTDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        var values = [Int16](repeating: -1_024, count: dimensions.voxelCount)
        let centerX = dimensions.width / 2
        let centerY = dimensions.height / 2
        let centerZ = dimensions.depth / 2
        let radiusSquared = 14 * 14

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let dx = x - centerX
                    let dy = y - centerY
                    let dz = z - centerZ
                    guard dx * dx + dy * dy + dz * dz < radiusSquared else { continue }
                    let index = z * dimensions.width * dimensions.height + y * dimensions.width + x
                    values[index] = Int16(((x * 13 + y * 7 + z * 5) % 401) - 200)
                }
            }
        }

        return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                             dimensions: dimensions,
                             spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                             pixelFormat: .int16Signed,
                             intensityRange: (-1_024)...3_071,
                             recommendedWindow: (-1_024)...3_071)
    }

    /// Per-batch adaptive/fixed kernel duration ratios, sorted, so the caller can see how
    /// far the batches disagree as well as where they centre.
    private func adaptiveToFixedKernelDurationRatios(fixedInput: VolumeRaycastPassInput,
                                                     adaptiveInput: VolumeRaycastPassInput,
                                                     setup: DirectPassSetup,
                                                     batchCount: Int,
                                                     executionsPerBatch: Int) async throws -> [Double] {
        var ratios = [Double]()
        ratios.reserveCapacity(batchCount)

        for batchIndex in 0..<batchCount {
            var fixedDuration = 0.0
            var adaptiveDuration = 0.0

            for executionIndex in 0..<executionsPerBatch {
                let measuresFixedFirst = (batchIndex + executionIndex).isMultiple(of: 2)
                let firstInput = measuresFixedFirst ? fixedInput : adaptiveInput
                let secondInput = measuresFixedFirst ? adaptiveInput : fixedInput
                let firstDuration = try await kernelDuration(input: firstInput,
                                                             setup: setup)
                let secondDuration = try await kernelDuration(input: secondInput,
                                                              setup: setup)
                fixedDuration += measuresFixedFirst ? firstDuration : secondDuration
                adaptiveDuration += measuresFixedFirst ? secondDuration : firstDuration
            }

            let nonzeroFixedDuration = try XCTUnwrap(
                fixedDuration > 0 ? fixedDuration : nil,
                "Fixed stepping kernel duration must be positive"
            )
            ratios.append(adaptiveDuration / nonzeroFixedDuration)
        }

        ratios.sort()
        return ratios
    }

    private func kernelDuration(input: VolumeRaycastPassInput,
                                setup: DirectPassSetup) async throws -> Double {
        let output: VolumeRaycastPassOutput
        do {
            output = try await setup.pass.execute(input: input,
                                                  commandQueue: setup.commandQueue)
        } catch {
            // Another process's GPU error takes our in-flight command buffers with it.
            // There is no duration to compare once that happens, and nothing of ours to
            // blame for it.
            try GPUFaultAttribution.rethrowUnlessDiscarded(error, while: "Timing the raycast kernel")
        }
        return try XCTUnwrap(output.timing.kernelDurationMilliseconds)
    }

    /// Runs the pass, and abstains rather than reporting another process's GPU fault as
    /// a defect of ours.
    ///
    /// The pass is right to raise a discarded command buffer as an error — the frame
    /// really was lost, and it does not retry, because it renders under a global in-flight
    /// lock and the caller is about to ask for the next frame anyway. But "the machine was
    /// busy" is not a verdict on this code, and under six concurrent runs of this suite
    /// that is exactly what this test reported.
    private func executeAttributingGPUFaults(_ input: VolumeRaycastPassInput,
                                             setup: DirectPassSetup) async throws -> VolumeRaycastPassOutput {
        do {
            return try await setup.pass.execute(input: input, commandQueue: setup.commandQueue)
        } catch {
            try GPUFaultAttribution.rethrowUnlessDiscarded(error, while: "Rendering the raycast pass")
        }
    }

    private func visiblePixelBounds(in image: CGImage) -> PixelBounds? {
        visiblePixelFill(in: image)?.bounds
    }

    private func visiblePixelFill(in image: CGImage) -> PixelFill? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var visibleCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                let visible = pixels[index] > 5 || pixels[index + 1] > 5 || pixels[index + 2] > 5
                if visible {
                    visibleCount += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bounds = PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        let area = max(bounds.width * bounds.height, 1)
        return PixelFill(bounds: bounds,
                         ratio: Double(visibleCount) / Double(area),
                         visibleCount: visibleCount)
    }

    private static func shaderMethod(for compositing: VolumeRenderRequest.Compositing) -> Int32 {
        switch compositing {
        case .frontToBack:
            return 1
        case .maximumIntensity:
            return 2
        case .minimumIntensity:
            return 3
        case .averageIntensity:
            return 4
        }
    }

    private func makeOutputTexture(device: any MTLDevice,
                                   width: Int,
                                   height: Int,
                                   pixelFormat: MTLPixelFormat,
                                   storageMode: MTLStorageMode,
                                   usage: MTLTextureUsage) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = storageMode
        descriptor.usage = usage

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create output texture")
        }
        return texture
    }
}

private struct DirectPassSetup {
    var pass: VolumeRaycastPass
    var commandQueue: any MTLCommandQueue
    var input: VolumeRaycastPassInput
    var viewportSize: CGSize
}

private struct PixelBounds: CustomStringConvertible {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    var description: String {
        "x:\(minX)...\(maxX) y:\(minY)...\(maxY) width:\(width) height:\(height)"
    }
}

private struct PixelFill: CustomStringConvertible {
    var bounds: PixelBounds
    var ratio: Double
    var visibleCount: Int

    var description: String {
        "bounds:\(bounds) fillRatio:\(ratio) visibleCount:\(visibleCount)"
    }
}
