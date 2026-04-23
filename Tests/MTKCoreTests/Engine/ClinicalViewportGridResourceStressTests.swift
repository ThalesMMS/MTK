import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

private typealias ClinicalViewportSet = (
    axial: ViewportID,
    coronal: ViewportID,
    sagittal: ViewportID,
    volume3D: ViewportID
)

final class ClinicalViewportGridResourceStressTests: MTKRenderingEngineTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ClinicalProfiler.shared.reset()
    }

    override func tearDown() async throws {
        _ = ClinicalProfiler.shared.endSession()
        try await super.tearDown()
    }

    func test_sharedDatasetCreatesOneTextureWithFourReferences() async throws {
        let viewports = try await createClinicalViewports()
        let viewportIDs = viewportIDs(for: viewports)

        let sharedHandleValue = try await engine.setVolume(testDataset, for: viewportIDs)
        let sharedHandle = try XCTUnwrap(sharedHandleValue)
        let (resolvedHandle, resolvedTextureID) = try await assertSharedVolumeResource(for: viewports,
                                                                                       expectedReferenceCount: 4)

        XCTAssertEqual(resolvedHandle, sharedHandle)
        XCTAssertNotNil(resolvedTextureID)
    }

    func test_renderAndPresentReleasesOutputTexturesForAllViewports() async throws {
        let viewports = try await createClinicalViewports()
        try await engine.setVolume(testDataset, for: viewportIDs(for: viewports))

        for _ in 0..<3 {
            let frames = try await renderAllViewports(viewports)
            let inUseDuringFrameSet = await engine.debugOutputPoolInUseCount

            // The clinical 2x2 layout has one raycast viewport and three MPR
            // viewports. Only the raycast viewport uses the pooled output lease.
            XCTAssertEqual(frames.compactMap(\.outputTextureLease).count, 1)
            XCTAssertEqual(inUseDuringFrameSet, 1)

            presentAndRelease(frames)

            let inUseAfterPresent = await engine.debugOutputPoolInUseCount
            let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
            XCTAssertEqual(inUseAfterPresent, 0)
            XCTAssertEqual(pendingLeaseCount, 0)
        }

        let poolTextureCount = await engine.debugOutputPoolTextureCount
        XCTAssertEqual(poolTextureCount, 1)
    }

    func test_resizeDoesNotDuplicateVolumeTexture() async throws {
        let viewports = try await createClinicalViewports()
        try await engine.setVolume(testDataset, for: viewportIDs(for: viewports))

        let initialTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.axial)
        let initialTextureID = try XCTUnwrap(initialTextureIDValue)
        let initialTextureCount = await engine.debugResourceTextureCount
        XCTAssertEqual(initialTextureCount, 1)

        for viewport in viewportIDs(for: viewports) {
            try await engine.resize(viewport, to: .init(width: 64, height: 64))
        }

        let frames = try await renderAllViewports(viewports)
        presentAndRelease(frames)

        let resizedTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.axial)
        let resizedTextureID = try XCTUnwrap(resizedTextureIDValue)
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount
        let outputPoolInUseCount = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(initialTextureID, resizedTextureID)
        XCTAssertEqual(textureCount, 1)
        XCTAssertEqual(referenceCount, 4)
        XCTAssertEqual(outputPoolInUseCount, 0)
    }

    func test_datasetSwapInvalidatesOldResourceAndCreatesNewShared() async throws {
        let viewports = try await createClinicalViewports()
        let viewportIDs = viewportIDs(for: viewports)

        let oldHandleValue = try await engine.setVolume(testDataset, for: viewportIDs)
        let oldHandle = try XCTUnwrap(oldHandleValue)
        let oldTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.volume3D)
        let oldTextureID = try XCTUnwrap(oldTextureIDValue)
        let swappedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: testDataset)

        let newHandleValue = try await engine.setVolume(swappedDataset, for: viewportIDs)
        let newHandle = try XCTUnwrap(newHandleValue)
        let (_, newTextureID) = try await assertSharedVolumeResource(for: viewports,
                                                                     expectedReferenceCount: 4)

        XCTAssertNotEqual(newHandle, oldHandle)
        XCTAssertNotEqual(newTextureID, oldTextureID)
    }

    func test_destroyViewportsDecrementsRefcountAndReleasesOnLast() async throws {
        let viewports = try await createClinicalViewports()
        let viewportIDs = viewportIDs(for: viewports)

        try await engine.setVolume(testDataset, for: viewportIDs)
        let initialTextureCount = await engine.debugResourceTextureCount
        let initialReferenceCount = await engine.debugResourceReferenceCount

        XCTAssertEqual(initialTextureCount, 1)
        XCTAssertEqual(initialReferenceCount, 4)

        for expectedReferenceCount in stride(from: 3, through: 1, by: -1) {
            let viewport = viewportIDs[3 - expectedReferenceCount]
            await engine.destroyViewport(viewport)
            let textureCount = await engine.debugResourceTextureCount
            let referenceCount = await engine.debugResourceReferenceCount
            XCTAssertEqual(textureCount, 1)
            XCTAssertEqual(referenceCount, expectedReferenceCount)
        }

        await engine.destroyViewport(viewports.volume3D)

        let viewportCount = await engine.debugViewportCount
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount
        XCTAssertEqual(viewportCount, 0)
        XCTAssertEqual(textureCount, 0)
        XCTAssertEqual(referenceCount, 0)
    }

    func test_fullLifecycleStressLoopDoesNotAccumulateResources() async throws {
        let iterationCount = 5
        let expectedRendersPerIteration = 12
        await engine.setProfilingOptions(.init(measureRenderTime: true))
        ClinicalProfiler.shared.reset()

        var postIterationMemoryBytes: [Int] = []
        var postIterationPoolTextureCounts: [Int] = []

        for iteration in 0..<iterationCount {
            let viewports = try await createClinicalViewports()
            let viewportIDs = viewportIDs(for: viewports)
            let initialHandleValue = try await engine.setVolume(testDataset, for: viewportIDs)
            let initialHandle = try XCTUnwrap(initialHandleValue)
            let initialTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.axial)
            let initialTextureID = try XCTUnwrap(initialTextureIDValue)

            let firstFrames = try await renderAllViewports(viewports)
            let firstInUseCount = await engine.debugOutputPoolInUseCount
            XCTAssertEqual(firstInUseCount, 1)
            presentAndRelease(firstFrames)
            let firstPostPresentInUseCount = await engine.debugOutputPoolInUseCount
            XCTAssertEqual(firstPostPresentInUseCount, 0)

            for viewport in viewportIDs {
                try await engine.resize(viewport, to: .init(width: 64, height: 64))
            }

            let resizedFrames = try await renderAllViewports(viewports)
            presentAndRelease(resizedFrames)
            let resizedTextureCount = await engine.debugResourceTextureCount
            let resizedReferenceCount = await engine.debugResourceReferenceCount
            let resizedInUseCount = await engine.debugOutputPoolInUseCount
            let resizedTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.axial)
            let resizedTextureID = try XCTUnwrap(resizedTextureIDValue)
            XCTAssertEqual(resizedTextureCount, 1)
            XCTAssertEqual(resizedReferenceCount, 4)
            XCTAssertEqual(resizedInUseCount, 0)
            XCTAssertEqual(resizedTextureID, initialTextureID)

            let swappedDataset = VolumeDatasetTestFactory.makeTestDataset(
                dimensions: testDataset.dimensions,
                spacing: testDataset.spacing,
                pixelFormat: testDataset.pixelFormat,
                orientation: testDataset.orientation,
                seed: iteration + 1
            )
            let swappedHandleValue = try await engine.setVolume(swappedDataset, for: viewportIDs)
            let swappedHandle = try XCTUnwrap(swappedHandleValue)
            let swappedTextureIDValue = await engine.debugTextureObjectIdentifier(for: viewports.axial)
            let swappedTextureID = try XCTUnwrap(swappedTextureIDValue)

            XCTAssertNotEqual(swappedHandle, initialHandle)
            XCTAssertNotEqual(swappedTextureID, initialTextureID)
            _ = try await assertSharedVolumeResource(for: viewports, expectedReferenceCount: 4)

            let swappedFrames = try await renderAllViewports(viewports)
            presentAndRelease(swappedFrames)

            for viewport in viewportIDs {
                await engine.destroyViewport(viewport)
            }

            let viewportCount = await engine.debugViewportCount
            let textureCount = await engine.debugResourceTextureCount
            let referenceCount = await engine.debugResourceReferenceCount
            let inUseCount = await engine.debugOutputPoolInUseCount
            let pendingLeaseCount = await engine.debugOutputTextureLeasePendingCount
            XCTAssertEqual(viewportCount, 0)
            XCTAssertEqual(textureCount, 0)
            XCTAssertEqual(referenceCount, 0)
            XCTAssertEqual(inUseCount, 0)
            XCTAssertEqual(pendingLeaseCount, 0)

            postIterationMemoryBytes.append(await engine.estimatedGPUMemoryBytes)
            postIterationPoolTextureCounts.append(await engine.debugOutputPoolTextureCount)
        }

        let stableMemoryCeiling = try XCTUnwrap(postIterationMemoryBytes.first)
        let stablePoolTextureCount = try XCTUnwrap(postIterationPoolTextureCounts.first)
        for memoryBytes in postIterationMemoryBytes.dropFirst() {
            XCTAssertLessThanOrEqual(memoryBytes, stableMemoryCeiling)
        }
        for poolTextureCount in postIterationPoolTextureCounts.dropFirst() {
            XCTAssertLessThanOrEqual(poolTextureCount, stablePoolTextureCount)
        }

        let profilingSession = ClinicalProfiler.shared.endSession()
        let memorySnapshots = profilingSession.samples.filter { $0.stageType == .memorySnapshot }

        XCTAssertEqual(memorySnapshots.count, iterationCount * expectedRendersPerIteration)
        XCTAssertTrue(memorySnapshots.allSatisfy { ($0.memoryEstimateBytes ?? -1) >= 0 })
    }

    private func createClinicalViewports() async throws -> ClinicalViewportSet {
        (
            axial: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .axial),
                                   initialSize: .init(width: 32, height: 32))
            ),
            coronal: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .coronal),
                                   initialSize: .init(width: 32, height: 32))
            ),
            sagittal: try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .sagittal),
                                   initialSize: .init(width: 32, height: 32))
            ),
            volume3D: try await engine.createViewport(
                ViewportDescriptor(type: .volume3D,
                                   initialSize: .init(width: 32, height: 32))
            )
        )
    }

    private func viewportIDs(for viewports: ClinicalViewportSet) -> [ViewportID] {
        [viewports.axial, viewports.coronal, viewports.sagittal, viewports.volume3D]
    }

    private func renderAllViewports(_ viewports: ClinicalViewportSet) async throws -> [RenderFrame] {
        try await [
            engine.render(viewports.axial),
            engine.render(viewports.coronal),
            engine.render(viewports.sagittal),
            engine.render(viewports.volume3D)
        ]
    }

    private func presentAndRelease(_ frames: [RenderFrame]) {
        for frame in frames {
            frame.outputTextureLease?.markPresented()
            frame.outputTextureLease?.release()
        }
    }

    @discardableResult
    private func assertSharedVolumeResource(
        for viewports: ClinicalViewportSet,
        expectedReferenceCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (VolumeResourceHandle, ObjectIdentifier) {
        let handles = await [
            engine.debugResourceHandle(for: viewports.axial),
            engine.debugResourceHandle(for: viewports.coronal),
            engine.debugResourceHandle(for: viewports.sagittal),
            engine.debugResourceHandle(for: viewports.volume3D)
        ].compactMap { $0 }
        let textureIDs = await [
            engine.debugTextureObjectIdentifier(for: viewports.axial),
            engine.debugTextureObjectIdentifier(for: viewports.coronal),
            engine.debugTextureObjectIdentifier(for: viewports.sagittal),
            engine.debugTextureObjectIdentifier(for: viewports.volume3D)
        ].compactMap { $0 }
        let textureCount = await engine.debugResourceTextureCount
        let referenceCount = await engine.debugResourceReferenceCount

        XCTAssertEqual(handles.count, 4, file: file, line: line)
        XCTAssertEqual(Set(handles).count, 1, file: file, line: line)
        XCTAssertEqual(textureIDs.count, 4, file: file, line: line)
        XCTAssertEqual(Set(textureIDs).count, 1, file: file, line: line)
        XCTAssertEqual(textureCount, 1, file: file, line: line)
        XCTAssertEqual(referenceCount, expectedReferenceCount, file: file, line: line)

        return (try XCTUnwrap(handles.first, file: file, line: line),
                try XCTUnwrap(textureIDs.first, file: file, line: line))
    }
}
