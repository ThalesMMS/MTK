//
//  MetalMPRComputeAdapterStateTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter command and snapshot state.
//

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterStateTests: MetalMPRComputeAdapterTestCase {

    func test_sendSetBlendCommandUpdatesOverride() async throws {
        let overridesBefore = await adapter.debugOverrides
        XCTAssertNil(overridesBefore.blend)

        try await adapter.send(.setBlend(.maximum))

        let overridesAfter = await adapter.debugOverrides
        XCTAssertEqual(overridesAfter.blend, .maximum)
    }

    func test_sendSetSlabCommandUpdatesOverrides() async throws {
        let overridesBefore = await adapter.debugOverrides
        XCTAssertNil(overridesBefore.slabThickness)
        XCTAssertNil(overridesBefore.slabSteps)

        try await adapter.send(.setSlab(thickness: 10, steps: 5))

        let overridesAfter = await adapter.debugOverrides
        XCTAssertEqual(overridesAfter.slabThickness, 10)
        XCTAssertEqual(overridesAfter.slabSteps, 5)
    }

    func test_overridesApplyToNextFrame() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        try await adapter.send(.setBlend(.minimum))
        try await adapter.send(.setSlab(thickness: 15, steps: 10))

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(snapshot?.blend, .minimum)
        XCTAssertEqual(snapshot?.thickness, 15)
        XCTAssertEqual(snapshot?.steps, 10)

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
        XCTAssertNil(overridesAfter.slabThickness)
        XCTAssertNil(overridesAfter.slabSteps)
    }

    func test_overridesClearedAfterFrameGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        try await adapter.send(.setBlend(.maximum))
        _ = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
    }

    func test_lastSnapshotUpdatedAfterFrameGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let snapshotBefore = await adapter.debugLastSnapshot
        XCTAssertNil(snapshotBefore)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 5,
            steps: 3,
            blend: .average
        )
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.blend, .average)
        XCTAssertEqual(snapshot?.thickness, 5)
        XCTAssertEqual(snapshot?.steps, 3)
        XCTAssertEqual(snapshot?.intensityRange, dataset.intensityRange)
    }

    func test_pipelineCreationFailureIsMemoizedWithoutAllocatingOutputTexture() async throws {
        let counter = PipelineStateFactoryCounter()
        let failingAdapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: FeatureFlags.evaluate(for: device),
            debugOptions: VolumeRenderingDebugOptions(),
            pipelineStateFactory: { descriptor in
                try counter.makePipelineState(descriptor)
            }
        )
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        for _ in 0..<2 {
            do {
                _ = try await failingAdapter.makeSlabTexture(
                    dataset: dataset,
                    volumeTexture: volumeTexture,
                    plane: plane,
                    thickness: 1,
                    steps: 1,
                    blend: .single
                )
                XCTFail("Expected MPR pipeline creation to fail")
            } catch MetalMPRComputeAdapter.ComputeError.pipelineUnavailable {
                continue
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(counter.count, 1)
        let unavailablePipelineNames = await failingAdapter.debugUnavailablePipelineNames
        let outputTextureAllocationCount = await failingAdapter.debugOutputTextureAllocationCount
        XCTAssertEqual(unavailablePipelineNames, ["computeMPRSlabUnsigned"])
        XCTAssertEqual(outputTextureAllocationCount, 0)
    }

    func test_makeTextureFrameWithSmallDataset() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)
        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertGreaterThan(frame.texture.width, 0)
        XCTAssertGreaterThan(frame.texture.height, 0)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, frame.texture.width * frame.texture.height)
        XCTAssertEqual(frame.intensityRange, dataset.intensityRange)
    }

    func test_makeSlabTextureWithLargeThickness() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 100,
            steps: 50,
            blend: .maximum
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
    }
}

private final class PipelineStateFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func makePipelineState(_ descriptor: MTLComputePipelineDescriptor) throws -> MTLComputePipelineState {
        _ = descriptor
        lock.lock()
        callCount += 1
        lock.unlock()
        throw PipelineStateFactoryError()
    }
}

private struct PipelineStateFactoryError: Error {}
