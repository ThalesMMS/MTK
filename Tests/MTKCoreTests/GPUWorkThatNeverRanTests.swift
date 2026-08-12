//
//  GPUWorkThatNeverRanTests.swift
//  MTK
//
//  The GPU paths whose output cannot say whether it was written, and what they do
//  about a command buffer the driver discarded before it ran (#1686).
//

import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class GPUWorkThatNeverRanTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = commandQueue
    }

    // MARK: - What a dispatch that never ran leaves behind

    /// The premise the rest of this file rests on: a texture nothing wrote into does not
    /// read back as blank, so no caller downstream can recognise one.
    ///
    /// Metal hands out fresh `.private` render targets filled with magenta — 0xFF00FFFF —
    /// which is why `SurfaceMeshRendererTests` reported
    /// `("255") is not greater than ("255")` under contention and looked like a broken
    /// depth sort. It was a render pass that never ran, compared against itself.
    func test_freshPrivateRenderTarget_readsBackAsMagentaRatherThanBlank() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 64,
                                                                  height: 64,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let bytes = try MPRTextureReadbackHelper.readBytes(from: target,
                                                           bytesPerPixel: 4,
                                                           device: device,
                                                           commandQueue: commandQueue)
        let centre = ((target.height / 2) * target.width + (target.width / 2)) * 4

        XCTAssertNotEqual(Array(bytes[centre..<(centre + 4)]), [0, 0, 0, 0],
                          "if this ever starts reading as zeroes, the magenta note above is stale")
        XCTAssertEqual(bytes[centre], bytes[centre + 2],
                       "blue and red both saturated is what the surface mesh test was comparing")
    }

    // MARK: - VolumeTextureFactory

    func test_volumeTextureUpload_failsWhenTheCopyNeverRan() async throws {
        let factory = VolumeTextureFactory(dataset: makeRampDataset())
        factory.discardedUploadsForTesting = 2

        do {
            _ = try await factory.generateAsync(device: device, commandQueue: commandQueue)
            XCTFail("An upload that never ran must not hand back the texture it did not fill")
        } catch let error as VolumeTextureFactory.TextureUploadError {
            guard case .uploadDidNotRun(let reason) = error else {
                return XCTFail("Expected uploadDidNotRun, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_volumeTextureUpload_recoversWhenOnlyTheFirstCopyIsDiscarded() async throws {
        let dataset = makeRampDataset()
        let factory = VolumeTextureFactory(dataset: dataset)
        factory.discardedUploadsForTesting = 1

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        let firstSlice: [UInt16] = try readFirstSlice(of: texture)
        XCTAssertEqual(firstSlice, Array(Self.rampVoxels.prefix(firstSlice.count)),
                       "the retry has to copy the voxels, not just return the allocation")
    }

    // MARK: - MetalMPRComputeAdapter

    func test_mprSlab_failsWhenTheDispatchNeverRan() async throws {
        let setup = try await makeMPRSetup()
        await setup.adapter.setDiscardedDispatchesForTesting(2)

        do {
            _ = try await setup.adapter.makeSlabTexture(dataset: setup.dataset,
                                                        volumeTexture: setup.volumeTexture,
                                                        plane: setup.plane,
                                                        thickness: 1,
                                                        steps: 1,
                                                        blend: .single)
            XCTFail("A slab that never ran must not be returned as a slice")
        } catch let error as MetalMPRComputeAdapter.ComputeError {
            guard case .dispatchDidNotRun = error else {
                return XCTFail("Expected dispatchDidNotRun, got \(error)")
            }
        }
    }

    func test_mprSlab_recoversWhenOnlyTheFirstDispatchIsDiscarded() async throws {
        let setup = try await makeMPRSetup()
        await setup.adapter.setDiscardedDispatchesForTesting(1)

        let frame = try await setup.adapter.makeSlabTexture(dataset: setup.dataset,
                                                            volumeTexture: setup.volumeTexture,
                                                            plane: setup.plane,
                                                            thickness: 1,
                                                            steps: 1,
                                                            blend: .single)
        defer { frame.debugReleaseOutputTextureLease() }

        let values: [UInt16] = try MPRTextureReadbackHelper.readValues(UInt16.self,
                                                                       from: frame,
                                                                       device: device,
                                                                       commandQueue: commandQueue)
        XCTAssertEqual(values.count, frame.texture.width * frame.texture.height)
        XCTAssertTrue(values.contains { $0 != 0 },
                      "the retry has to produce a slice, not the texture it was handed")
    }

    // MARK: - MetalCPRAdapter

    func test_cprStretchedFrame_failsWhenTheDispatchNeverRan() async throws {
        let setup = try makeCPRSetup()
        await setup.adapter.setDiscardedDispatchesForTesting(2)

        do {
            _ = try await setup.adapter.makeStretchedTextureFrame(dataset: setup.dataset,
                                                                   path: setup.path,
                                                                   authoringPlane: setup.plane,
                                                                   outputWidth: 32,
                                                                   outputHeight: 24)
            XCTFail("A reformat that never ran must not be returned as an image")
        } catch let error as MetalCPRAdapter.AdapterError {
            guard case .dispatchDidNotRun = error else {
                return XCTFail("Expected dispatchDidNotRun, got \(error)")
            }
        }
    }

    func test_cprStretchedFrame_recoversWhenOnlyTheFirstDispatchIsDiscarded() async throws {
        let setup = try makeCPRSetup()
        await setup.adapter.setDiscardedDispatchesForTesting(1)

        let frame = try await setup.adapter.makeStretchedTextureFrame(dataset: setup.dataset,
                                                                       path: setup.path,
                                                                       authoringPlane: setup.plane,
                                                                       outputWidth: 32,
                                                                       outputHeight: 24)

        let values: [UInt16] = try MPRTextureReadbackHelper.readValues(UInt16.self,
                                                                       from: frame,
                                                                       device: device,
                                                                       commandQueue: commandQueue)
        XCTAssertEqual(values.count, 32 * 24)
        XCTAssertTrue(values.contains { $0 != 0 },
                      "the retry has to produce a reformat, not the allocation it started from")
    }

    // MARK: - MPSEmptySpaceAccelerator

    func test_accelerationPyramid_failsWhenTheBuildNeverRan() async throws {
        let (accelerator, volumeTexture, dataset) = try await makeAcceleratorSetup()
        accelerator.discardedBuildsForTesting = 2

        do {
            _ = try accelerator.generateAccelerationStructure(from: volumeTexture,
                                                              intensityRange: dataset.intensityRange)
            XCTFail("A pyramid that was never built must not be handed to the raycaster")
        } catch let error as MPSEmptySpaceAccelerator.AcceleratorError {
            guard case .pyramidBuildDidNotRun = error else {
                return XCTFail("Expected pyramidBuildDidNotRun, got \(error)")
            }
        }
    }

    /// A pyramid nobody wrote reads as empty everywhere, so the raycaster skips the whole
    /// volume and returns a black frame. That is the shape of the one failure #1686 could
    /// not account for: RGB energy 0 against a baseline of 1969749.
    func test_accelerationPyramid_recoversWhenOnlyTheFirstBuildIsDiscarded() async throws {
        let (accelerator, volumeTexture, dataset) = try await makeAcceleratorSetup()

        let undisturbed = try accelerator.generateAccelerationStructure(from: volumeTexture,
                                                                        intensityRange: dataset.intensityRange)
        let expected = try readBaseLevel(of: undisturbed.texture)
        XCTAssertTrue(expected.contains { $0 != 0 },
                      "the fixture has to produce a pyramid with something in it")

        accelerator.discardedBuildsForTesting = 1
        let retried = try accelerator.generateAccelerationStructure(from: volumeTexture,
                                                                    intensityRange: dataset.intensityRange)

        XCTAssertEqual(try readBaseLevel(of: retried.texture), expected,
                       "the retry has to build the pyramid, not return the allocation")
    }

    // MARK: - MetalSurfaceMeshRenderer

    func test_surfaceMeshRender_failsWhenTheRenderNeverRan() async throws {
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: commandQueue)
        renderer.discardedRendersForTesting = 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 64,
                                                                  height: 64,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            pixelFormat: .int16Signed
        )
        let layer = SurfaceMeshLayer(
            id: "quad",
            mesh: SurfaceMesh(name: "Quad",
                              vertices: [
                                  SIMD3<Float>(0.2, 0.2, 0.5),
                                  SIMD3<Float>(0.8, 0.2, 0.5),
                                  SIMD3<Float>(0.8, 0.8, 0.5),
                                  SIMD3<Float>(0.2, 0.8, 0.5)
                              ],
                              normals: [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4),
                              indices: [0, 1, 2, 0, 2, 3],
                              coordinateSpace: .textureNormalized),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1))
        )
        let camera = VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, 2),
                                                target: SIMD3<Float>(repeating: 0.5),
                                                up: SIMD3<Float>(0, 1, 0),
                                                fieldOfView: 45,
                                                projectionType: .orthographic)

        do {
            _ = try await renderer.render(layers: [layer],
                                          dataset: dataset,
                                          camera: camera,
                                          targetTexture: target,
                                          clearTarget: true)
            XCTFail("A render that never ran must not report the target as drawn")
        } catch let error as MetalSurfaceMeshRendererError {
            guard case .commandBufferFailed(let reason) = error else {
                return XCTFail("Expected commandBufferFailed, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - Fixtures

    /// A ramp rather than a constant, so a slice read back from the wrong place is visible.
    private static let rampVoxels: [UInt16] = (0..<32).map { UInt16(100 + $0 * 7) }

    private func makeRampDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 2)
        let data = Self.rampVoxels.withUnsafeBytes { Data($0) }
        return VolumeDataset(data: data,
                             dimensions: dimensions,
                             spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                             pixelFormat: .int16Unsigned)
    }

    private func readFirstSlice(of texture: any MTLTexture) throws -> [UInt16] {
        let bytes = try MPRTextureReadbackHelper.readBytes(from: texture,
                                                           bytesPerPixel: 2,
                                                           device: device,
                                                           commandQueue: commandQueue)
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    }

    private struct MPRSetup {
        let adapter: MetalMPRComputeAdapter
        let dataset: VolumeDataset
        let volumeTexture: any MTLTexture
        let plane: MPRPlaneGeometry
    }

    private func makeMPRSetup() async throws -> MPRSetup {
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        let adapter = MetalMPRComputeAdapter(device: device,
                                             commandQueue: commandQueue,
                                             library: library,
                                             featureFlags: FeatureFlags.evaluate(for: device),
                                             debugOptions: VolumeRenderingDebugOptions())
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        return MPRSetup(adapter: adapter,
                        dataset: dataset,
                        volumeTexture: volumeTexture,
                        plane: MPRTestHelpers.makeTestPlaneGeometry(for: dataset))
    }

    /// Base mip level of a min–max pyramid, as raw bytes — `rg16Float`, so four per texel.
    private func readBaseLevel(of pyramid: any MTLTexture) throws -> [UInt8] {
        let bytesPerRow = pyramid.width * 4
        let bytesPerImage = bytesPerRow * pyramid.height
        let byteCount = bytesPerImage * pyramid.depth
        let readback = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: pyramid,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: pyramid.width, height: pyramid.height, depth: pyramid.depth),
                  to: readback,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerImage)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try XCTSkipUnless(commandBuffer.status == .completed,
                          "The pyramid readback itself did not run on this runner")
        let pointer = readback.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
    }

    private func makeAcceleratorSetup() async throws
        -> (MPSEmptySpaceAccelerator, any MTLTexture, VolumeDataset) {
        guard let commandQueue else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        guard case .success(let accelerator) = MPSEmptySpaceAccelerator.create(device: device,
                                                                                commandQueue: commandQueue) else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device,
                           commandQueue: commandQueue,
                           usage: [.shaderRead, .pixelFormatView])
        return (accelerator, volumeTexture, dataset)
    }

    private struct CPRSetup {
        let adapter: MetalCPRAdapter
        let dataset: VolumeDataset
        let path: CPRSampledPath
        let plane: MPRPlaneGeometry
    }

    private func makeCPRSetup() throws -> CPRSetup {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0.5)
        let path = try CPRPathSampler.sample(
            controlPointsWorld: [
                plane.originWorld + 0.1 * plane.axisUWorld + 0.5 * plane.axisVWorld,
                plane.originWorld + 0.5 * plane.axisUWorld + 0.65 * plane.axisVWorld,
                plane.originWorld + 0.9 * plane.axisUWorld + 0.5 * plane.axisVWorld
            ],
            spacingMillimeters: 1
        )
        return CPRSetup(adapter: try MetalCPRAdapter(device: device),
                        dataset: dataset,
                        path: path,
                        plane: plane)
    }
}
