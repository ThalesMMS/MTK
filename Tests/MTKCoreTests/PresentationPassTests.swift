import CoreGraphics
import Metal
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

final class PresentationPassTests: MTKRenderingEngineTestCase {
    func testRejectsNilDrawableBeforeEncoding() throws {
        let device = try requireMetalDevice()
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .bgra8Unorm)
        guard let queue = texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let pass = PresentationPass()

        XCTAssertThrowsError(try pass.present(texture, to: nil, commandQueue: queue)) { error in
            XCTAssertEqual(error as? PresentationPassError, .drawableUnavailable)
        }
    }

    func testReleasesLeaseWhenDrawableUnavailable() async throws {
        _ = try requireMetalDevice()

        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 8, height: 8))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        let lease = try XCTUnwrap(frame.outputTextureLease)
        guard let queue = frame.texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        do {
            _ = try PresentationPass().present(frame.texture,
                                               to: nil,
                                               commandQueue: queue,
                                               lease: lease)
            XCTFail("Expected drawableUnavailable")
        } catch {
            XCTAssertEqual(error as? PresentationPassError, .drawableUnavailable)
        }

        XCTAssertTrue(lease.isReleased)
        let poolInUseCount = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(poolInUseCount, 0)
    }

    func testReleasesVolumeFrameLeaseWhenDrawableUnavailable() async throws {
        let device = try requireMetalDevice()
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        try await adapter.send(.setWindow(min: testDataset.intensityRange.lowerBound,
                                          max: testDataset.intensityRange.upperBound))
        let frame = try await adapter.enqueueInteractiveFrame(using: makeInteractiveRequest())
        let lease = try XCTUnwrap(frame.outputTextureLease)
        guard let queue = frame.texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        XCTAssertThrowsError(try PresentationPass().present(frame, to: nil, commandQueue: queue)) { error in
            XCTAssertEqual(error as? PresentationPassError, .drawableUnavailable)
        }

        XCTAssertTrue(lease.isReleased)
    }

    func testReleasesVolumeFrameLeaseAfterPresentationCompletion() async throws {
        let device = try requireMetalDevice()
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        try await adapter.send(.setWindow(min: testDataset.intensityRange.lowerBound,
                                          max: testDataset.intensityRange.upperBound))
        let frame = try await adapter.enqueueInteractiveFrame(using: makeInteractiveRequest())
        let lease = try XCTUnwrap(frame.outputTextureLease)
        guard let queue = frame.texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let drawable = try MPRTestMetalDrawable(device: device, width: 8, height: 8)

        _ = try PresentationPass().present(frame, to: drawable, commandQueue: queue)
        try MPRTestHelpers.waitForQueue(queue)
        try await waitUntilReleased(lease)

        XCTAssertTrue(lease.isPresented)
    }

    func testSourceDoesNotUseReadbackOrCGImage() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Rendering/PresentationPass.swift"))

        assertSourceDoesNotUseReadbackOrCGImage(source)
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }

    private func makeTexture(device: any MTLDevice,
                             width: Int,
                             height: Int,
                             pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to allocate Metal texture")
        }
        return texture
    }

    private func makeInteractiveRequest() -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: testDataset,
            transferFunction: VolumeTransferFunction(
                opacityPoints: [
                    .init(intensity: Float(testDataset.intensityRange.lowerBound), opacity: 0),
                    .init(intensity: Float(testDataset.intensityRange.upperBound), opacity: 1)
                ],
                colourPoints: [
                    .init(intensity: Float(testDataset.intensityRange.lowerBound), colour: SIMD4<Float>(0, 0, 0, 1)),
                    .init(intensity: Float(testDataset.intensityRange.upperBound), colour: SIMD4<Float>(1, 1, 1, 1))
                ]
            ),
            viewportSize: CGSize(width: 8, height: 8),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0.5, 0.5, 2),
                target: SIMD3<Float>(0.5, 0.5, 0.5),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45,
                projectionType: .perspective
            ),
            samplingDistance: 1.0 / 8.0,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

    private func waitUntilReleased(_ lease: OutputTextureLease,
                                   timeoutNanoseconds: UInt64 = 2_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !lease.isReleased {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for lease release")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
