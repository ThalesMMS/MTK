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

    private func makeTestDataset(pixelFormat: VolumePixelFormat = .int16Unsigned) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)

        let data: Data
        switch pixelFormat {
        case .int16Signed:
            let values: [Int16] = (0..<dimensions.voxelCount).map { Int16($0 % 2048 - 1024) }
            data = values.withUnsafeBytes { Data($0) }
        case .int16Unsigned:
            let values: [UInt16] = (0..<dimensions.voxelCount).map { UInt16($0 % 4096) }
            data = values.withUnsafeBytes { Data($0) }
        }

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1.0, y: 1.0, z: 1.0),
            pixelFormat: pixelFormat
        )
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

    private func makeBenchmarkAdapter() throws -> MetalMPRAdapter {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable for benchmark")
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue for benchmark")
        }

        guard let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) else {
            throw XCTSkip("No bundled metallib present for benchmark")
        }

        let debugOptions = VolumeRenderingDebugOptions()
        return MetalMPRAdapter(
            device: device,
            commandQueue: commandQueue,
            library: library,
            debugOptions: debugOptions
        )
    }
}

// MARK: - Performance Benchmarks

extension MetalMPRComputeAdapterTests {
    /// Benchmark GPU vs CPU for 10mm slab thickness (target: 2x+ speedup)
    func testPerformanceGPUvsCPU_10mm() async throws {
        let benchmarkAdapter = try makeBenchmarkAdapter()
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)
        let thickness = 10
        let steps = 10

        // Warmup run for GPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark GPU path
        let gpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let gpuDuration = CFAbsoluteTimeGetCurrent() - gpuStart

        // Switch to CPU path
        await benchmarkAdapter.setForceCPU(true)

        // Warmup run for CPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark CPU path
        let cpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let cpuDuration = CFAbsoluteTimeGetCurrent() - cpuStart

        let speedup = cpuDuration / gpuDuration

        print("""
        Performance Benchmark - 10mm slab:
          GPU: \(String(format: "%.2f", gpuDuration * 1000))ms
          CPU: \(String(format: "%.2f", cpuDuration * 1000))ms
          Speedup: \(String(format: "%.2f", speedup))x
        """)

        XCTAssertGreaterThan(speedup, 2.0, "GPU should be at least 2x faster than CPU for 10mm slab (actual: \(String(format: "%.2f", speedup))x)")
    }

    /// Benchmark GPU vs CPU for 20mm slab thickness
    func testPerformanceGPUvsCPU_20mm() async throws {
        let benchmarkAdapter = try makeBenchmarkAdapter()
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)
        let thickness = 20
        let steps = 20

        // Warmup run for GPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark GPU path
        let gpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let gpuDuration = CFAbsoluteTimeGetCurrent() - gpuStart

        // Switch to CPU path
        await benchmarkAdapter.setForceCPU(true)

        // Warmup run for CPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark CPU path
        let cpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let cpuDuration = CFAbsoluteTimeGetCurrent() - cpuStart

        let speedup = cpuDuration / gpuDuration

        print("""
        Performance Benchmark - 20mm slab:
          GPU: \(String(format: "%.2f", gpuDuration * 1000))ms
          CPU: \(String(format: "%.2f", cpuDuration * 1000))ms
          Speedup: \(String(format: "%.2f", speedup))x
        """)

        XCTAssertGreaterThan(speedup, 2.0, "GPU should be at least 2x faster than CPU for 20mm slab (actual: \(String(format: "%.2f", speedup))x)")
    }

    /// Benchmark GPU vs CPU for 50mm slab thickness (maximum test)
    func testPerformanceGPUvsCPU_50mm() async throws {
        let benchmarkAdapter = try makeBenchmarkAdapter()
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)
        let thickness = 50
        let steps = 50

        // Warmup run for GPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark GPU path
        let gpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let gpuDuration = CFAbsoluteTimeGetCurrent() - gpuStart

        // Switch to CPU path
        await benchmarkAdapter.setForceCPU(true)

        // Warmup run for CPU
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )

        // Benchmark CPU path
        let cpuStart = CFAbsoluteTimeGetCurrent()
        _ = try await benchmarkAdapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: thickness,
            steps: steps,
            blend: .average
        )
        let cpuDuration = CFAbsoluteTimeGetCurrent() - cpuStart

        let speedup = cpuDuration / gpuDuration

        print("""
        Performance Benchmark - 50mm slab:
          GPU: \(String(format: "%.2f", gpuDuration * 1000))ms
          CPU: \(String(format: "%.2f", cpuDuration * 1000))ms
          Speedup: \(String(format: "%.2f", speedup))x
        """)

        XCTAssertGreaterThan(speedup, 2.0, "GPU should be at least 2x faster than CPU for 50mm slab (actual: \(String(format: "%.2f", speedup))x)")
    }

    /// Benchmark different blend modes on GPU vs CPU
    func testPerformanceGPUvsCPU_BlendModes() async throws {
        let benchmarkAdapter = try makeBenchmarkAdapter()
        let dataset = makeTestDataset()
        let plane = makeTestPlaneGeometry(for: dataset)
        let thickness = 15
        let steps = 15

        for blendMode in MPRBlendMode.allCases {
            // Warmup run for GPU
            _ = try await benchmarkAdapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )

            // Benchmark GPU path
            let gpuStart = CFAbsoluteTimeGetCurrent()
            _ = try await benchmarkAdapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )
            let gpuDuration = CFAbsoluteTimeGetCurrent() - gpuStart

            // Switch to CPU path
            await benchmarkAdapter.setForceCPU(true)

            // Warmup run for CPU
            _ = try await benchmarkAdapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )

            // Benchmark CPU path
            let cpuStart = CFAbsoluteTimeGetCurrent()
            _ = try await benchmarkAdapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )
            let cpuDuration = CFAbsoluteTimeGetCurrent() - cpuStart

            let speedup = cpuDuration / gpuDuration

            print("""
            Performance Benchmark - Blend Mode \(blendMode):
              GPU: \(String(format: "%.2f", gpuDuration * 1000))ms
              CPU: \(String(format: "%.2f", cpuDuration * 1000))ms
              Speedup: \(String(format: "%.2f", speedup))x
            """)

            // Re-enable GPU for next iteration
            await benchmarkAdapter.setForceCPU(false)

            // Verify GPU is faster for all blend modes
            XCTAssertGreaterThan(speedup, 1.0, "GPU should be faster than CPU for \(blendMode) blend mode")
        }
    }
}
