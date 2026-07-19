import Metal
import XCTest

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

@testable import MTKCore

final class EmptySpaceVisibilityCacheTests: XCTestCase {
    func test_visibilityRebuildsForWindowChangesButNotIdenticalFrames() async throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard case .success(let accelerator) = MPSEmptySpaceAccelerator.create(
            device: device,
            commandQueue: commandQueue
        ) else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }

        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Signed
        )
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset,
                                                                                      device: device)
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        let cache = try EmptySpaceVisibilityCache(device: device, library: library)
        var parameters = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)

        let first = try await cache.texture(minMaxTexture: structure.texture,
                                      transferTexture: transferTexture,
                                      parameters: parameters,
                                      commandQueue: commandQueue)
        let second = try await cache.texture(minMaxTexture: structure.texture,
                                       transferTexture: transferTexture,
                                       parameters: parameters,
                                       commandQueue: commandQueue)

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.pixelFormat, .r8Unorm)
        XCTAssertEqual(first.mipmapLevelCount, structure.texture.mipmapLevelCount)
        XCTAssertEqual(cache.visibilityBuildCount, 1)

        let replacementTransferTexture = try XCTUnwrap(
            transferTexture.makeTextureView(pixelFormat: transferTexture.pixelFormat)
        )
        XCTAssertFalse(transferTexture === replacementTransferTexture)
        let afterResourceReplacement = try await cache.texture(
            minMaxTexture: structure.texture,
            transferTexture: replacementTransferTexture,
            parameters: parameters,
            commandQueue: commandQueue
        )
        XCTAssertTrue(first === afterResourceReplacement)
        XCTAssertEqual(cache.visibilityBuildCount, 2)

        parameters.material.voxelMinValue -= 1
        let afterWindowChange = try await cache.texture(minMaxTexture: structure.texture,
                                                  transferTexture: replacementTransferTexture,
                                                  parameters: parameters,
                                                  commandQueue: commandQueue)
        _ = try await cache.texture(minMaxTexture: structure.texture,
                              transferTexture: replacementTransferTexture,
                              parameters: parameters,
                              commandQueue: commandQueue)

        XCTAssertTrue(first === afterWindowChange)
        XCTAssertEqual(cache.visibilityBuildCount, 3)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }

    func test_fullyOccupiedVisibilityDisablesPerStepSkipping() async throws {
        #if canImport(MetalPerformanceShaders)
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        guard case .success(let accelerator) = MPSEmptySpaceAccelerator.create(
            device: device,
            commandQueue: commandQueue
        ) else {
            throw XCTSkip("Empty-space acceleration is unavailable on this test runner")
        }

        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let values = [Int16](repeating: 1_024, count: dimensions.voxelCount)
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
        let structure = try accelerator.generateAccelerationStructure(dataset: dataset)
        let transferTexture = try await RaycasterTestHelpers.makeTestTransferTexture(for: dataset,
                                                                                      device: device)
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        let cache = try EmptySpaceVisibilityCache(device: device, library: library)
        let parameters = RaycasterTestHelpers.makeTestRenderingParameters(dataset: dataset, method: 1)

        _ = try await cache.texture(minMaxTexture: structure.texture,
                              transferTexture: transferTexture,
                              parameters: parameters,
                              commandQueue: commandQueue)

        XCTAssertFalse(cache.isSkippingUseful)
        #else
        throw XCTSkip("MetalPerformanceShaders unavailable on this platform")
        #endif
    }
}
