import CoreGraphics
import Foundation
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

    private func makeDirectPassSetup(device: any MTLDevice,
                                     compositing: VolumeRenderRequest.Compositing,
                                     viewportSize: CGSize = VolumeRenderRegressionFixture.viewportSize,
                                     camera: CameraUniforms? = nil,
                                     dataset: VolumeDataset = VolumeRenderRegressionFixture.dataset(),
                                     requestCamera: VolumeRenderRequest.Camera = VolumeRenderRegressionFixture.camera()) async throws -> DirectPassSetup {
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
            camera: requestCamera,
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
