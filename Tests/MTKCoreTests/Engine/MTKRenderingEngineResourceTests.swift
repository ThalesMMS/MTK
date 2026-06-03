import CoreGraphics
import Metal
import XCTest
import simd

@_spi(Testing) @testable import MTKCore

final class MTKRenderingEngineResourceTests: MTKRenderingEngineTestCase {
    func test_multipleViewportsSameDataset_shareTexture() async throws {
        let axial = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let coronal = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let sagittal = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .sagittal),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let volume = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )

        try await engine.setVolume(testDataset, for: [axial, coronal, sagittal, volume])

        let textureIDs = await [
            engine.debugTextureObjectIdentifier(for: axial),
            engine.debugTextureObjectIdentifier(for: coronal),
            engine.debugTextureObjectIdentifier(for: sagittal),
            engine.debugTextureObjectIdentifier(for: volume)
        ]
        let handles = await [
            engine.debugResourceHandle(for: axial),
            engine.debugResourceHandle(for: coronal),
            engine.debugResourceHandle(for: sagittal),
            engine.debugResourceHandle(for: volume)
        ].compactMap { $0 }
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount

        XCTAssertEqual(textureCount, 1)
        XCTAssertEqual(referenceCount, 4)
        XCTAssertEqual(Set(textureIDs.compactMap { $0 }).count, 1)
        XCTAssertEqual(handles.count, 4)
        XCTAssertEqual(Set(handles).count, 1)
    }

    func test_differentDatasets_createSeparateTextures() async throws {
        let first = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let second = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let otherDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: testDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 9
        )

        try await engine.setVolume(testDataset, for: first)
        try await engine.setVolume(otherDataset, for: second)

        let textureCount = await engine.debugResourceTextureCount
        XCTAssertEqual(textureCount, 2)
    }

    func test_resourceMetadata_describesCachedVolumeTexture() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )

        try await engine.setVolume(testDataset, for: viewport)

        let resourceMetadata = await engine.debugResourceMetadata(for: viewport)
        let metadata = try XCTUnwrap(resourceMetadata)
        XCTAssertEqual(metadata.resourceType, .volume)
        XCTAssertEqual(metadata.debugLabel, "MTKRenderingEngine.VolumeTexture3D")
        XCTAssertEqual(metadata.pixelFormat, .r16Sint)
        XCTAssertEqual(metadata.dimensions.width, testDataset.dimensions.width)
        XCTAssertEqual(metadata.dimensions.height, testDataset.dimensions.height)
        XCTAssertEqual(metadata.dimensions.depth, testDataset.dimensions.depth)
        XCTAssertEqual(metadata.estimatedBytes, ResourceMemoryEstimator.estimate(for: testDataset))
    }

    func test_gpuResourceMetrics_reportsEstimatedVolumeMemory() async throws {
        let axial = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let coronal = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal),
                               initialSize: CGSize(width: 32, height: 32))
        )

        try await engine.setVolume(testDataset, for: [axial, coronal])

        let metrics = await engine.resourceMetrics()
        let debugBreakdown = await engine.debugMemoryBreakdown
        let debugOutputPoolTextureCount = await engine.debugOutputPoolTextureCount
        let debugOutputPoolInUseCount = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(metrics.volumeTextureCount, 1)
        XCTAssertEqual(metrics.transferTextureCount, 0)
        XCTAssertEqual(metrics.outputTexturePoolSize, 0)
        XCTAssertEqual(metrics.breakdown.volumeTextures, ResourceMemoryEstimator.estimate(for: testDataset))
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: testDataset))
        XCTAssertEqual(debugBreakdown, metrics.breakdown)
        XCTAssertEqual(debugOutputPoolTextureCount, 0)
        XCTAssertEqual(debugOutputPoolInUseCount, 0)
    }

    func test_scalarVolumeLayerAssignedToMultipleViewportsSharesOneHandleAndTexture() async throws {
        let first = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let second = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let petDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: testDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 42
        )
        let petLayer = VolumeLayer(id: "pet",
                                   dataset: petDataset,
                                   transferFunction: .defaultGrayscale(for: petDataset),
                                   opacity: 0.5,
                                   blendMode: .additive)

        try await engine.setVolume(testDataset, for: [first, second])
        try await engine.configure([first, second], volumeLayers: [petLayer])

        let diagnostics = await engine.volumeLayerResourceSharingDiagnostics(for: [first, second])
        let metrics = await engine.resourceMetrics()
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(Set(diagnostics.map(\.handle)).count, 1)
        XCTAssertEqual(Set(diagnostics.map(\.textureObjectIdentifier)).count, 1)
        XCTAssertEqual(textureCount, 2)
        XCTAssertEqual(referenceCount, 4)
        XCTAssertEqual(metrics.volumeTextureCount, 2)
        XCTAssertEqual(metrics.breakdown.volumeTextures,
                       ResourceMemoryEstimator.estimate(for: testDataset) +
                       ResourceMemoryEstimator.estimate(for: petDataset))

        try await engine.configure([first, second], volumeLayers: [])
        let releasedDiagnostics = await engine.volumeLayerResourceSharingDiagnostics(for: [first, second])
        let releasedMetrics = await engine.resourceMetrics()
        let releasedTextureCount = await engine.debugResourceTextureCount
        let releasedReferenceCount = await engine.debugResourceReferenceCount
        XCTAssertTrue(releasedDiagnostics.isEmpty)
        XCTAssertEqual(releasedTextureCount, 1)
        XCTAssertEqual(releasedReferenceCount, 2)
        XCTAssertEqual(releasedMetrics.volumeTextureCount, 1)
    }

    func test_translatedScalarVolumeLayerTransformIsResampledBeforeResourceAcquisition() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let petDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: testDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 42
        )
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 1
        let petLayer = VolumeLayer(id: "translated-pet",
                                   dataset: petDataset,
                                   transferFunction: .defaultGrayscale(for: petDataset),
                                   baseWorldToLayerWorld: transform)

        try await engine.setVolume(testDataset, for: viewport)
        try await engine.configure(viewport, volumeLayers: [petLayer])

        let textureCount = await engine.debugResourceTextureCount
        let diagnostics = await engine.volumeLayerResourceSharingDiagnostics(for: [viewport])
        let storedLayers = await engine.debugVolumeLayers(for: viewport)
        XCTAssertEqual(textureCount, 2)
        XCTAssertEqual(diagnostics.map(\.layerID), ["translated-pet"])
        XCTAssertEqual(storedLayers?.first?.baseWorldToLayerWorld, matrix_identity_float4x4)
        XCTAssertEqual(storedLayers?.first?.scalarVolume?.dataset.dimensions, testDataset.dimensions)
    }

    func test_unsupportedScalarVolumeLayerTransformIsRejectedBeforeResourceAcquisition() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let petDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: testDataset.dimensions,
            pixelFormat: .int16Signed,
            seed: 42
        )
        let transform = simd_float4x4(columns: (
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        let petLayer = VolumeLayer(id: "rotated-pet",
                                   dataset: petDataset,
                                   transferFunction: .defaultGrayscale(for: petDataset),
                                   baseWorldToLayerWorld: transform)

        try await engine.setVolume(testDataset, for: viewport)

        do {
            try await engine.configure(viewport, volumeLayers: [petLayer])
            XCTFail("Expected unsupported scalar transform to be rejected")
        } catch let error as MTKRenderingEngine.EngineError {
            XCTAssertEqual(error, .unsupportedScalarLayerTransform("rotated-pet"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let textureCount = await engine.debugResourceTextureCount
        let diagnostics = await engine.volumeLayerResourceSharingDiagnostics(for: [viewport])
        XCTAssertEqual(textureCount, 1)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func test_replacingDataset_invalidatesPreviousTextureForViewport() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let otherDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Unsigned,
            seed: 7
        )

        try await engine.setVolume(testDataset, for: viewport)
        let firstViewportTextureID = await engine.debugTextureObjectIdentifier(for: viewport)
        let firstTextureID = try XCTUnwrap(firstViewportTextureID)

        try await engine.setVolume(otherDataset, for: viewport)
        let secondViewportTextureID = await engine.debugTextureObjectIdentifier(for: viewport)
        let secondTextureID = try XCTUnwrap(secondViewportTextureID)
        let resourceMetadata = await engine.debugResourceMetadata(for: viewport)
        let metadata = try XCTUnwrap(resourceMetadata)
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount
        let metrics = await engine.resourceMetrics()

        XCTAssertNotEqual(firstTextureID, secondTextureID)
        XCTAssertEqual(textureCount, 1)
        XCTAssertEqual(referenceCount, 1)
        XCTAssertEqual(metadata.pixelFormat, .r16Uint)
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: otherDataset))
    }

    func test_dataChangedDatasetSwapInvalidatesPreviousTextureForViewport() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let changedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: testDataset)

        try await engine.setVolume(testDataset, for: viewport)
        let firstTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewport)
        let firstTextureID = try XCTUnwrap(firstTextureIDValue)

        try await engine.setVolume(changedDataset, for: viewport)
        let secondTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewport)
        let secondTextureID = try XCTUnwrap(secondTextureIDValue)
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount
        let metrics = await engine.resourceMetrics()

        XCTAssertNotEqual(firstTextureID, secondTextureID)
        XCTAssertEqual(textureCount, 1)
        XCTAssertEqual(referenceCount, 1)
        XCTAssertEqual(metrics.volumeTextureCount, 1)
        XCTAssertEqual(metrics.breakdown.volumeTextures, ResourceMemoryEstimator.estimate(for: changedDataset))
    }

    func test_estimatedGPUMemoryBytesReflectsVolumeAndOutputAllocations() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )

        try await engine.setVolume(testDataset, for: viewport)
        _ = try await engine.debugAcquireOutputTextureIdentifier(width: 20,
                                                                 height: 10,
                                                                 pixelFormat: .bgra8Unorm)

        let estimatedMemoryBytes = await engine.estimatedGPUMemoryBytes
        let metrics = await engine.resourceMetrics()
        let expectedVolumeBytes = ResourceMemoryEstimator.estimate(for: testDataset)
        let expectedOutputBytes = ResourceMemoryEstimator.estimate(
            forOutputTexture: CGSize(width: 20, height: 10),
            pixelFormat: .bgra8Unorm
        )

        XCTAssertEqual(metrics.breakdown.volumeTextures, expectedVolumeBytes)
        XCTAssertEqual(metrics.breakdown.outputTextures, expectedOutputBytes)
        XCTAssertEqual(estimatedMemoryBytes, expectedVolumeBytes + expectedOutputBytes)
        XCTAssertEqual(metrics.estimatedMemoryBytes, estimatedMemoryBytes)
    }

    func test_outputTexturePoolIntegrationReusesReleasedTextureAcrossViewports() async throws {
        _ = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        _ = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal),
                               initialSize: CGSize(width: 32, height: 32))
        )

        let firstTextureID = try await engine.debugAcquireOutputTextureIdentifier(width: 32,
                                                                                  height: 32,
                                                                                  pixelFormat: .bgra8Unorm,
                                                                                  releaseImmediately: true)
        let secondTextureID = try await engine.debugAcquireOutputTextureIdentifier(width: 32,
                                                                                   height: 32,
                                                                                   pixelFormat: .bgra8Unorm,
                                                                                   releaseImmediately: true)
        let poolTextureCount = await engine.debugOutputPoolTextureCount
        let poolInUseCount = await engine.debugOutputPoolInUseCount
        let metrics = await engine.resourceMetrics()

        XCTAssertEqual(firstTextureID, secondTextureID)
        XCTAssertEqual(poolTextureCount, 1)
        XCTAssertEqual(poolInUseCount, 0)
        XCTAssertEqual(metrics.outputTexturePoolSize, 1)
        XCTAssertEqual(metrics.breakdown.outputTextures,
                       ResourceMemoryEstimator.estimate(forOutputTexture: CGSize(width: 32, height: 32),
                                                        pixelFormat: .bgra8Unorm))
    }

    func test_releaseLastViewport_deallocatesTexture() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)
        let textureCountAfterSetVolume = await engine.debugResourceTextureCount
        XCTAssertEqual(textureCountAfterSetVolume, 1)

        await engine.destroyViewport(viewport)

        let textureCountAfterDestroy = await engine.debugResourceTextureCount
        let referenceCountAfterDestroy = await engine.debugResourceReferenceCount
        let metricsAfterDestroy = await engine.resourceMetrics()
        XCTAssertEqual(textureCountAfterDestroy, 0)
        XCTAssertEqual(referenceCountAfterDestroy, 0)
        XCTAssertEqual(metricsAfterDestroy.estimatedMemoryBytes, 0)
    }

    func test_destroyViewportReleasesPendingOutputTextureLease() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        XCTAssertNotNil(frame.outputTextureLease)
        let poolInUseBeforeDestroy = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(poolInUseBeforeDestroy, 1)

        await engine.destroyViewport(viewport)

        XCTAssertTrue(frame.outputTextureLease?.isReleased ?? false)
        let poolInUseAfterDestroy = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(poolInUseAfterDestroy, 0)
        let releasedCount = await engine.debugOutputTextureLeaseReleasedCount
        XCTAssertEqual(releasedCount, 1)
    }

    func test_renderThenSimulatedPresentCompletionLeavesOutputPoolClean() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        let lease = try XCTUnwrap(frame.outputTextureLease)
        lease.markPresented()
        lease.release()

        let inUseCount = await engine.debugOutputPoolInUseCount
        let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
        let presentedCount = await engine.debugOutputTextureLeasePresentedCount
        XCTAssertEqual(inUseCount, 0)
        XCTAssertEqual(pendingLeaseCount, 0)
        XCTAssertEqual(presentedCount, 1)
    }

    func test_renderPreflightErrorDoesNotAcquireLease() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)
        try await engine.configure(
            viewport,
            transferFunction: VolumeTransferFunction(opacityPoints: [],
                                                     colourPoints: [])
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await self.engine.render(viewport)
        }

        let inUseCount = await engine.debugOutputPoolInUseCount
        let releasedCount = await engine.debugOutputTextureLeaseReleasedCount
        let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
        XCTAssertEqual(inUseCount, 0)
        XCTAssertEqual(releasedCount, 0)
        XCTAssertEqual(pendingLeaseCount, 0)
    }

    func test_renderErrorReleasesLease_postAcquireFailure() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)
        await engine.debugFailNextVolumeRenderAfterOutputLeaseAcquire()

        await XCTAssertThrowsErrorAsync {
            _ = try await self.engine.render(viewport)
        }

        let inUseCount = await engine.debugOutputPoolInUseCount
        let releasedCount = await engine.debugOutputTextureLeaseReleasedCount
        let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
        XCTAssertEqual(inUseCount, 0)
        XCTAssertEqual(releasedCount, 1)
        XCTAssertEqual(pendingLeaseCount, 0)

        let retryFrame = try await engine.render(viewport)
        retryFrame.outputTextureLease?.release()
    }

    func test_destroyViewportWithNoPendingFramesLeavesPoolClean() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        frame.outputTextureLease?.release()
        await engine.destroyViewport(viewport)

        let inUseCount = await engine.debugOutputPoolInUseCount
        let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
        XCTAssertEqual(inUseCount, 0)
        XCTAssertEqual(pendingLeaseCount, 0)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // Expected.
    }
}
