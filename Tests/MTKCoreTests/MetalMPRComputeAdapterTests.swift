//
//  MetalMPRComputeAdapterTests.swift
//  MTK
//
//  Unit tests for GPU-accelerated MPR slab generation adapter.
//  Validates compute pipeline, texture operations, blend modes, and command handling.
//
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
import Metal
import simd
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterTests: XCTestCase {
    private enum TestHelperError: Error {
        case sharedDataAllocationFailed(byteCount: Int)
    }

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!
    private var adapter: MetalMPRComputeAdapter!

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

        guard let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) else {
            throw XCTSkip("No bundled metallib present; expected on CI without GPU assets")
        }
        self.library = library

        let featureFlags = FeatureFlags.evaluate(for: device)
        let debugOptions = VolumeRenderingDebugOptions()
        self.adapter = MetalMPRComputeAdapter(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: featureFlags,
            debugOptions: debugOptions
        )
    }

    // MARK: - Initialization Tests

    func test_adapterInitializesSuccessfully() async {
        XCTAssertNotNil(adapter)
    }

    func test_adapterDetectsMPSAvailability() async {
        let mpsAvailable = await adapter.debugMPSAvailable
        // Just verify the property is accessible, actual availability depends on platform
        print("MPS available: \(mpsAvailable)")
    }

    // MARK: - Slab Generation Tests

    func test_makeSlabGeneratesValidSlice() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertEqual(slice.pixelFormat, dataset.pixelFormat)
        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.bytesPerRow, 0)
    }

    func test_makeSlabWithMaximumBlend() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithMinimumBlend() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .minimum
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithAverageBlend() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 10,
            steps: 10,
            blend: .average
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabSanitizesThickness() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        // Negative thickness should be sanitized
        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: -10,
            steps: 5,
            blend: .single
        )

        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
    }

    func test_makeSlabSanitizesSteps() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        // Zero steps should be sanitized
        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 0,
            blend: .single
        )

        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
    }

    // MARK: - Command Tests

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
        XCTAssertNotNil(overridesAfter.slabThickness)
        XCTAssertNotNil(overridesAfter.slabSteps)
    }

    func test_overridesApplyToNextSlab() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        try await adapter.send(.setBlend(.minimum))
        try await adapter.send(.setSlab(thickness: 15, steps: 10))

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        // Verify slice was generated (overrides were applied internally)
        XCTAssertFalse(slice.pixels.isEmpty)

        // Verify overrides are cleared after slab generation
        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
        XCTAssertNil(overridesAfter.slabThickness)
        XCTAssertNil(overridesAfter.slabSteps)
    }

    func test_overridesClearedAfterSlabGeneration() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        try await adapter.send(.setBlend(.maximum))

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
    }

    // MARK: - Snapshot Tests

    func test_lastSnapshotUpdatedAfterSlabGeneration() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let snapshotBefore = await adapter.debugLastSnapshot
        XCTAssertNil(snapshotBefore)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 3,
            blend: .average
        )

        let snapshotAfter = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshotAfter)
        XCTAssertEqual(snapshotAfter?.blend, .average)
        XCTAssertEqual(snapshotAfter?.thickness, 5)
        XCTAssertEqual(snapshotAfter?.steps, 3)
    }

    func test_snapshotCapturesIntensityRange() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot?.intensityRange)
    }

    // MARK: - Pixel Format Tests

    func test_makeSlabWithInt16SignedPixelFormat() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Signed)
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.pixelFormat, .int16Signed)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithInt16UnsignedPixelFormat() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Unsigned)
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.pixelFormat, .int16Unsigned)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    // MARK: - Edge Cases

    func test_makeSlabWithSmallDataset() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithLargeThickness() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 100,
            steps: 50,
            blend: .maximum
        )

        XCTAssertFalse(slice.pixels.isEmpty)
    }

    // MARK: - Texture Cache Tests

    func test_makeSlabReusesTextureForSameDataset() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .average
        )

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(cachedIdentity)
        XCTAssertEqual(cachedIdentity?.count, dataset.data.count)
        XCTAssertEqual(cachedIdentity?.dimensions, dataset.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_cachedTextureReuseAcrossIterations() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Signed)
        let plane = makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_makeSlabReusesOutputTextureForSameGeometry() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        for _ in 0..<3 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureReuseAcrossIterations() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Signed)
        let plane = makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)
    }

    func test_outputTextureReuseAcrossBlendModes() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Signed, seed: 7)
        let plane = makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let thickness = blendMode == .single ? 1 : 5
            let steps = blendMode == .single ? 1 : 5

            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )
            assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_concurrentMakeSlabUsesTemporaryOutputTextureFallback() async throws {
        let dataset = makeTestDataset(
            dimensions: VolumeDimensions(width: 96, height: 96, depth: 96),
            pixelFormat: .int16Signed,
            seed: 29
        )
        let plane = makeTestPlaneGeometry(for: dataset)

        async let firstSlice = adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )
        async let secondSlice = adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )

        let (first, second) = try await (firstSlice, secondSlice)
        assertValidSlice(first, expectedWidth: 96, expectedHeight: 96)
        assertValidSlice(second, expectedWidth: 96, expectedHeight: 96)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 96)
        XCTAssertEqual(cachedShape?.height, 96)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureInvalidatesOnDimensionChange() async throws {
        let dataset = makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 5
        )
        let axialPlane = makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = makeTestPlaneGeometry(for: dataset, axis: .x)

        let axialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        assertValidSlice(axialSlice, expectedWidth: 48, expectedHeight: 32)

        let sagittalSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        assertValidSlice(sagittalSlice, expectedWidth: 32, expectedHeight: 24)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 32)
        XCTAssertEqual(cachedShape?.height, 24)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureShapeUpdatesOnInvalidation() async throws {
        let dataset = makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Unsigned,
            seed: 19
        )
        let axialPlane = makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = makeTestPlaneGeometry(for: dataset, axis: .x)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let initialShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(initialShape?.width, 48)
        XCTAssertEqual(initialShape?.height, 32)
        XCTAssertEqual(initialShape?.pixelFormat, dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let updatedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(updatedShape?.width, 32)
        XCTAssertEqual(updatedShape?.height, 24)
        XCTAssertEqual(updatedShape?.pixelFormat, dataset.pixelFormat)
        XCTAssertNotEqual(updatedShape?.width, initialShape?.width)
        XCTAssertNotEqual(updatedShape?.height, initialShape?.height)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)
    }

    func test_outputTextureInvalidatesOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try makeSharedTestData(dimensions: dimensions, pixelFormat: .int16Unsigned, seed: 11)
        let unsignedDataset = makeTestDataset(data: sharedData.data,
                                              dimensions: dimensions,
                                              pixelFormat: .int16Unsigned)
        let signedDataset = makeTestDataset(data: sharedData.data,
                                            dimensions: dimensions,
                                            pixelFormat: .int16Signed)
        let plane = makeTestPlaneGeometry(for: unsignedDataset)

        _ = try await adapter.makeSlab(
            dataset: unsignedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        _ = try await adapter.makeSlab(
            dataset: signedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, .int16Signed)
    }

    func test_makeSlabInvalidatesCacheOnDimensionChange() async throws {
        let dimensionsA = VolumeDimensions(width: 64, height: 64, depth: 64)
        let dimensionsB = VolumeDimensions(width: 32, height: 64, depth: 128)
        let sharedData = try makeSharedTestData(dimensions: dimensionsA, pixelFormat: .int16Unsigned, seed: 17)
        let datasetA = makeTestDataset(data: sharedData.data, dimensions: dimensionsA, pixelFormat: .int16Unsigned)
        let datasetB = makeTestDataset(data: sharedData.data, dimensions: dimensionsB, pixelFormat: .int16Unsigned)
        let planeA = makeTestPlaneGeometry(for: datasetA)
        let planeB = makeTestPlaneGeometry(for: datasetB)

        _ = try await adapter.makeSlab(
            dataset: datasetA,
            plane: planeA,
            thickness: 5,
            steps: 5,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        _ = try await adapter.makeSlab(
            dataset: datasetB,
            plane: planeB,
            thickness: 5,
            steps: 5,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(cachedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(cachedIdentity?.dimensions, datasetB.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, datasetB.pixelFormat)
        XCTAssertNotEqual(cachedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(cachedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnDataChange() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        let mutatedDataset = makeDataChangedDataset(from: dataset)
        _ = try await adapter.makeSlab(
            dataset: mutatedDataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, mutatedDataset.data.count)
        XCTAssertEqual(updatedIdentity?.dimensions, mutatedDataset.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, mutatedDataset.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try makeSharedTestData(dimensions: dimensions, pixelFormat: .int16Unsigned, seed: 23)
        let datasetA = makeTestDataset(data: sharedData.data, dimensions: dimensions, pixelFormat: .int16Unsigned)
        let datasetB = makeTestDataset(data: sharedData.data, dimensions: dimensions, pixelFormat: .int16Signed)
        let planeA = makeTestPlaneGeometry(for: datasetA)
        let planeB = makeTestPlaneGeometry(for: datasetB)

        _ = try await adapter.makeSlab(
            dataset: datasetA,
            plane: planeA,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        _ = try await adapter.makeSlab(
            dataset: datasetB,
            plane: planeB,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertNotEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(updatedIdentity?.dimensions, dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, .int16Signed)
        XCTAssertEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnInPlaceDataMutation() async throws {
        let sharedData = try makeSharedTestData(pixelFormat: .int16Signed, seed: 31)
        let dataset = makeTestDataset(data: sharedData.data, pixelFormat: .int16Signed)
        let plane = makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        mutateSharedTestDataInPlace(sharedData.storage, pixelFormat: dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    // MARK: - Multiple Slab Generation

    func test_multipleSlabGenerationsSucceed() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        for _ in 0..<3 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .single
            )
            XCTAssertFalse(slice.pixels.isEmpty)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_multipleSlabsWithDifferentBlendModes() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: blendMode
            )
            XCTAssertFalse(slice.pixels.isEmpty)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_sliceCorrectnessAfterTextureReuse() async throws {
        let dataset = makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 3
        )
        let axialPlane = makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = makeTestPlaneGeometry(for: dataset, axis: .x)

        let axialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        assertValidSlice(axialSlice, expectedWidth: 48, expectedHeight: 32)

        let repeatedAxialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        XCTAssertEqual(repeatedAxialSlice.pixels, axialSlice.pixels)
        XCTAssertEqual(repeatedAxialSlice.intensityRange, axialSlice.intensityRange)
        assertValidSlice(repeatedAxialSlice, expectedWidth: 48, expectedHeight: 32)

        let sagittalSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )
        assertValidSlice(sagittalSlice, expectedWidth: 32, expectedHeight: 24)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 2)
    }

    func test_sliceCorrectnessAcrossBlendModes() async throws {
        let dataset = makeTestDataset(pixelFormat: .int16Signed, seed: 9)
        let plane = makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let thickness = blendMode == .single ? 1 : 5
            let steps = blendMode == .single ? 1 : 5

            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )

            assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_outputTextureAllocationReductionDemonstrated() async throws {
        let dataset = makeTestDataset(
            dimensions: VolumeDimensions(width: 16, height: 16, depth: 16),
            pixelFormat: .int16Unsigned,
            seed: 13
        )
        let plane = makeTestPlaneGeometry(for: dataset)
        var lastSlice: MPRSlice?

        for _ in 0..<100 {
            lastSlice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 3,
                steps: 3,
                blend: .average
            )
        }

        if let lastSlice {
            assertValidSlice(lastSlice, expectedWidth: 16, expectedHeight: 16)
        } else {
            XCTFail("Expected at least one generated slice")
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)
        // Before output texture caching, this loop would allocate one output texture per slab.
        print("Output texture allocations: \(allocationCount) (vs 100 without caching)")
    }

    // MARK: - Pixel Spacing Tests

    func test_sliceContainsPixelSpacing() async throws {
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertNotNil(slice.pixelSpacing)
        if let spacing = slice.pixelSpacing {
            XCTAssertGreaterThan(spacing.x, 0)
            XCTAssertGreaterThan(spacing.y, 0)
        }
    }

    // MARK: - Axis Detection Tests

    func test_dominantAxisDetection() async throws {
        let dataset = makeTestDataset()

        // Test axial plane (Z-dominant)
        let axialPlane = makeTestPlaneGeometry(for: dataset, axis: .z)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let axialSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(axialSnapshot?.axis, .z)

        // Test sagittal plane (X-dominant)
        let sagittalPlane = makeTestPlaneGeometry(for: dataset, axis: .x)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let sagittalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(sagittalSnapshot?.axis, .x)

        // Test coronal plane (Y-dominant)
        let coronalPlane = makeTestPlaneGeometry(for: dataset, axis: .y)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: coronalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let coronalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(coronalSnapshot?.axis, .y)
    }

    // MARK: - Helpers

    private func makeTestDataset(data overrideData: Data? = nil,
                                 dimensions: VolumeDimensions = VolumeDimensions(width: 64, height: 64, depth: 64),
                                 pixelFormat: VolumePixelFormat = .int16Unsigned,
                                 seed: Int = 0) -> VolumeDataset {
        let data = overrideData ?? {
            switch pixelFormat {
            case .int16Signed:
                let values: [Int16] = (0..<dimensions.voxelCount).map {
                    Int16((($0 + seed) % 2048) - 1024)
                }
                return values.withUnsafeBytes { Data($0) }
            case .int16Unsigned:
                let values: [UInt16] = (0..<dimensions.voxelCount).map {
                    UInt16(($0 + seed) % 4096)
                }
                return values.withUnsafeBytes { Data($0) }
            }
        }()

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1.0, y: 1.0, z: 1.0),
            pixelFormat: pixelFormat
        )
    }

    private func makeDataChangedDataset(from dataset: VolumeDataset) -> VolumeDataset {
        var mutatedDataset = dataset

        switch dataset.pixelFormat {
        case .int16Signed:
            var mutatedValues = Array(repeating: Int16.zero, count: dataset.voxelCount)
            _ = mutatedValues.withUnsafeMutableBytes { mutableBytes in
                dataset.data.copyBytes(to: mutableBytes)
            }
            if let firstValue = mutatedValues.first {
                mutatedValues[0] = firstValue == .max ? .min : firstValue &+ 1
            }
            mutatedDataset.data = mutatedValues.withUnsafeBytes { Data($0) }

        case .int16Unsigned:
            var mutatedValues = Array(repeating: UInt16.zero, count: dataset.voxelCount)
            _ = mutatedValues.withUnsafeMutableBytes { mutableBytes in
                dataset.data.copyBytes(to: mutableBytes)
            }
            if let firstValue = mutatedValues.first {
                mutatedValues[0] = firstValue &+ 1
            }
            mutatedDataset.data = mutatedValues.withUnsafeBytes { Data($0) }
        }

        return mutatedDataset
    }

    private func makeSharedTestData(dimensions: VolumeDimensions = VolumeDimensions(width: 64, height: 64, depth: 64),
                                    pixelFormat: VolumePixelFormat = .int16Unsigned,
                                    seed: Int = 0) throws -> (data: Data, storage: NSMutableData) {
        let byteCount = dimensions.voxelCount * pixelFormat.bytesPerVoxel
        guard let storage = NSMutableData(length: byteCount) else {
            throw TestHelperError.sharedDataAllocationFailed(byteCount: byteCount)
        }

        switch pixelFormat {
        case .int16Signed:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: Int16.self)
            for index in 0..<dimensions.voxelCount {
                pointer[index] = Int16((index + seed) % 2048 - 1024)
            }
        case .int16Unsigned:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: UInt16.self)
            for index in 0..<dimensions.voxelCount {
                pointer[index] = UInt16((index + seed) % 4096)
            }
        }

        return (data: Data(referencing: storage), storage: storage)
    }

    private func mutateSharedTestDataInPlace(_ storage: NSMutableData,
                                             pixelFormat: VolumePixelFormat) {
        switch pixelFormat {
        case .int16Signed:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: Int16.self)
            pointer[0] = pointer[0] == .max ? .min : pointer[0] &+ 1
        case .int16Unsigned:
            let pointer = storage.mutableBytes.assumingMemoryBound(to: UInt16.self)
            pointer[0] = pointer[0] &+ 1
        }
    }

    private func assertValidSlice(_ slice: MPRSlice,
                                  expectedWidth: Int,
                                  expectedHeight: Int,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(slice.width, expectedWidth, file: file, line: line)
        XCTAssertEqual(slice.height, expectedHeight, file: file, line: line)
        XCTAssertFalse(slice.pixels.isEmpty, file: file, line: line)
        XCTAssertTrue(slice.pixels.contains(where: { $0 != 0 }), file: file, line: line)
        XCTAssertGreaterThan(slice.bytesPerRow, 0, file: file, line: line)
    }

    private func makeTestPlaneGeometry(for dataset: VolumeDataset, axis: MPRPlaneAxis = .z) -> MPRPlaneGeometry {
        let dims = dataset.dimensions
        let centerVoxel = SIMD3<Float>(
            Float(dims.width) / 2.0,
            Float(dims.height) / 2.0,
            Float(dims.depth) / 2.0
        )

        let (axisU, axisV, normal): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        switch axis {
        case .x:
            // Sagittal plane (normal along X)
            axisU = SIMD3<Float>(0, Float(dims.height), 0)
            axisV = SIMD3<Float>(0, 0, Float(dims.depth))
            normal = SIMD3<Float>(1, 0, 0)
        case .y:
            // Coronal plane (normal along Y)
            axisU = SIMD3<Float>(Float(dims.width), 0, 0)
            axisV = SIMD3<Float>(0, 0, Float(dims.depth))
            normal = SIMD3<Float>(0, 1, 0)
        case .z:
            // Axial plane (normal along Z)
            axisU = SIMD3<Float>(Float(dims.width), 0, 0)
            axisV = SIMD3<Float>(0, Float(dims.height), 0)
            normal = SIMD3<Float>(0, 0, 1)
        }

        // Texture space coordinates (normalized [0,1])
        let originTexture = SIMD3<Float>(0, 0, 0)
        let axisUTexture = axisU / SIMD3<Float>(
            Float(dims.width),
            Float(dims.height),
            Float(dims.depth)
        )
        let axisVTexture = axisV / SIMD3<Float>(
            Float(dims.width),
            Float(dims.height),
            Float(dims.depth)
        )

        // World space (same as voxel space for this test)
        return MPRPlaneGeometry(
            originVoxel: centerVoxel - axisU / 2 - axisV / 2,
            axisUVoxel: axisU,
            axisVVoxel: axisV,
            originWorld: centerVoxel - axisU / 2 - axisV / 2,
            axisUWorld: axisU,
            axisVWorld: axisV,
            originTexture: originTexture,
            axisUTexture: axisUTexture,
            axisVTexture: axisVTexture,
            normalWorld: normal
        )
    }
}
