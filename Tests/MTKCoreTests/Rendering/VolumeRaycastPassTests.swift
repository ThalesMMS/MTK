import CoreGraphics
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeRaycastPassTests: XCTestCase {
    private let debugDensityOptionBit: UInt16 = 1 << 3

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

    private func makeDirectPassSetup(device: any MTLDevice,
                                     compositing: VolumeRenderRequest.Compositing,
                                     viewportSize: CGSize = VolumeRenderRegressionFixture.viewportSize,
                                     camera: CameraUniforms? = nil,
                                     dataset: VolumeDataset = VolumeRenderRegressionFixture.dataset()) async throws -> DirectPassSetup {
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        let pass = try VolumeRaycastPass(device: device)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let transferTextureOptional = await MainActor.run(body: {
            VolumeRenderRegressionFixture.transferTexture(for: dataset, device: device)
        })
        let transferTexture = try XCTUnwrap(transferTextureOptional, "Failed to create transfer function texture")

        let request = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: VolumeRenderRegressionFixture.volumeTransferFunction(for: dataset),
            viewportSize: viewportSize,
            camera: VolumeRenderRegressionFixture.camera(),
            samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
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
            samplingDistance: VolumeRenderRegressionFixture.samplingDistance,
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
