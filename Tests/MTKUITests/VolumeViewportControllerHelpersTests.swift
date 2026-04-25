//
//  VolumeViewportControllerHelpersTests.swift
//  MTKUITests
//
//  Tests for VolumeViewportController helper methods added in:
//  - Controllers/VolumeViewportController.swift (SlabConfiguration, init, helpers)
//  - Controllers/VolumeViewportController+Camera.swift
//  - Controllers/VolumeViewportController+MPR.swift
//  - Controllers/VolumeViewportController+Rendering.swift
//  - Controllers/MPRVolumeTextureCache.swift
//

import CoreGraphics
import Metal
import simd
import XCTest
import MTKCore
@_spi(Testing) @testable import MTKUI

// MARK: - VolumeViewportController.SlabConfiguration.snapToOddVoxelCount

final class SlabConfigurationSnapToOddVoxelCountTests: XCTestCase {

    func testZeroInputReturnsZero() {
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(0), 0)
    }

    func testNegativeInputReturnsZero() {
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(-5), 0)
    }

    func testOddInputIsUnchanged() {
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(1), 1)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(3), 3)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(7), 7)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(99), 99)
    }

    func testEvenInputSnapsToNextOdd() {
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(2), 3)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(4), 5)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(6), 7)
        XCTAssertEqual(VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(100), 101)
    }

    func testResultIsAlwaysOddForPositiveInputs() {
        for value in 1...20 {
            let result = VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(value)
            XCTAssertEqual(result % 2, 1,
                           "Expected odd result for input \(value), got \(result)")
        }
    }

    func testIntMaxEvenBehavior() {
        // Int.max is 9223372036854775807 which is odd on 64-bit systems;
        // test with a large even value near Int.max instead
        let largeEven = Int.max - 1  // Int.max - 1 is even (Int.max is odd)
        let result = VolumeViewportController.SlabConfiguration.snapToOddVoxelCount(largeEven)
        // When value == Int.max: returns max(1, Int.max - 1) = Int.max - 1
        // But largeEven = Int.max - 1 (even), so result should be Int.max - 2...
        // Actually looking at code: if clamped == Int.max, return max(1, clamped - 1) = Int.max - 1
        // Since largeEven = Int.max - 1 is not Int.max: result = largeEven + 1 = Int.max
        XCTAssertEqual(result % 2, 1)
    }
}

// MARK: - VolumeViewportController.SlabConfiguration init

final class SlabConfigurationInitTests: XCTestCase {

    func testInitSnapsThicknessToOdd() {
        let config = VolumeViewportController.SlabConfiguration(thickness: 4, steps: 5)
        XCTAssertEqual(config.thickness, 5)
    }

    func testInitSnapsStepsToOdd() {
        let config = VolumeViewportController.SlabConfiguration(thickness: 3, steps: 4)
        XCTAssertEqual(config.steps, 5)
    }

    func testInitWithOddValuesPreservesThem() {
        let config = VolumeViewportController.SlabConfiguration(thickness: 7, steps: 11)
        XCTAssertEqual(config.thickness, 7)
        XCTAssertEqual(config.steps, 11)
    }

    func testInitWithZeroThicknessProducesZero() {
        let config = VolumeViewportController.SlabConfiguration(thickness: 0, steps: 1)
        XCTAssertEqual(config.thickness, 0)
    }

    func testInitEquatableConformance() {
        let a = VolumeViewportController.SlabConfiguration(thickness: 3, steps: 5)
        let b = VolumeViewportController.SlabConfiguration(thickness: 3, steps: 5)
        XCTAssertEqual(a, b)
    }
}

// MARK: - VolumeViewportController.Axis

final class VolumeViewportControllerAxisTests: XCTestCase {

    func testAxisXMapsToPlanAxisX() {
        XCTAssertEqual(VolumeViewportController.Axis.x.mprPlaneAxis, MPRPlaneAxis.x)
    }

    func testAxisYMapsToPlanAxisY() {
        XCTAssertEqual(VolumeViewportController.Axis.y.mprPlaneAxis, MPRPlaneAxis.y)
    }

    func testAxisZMapsToPlanAxisZ() {
        XCTAssertEqual(VolumeViewportController.Axis.z.mprPlaneAxis, MPRPlaneAxis.z)
    }

    func testAxisCaseIterableHasThreeCases() {
        XCTAssertEqual(VolumeViewportController.Axis.allCases.count, 3)
    }

    func testAxisRawValues() {
        XCTAssertEqual(VolumeViewportController.Axis.x.rawValue, 0)
        XCTAssertEqual(VolumeViewportController.Axis.y.rawValue, 1)
        XCTAssertEqual(VolumeViewportController.Axis.z.rawValue, 2)
    }
}

// MARK: - VolumeViewportController.Error

final class VolumeViewportControllerErrorTests: XCTestCase {

    func testMetalUnavailableError() {
        let error = VolumeViewportController.Error.metalUnavailable
        XCTAssertNotNil(error)
    }

    func testDatasetNotLoadedError() {
        let error = VolumeViewportController.Error.datasetNotLoaded
        XCTAssertNotNil(error)
    }

    func testTransferFunctionUnavailableError() {
        let error = VolumeViewportController.Error.transferFunctionUnavailable
        XCTAssertNotNil(error)
    }

    func testPresentationFailedError() {
        let error = VolumeViewportController.Error.presentationFailed
        XCTAssertNotNil(error)
    }
}

// MARK: - VolumeViewportController Camera Helpers

@MainActor
final class VolumeViewportControllerCameraTests: XCTestCase {

    func testSafeNormalizeNonZeroVector() throws {
        let controller = try makeController()
        let result = controller.safeNormalize(SIMD3<Float>(3, 0, 0), fallback: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(result.x, 1.0, accuracy: 0.000_01)
        XCTAssertEqual(result.y, 0.0, accuracy: 0.000_01)
        XCTAssertEqual(result.z, 0.0, accuracy: 0.000_01)
    }

    func testSafeNormalizeZeroVectorReturnsFallback() throws {
        let controller = try makeController()
        let fallback = SIMD3<Float>(0, 1, 0)
        let result = controller.safeNormalize(.zero, fallback: fallback)
        XCTAssertEqual(result, fallback)
    }

    func testSafeNormalizeProducesUnitLength() throws {
        let controller = try makeController()
        let v = SIMD3<Float>(1, 2, 3)
        let result = controller.safeNormalize(v, fallback: .zero)
        let length = simd_length(result)
        XCTAssertEqual(length, 1.0, accuracy: 0.000_01)
    }

    func testSafePerpendicularProducesOrthogonalVector() throws {
        let controller = try makeController()
        let v = SIMD3<Float>(1, 0, 0)
        let perp = controller.safePerpendicular(to: v)
        let dot = simd_dot(v, perp)
        XCTAssertEqual(dot, 0.0, accuracy: 0.000_01)
    }

    func testSafePerpendicularProducesUnitLength() throws {
        let controller = try makeController()
        let v = SIMD3<Float>(0, 1, 0)
        let perp = controller.safePerpendicular(to: v)
        XCTAssertEqual(simd_length(perp), 1.0, accuracy: 0.000_01)
    }

    func testMakeCameraDistanceLimitsLowerBound() throws {
        let controller = try makeController()
        let limits = controller.makeCameraDistanceLimits(radius: 1.0)
        // minimum = max(1.0 * 0.25, 0.1) = 0.25
        XCTAssertEqual(limits.lowerBound, 0.25, accuracy: 0.000_01)
    }

    func testMakeCameraDistanceLimitsUpperBound() throws {
        let controller = try makeController()
        let limits = controller.makeCameraDistanceLimits(radius: 1.0)
        // maximum = max(1.0 * 12, 0.25 + 0.5) = 12.0
        XCTAssertEqual(limits.upperBound, 12.0, accuracy: 0.000_01)
    }

    func testMakeCameraDistanceLimitsSmallRadius() throws {
        let controller = try makeController()
        // For small radius, upper bound is clamped to minimum + 0.5
        let limits = controller.makeCameraDistanceLimits(radius: 0.001)
        XCTAssertEqual(limits.lowerBound, 0.1, accuracy: 0.000_01)
        XCTAssertGreaterThan(limits.upperBound, limits.lowerBound)
    }

    func testClampCameraOffsetPreservesDirectionWithinLimits() throws {
        let controller = try makeController()
        let offset = SIMD3<Float>(0, 0, 1.0)  // within default limits
        let clamped = controller.clampCameraOffset(offset)
        // Direction should be preserved
        XCTAssertEqual(simd_normalize(clamped), simd_normalize(offset))
    }

    func testClampCameraOffsetHandlesZeroVector() throws {
        let controller = try makeController()
        let clamped = controller.clampCameraOffset(.zero)
        // Should return a default offset along +Z
        XCTAssertEqual(clamped.x, 0.0, accuracy: 0.000_01)
        XCTAssertEqual(clamped.y, 0.0, accuracy: 0.000_01)
        XCTAssertGreaterThan(clamped.z, 0)
    }

    func testClampCameraTargetAllowsTargetNearCenter() throws {
        let controller = try makeController()
        let nearCenter = SIMD3<Float>(0.5, 0.5, 0.5)
        let clamped = controller.clampCameraTarget(nearCenter)
        XCTAssertEqual(clamped, nearCenter)
    }

    func testClampCameraTargetClampsDistantTarget() throws {
        let controller = try makeController()
        // Very far from center
        let distant = SIMD3<Float>(100, 100, 100)
        let clamped = controller.clampCameraTarget(distant)
        let distanceFromCenter = simd_length(clamped - controller.volumeWorldCenter)
        let limit = max(controller.volumeBoundingRadius * controller.maximumPanDistanceMultiplier, 1)
        XCTAssertLessThanOrEqual(distanceFromCenter, limit + 0.001)
    }
}

// MARK: - VolumeViewportController MPR Helpers

@MainActor
final class VolumeViewportControllerMPRTests: XCTestCase {

    func testClampedIndexWithNoDatasetReturnsZero() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.clampedIndex(for: .x, index: 10), 0)
        XCTAssertEqual(controller.clampedIndex(for: .y, index: 50), 0)
        XCTAssertEqual(controller.clampedIndex(for: .z, index: 100), 0)
    }

    func testNormalizedPositionWithNoDatasetReturnsHalf() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.normalizedPosition(for: .x, index: 0), 0.5)
        XCTAssertEqual(controller.normalizedPosition(for: .y, index: 5), 0.5)
        XCTAssertEqual(controller.normalizedPosition(for: .z, index: 10), 0.5)
    }

    func testIndexPositionWithNoDatasetReturnsZero() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.indexPosition(for: .x, normalized: 0.5), 0)
    }

    func testDatasetDimensionsWithNoDatasetReturnsUnit() throws {
        let controller = try makeController()
        let dims = controller.datasetDimensions()
        XCTAssertEqual(dims.x, 1, accuracy: 0.000_01)
        XCTAssertEqual(dims.y, 1, accuracy: 0.000_01)
        XCTAssertEqual(dims.z, 1, accuracy: 0.000_01)
    }

    func testRotationQuaternionForZeroEulerIsIdentity() throws {
        let controller = try makeController()
        let quat = controller.rotationQuaternion(for: .zero)
        // Identity quaternion has real part 1, imaginary parts 0
        XCTAssertEqual(quat.real, 1.0, accuracy: 0.000_01)
        XCTAssertEqual(quat.imag.x, 0.0, accuracy: 0.000_01)
        XCTAssertEqual(quat.imag.y, 0.0, accuracy: 0.000_01)
        XCTAssertEqual(quat.imag.z, 0.0, accuracy: 0.000_01)
    }

    func testRotationQuaternionIsNormalized() throws {
        let controller = try makeController()
        let euler = SIMD3<Float>(0.1, 0.2, 0.3)
        let quat = controller.rotationQuaternion(for: euler)
        let norm = simd_length(simd_quatf(ix: quat.imag.x,
                                          iy: quat.imag.y,
                                          iz: quat.imag.z,
                                          r: quat.real).vector)
        XCTAssertEqual(norm, 1.0, accuracy: 0.000_1)
    }

    func testInvalidateMPRCacheDoesNotCrash() throws {
        let controller = try makeController()
        controller.invalidateMPRCache()
        controller.invalidateMPRCache(axis: .x)
        controller.invalidateMPRCache(axis: .y)
        controller.invalidateMPRCache(axis: .z)
    }

    func testClampedViewportSizeReturnsAtLeastOneByOne() throws {
        let controller = try makeController()
        let size = controller.clampedViewportSize()
        XCTAssertGreaterThanOrEqual(size.width, 1)
        XCTAssertGreaterThanOrEqual(size.height, 1)
    }

    func testNormalizedPositionAndIndexRoundtripWithDataset() async throws {
        let controller = try makeController()
        let dataset = makeDataset(width: 100, height: 100, depth: 50)
        await controller.applyDataset(dataset)

        // index 25 in z (depth=50), normalized should be ~0.51
        let norm = controller.normalizedPosition(for: .z, index: 25)
        XCTAssertGreaterThan(norm, 0)
        XCTAssertLessThanOrEqual(norm, 1)

        // Round-trip: index -> normalized -> index should be approximately the same
        let recovered = controller.indexPosition(for: .z, normalized: norm)
        XCTAssertEqual(recovered, 25)
    }

    func testClampedIndexWithDatasetClampsToValidRange() async throws {
        let controller = try makeController()
        let dataset = makeDataset(width: 10, height: 10, depth: 10)
        await controller.applyDataset(dataset)

        XCTAssertEqual(controller.clampedIndex(for: .x, index: -5), 0)
        XCTAssertEqual(controller.clampedIndex(for: .x, index: 1000), 9)
        XCTAssertEqual(controller.clampedIndex(for: .x, index: 5), 5)
    }
}

// MARK: - MPRVolumeTextureCache

@MainActor
final class MPRVolumeTextureCacheTests: XCTestCase {

    func testInvalidateClearsCachedTexture() async throws {
        let device = try requireMetalDevice()
        let cache = MPRVolumeTextureCache()
        let dataset = makeDataset()
        let queue = try requireCommandQueue(device: device)

        // Generate and cache a texture
        _ = try await cache.texture(for: dataset, device: device, commandQueue: queue)
        let identifierBefore = cache.textureIdentifier

        cache.invalidate()

        XCTAssertNil(cache.textureIdentifier)
        XCTAssertNotNil(identifierBefore, "Should have had a texture identifier before invalidate")
    }

    func testTextureCacheReturnsSameTextureForSameDataset() async throws {
        let device = try requireMetalDevice()
        let cache = MPRVolumeTextureCache()
        let dataset = makeDataset()
        let queue = try requireCommandQueue(device: device)

        let texture1 = try await cache.texture(for: dataset, device: device, commandQueue: queue)
        let texture2 = try await cache.texture(for: dataset, device: device, commandQueue: queue)

        XCTAssertTrue(texture1 === texture2, "Cache should return identical texture for same dataset")
    }

    func testConcurrentTextureRequestsCoalesceInFlightGeneration() async throws {
        let device = try requireMetalDevice()
        let dataset = makeDataset()
        let queue = try requireCommandQueue(device: device)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = dataset.dimensions.width
        descriptor.height = dataset.dimensions.height
        descriptor.depth = dataset.dimensions.depth
        descriptor.usage = [.shaderRead]
        guard let expectedTexture = device.makeTexture(descriptor: descriptor) else {
            XCTFail("Could not create test texture")
            return
        }

        var creationCount = 0
        var releaseGeneration: CheckedContinuation<Void, Never>?
        let cache = MPRVolumeTextureCache(textureProvider: { _, _, _ in
            creationCount += 1
            await withCheckedContinuation { continuation in
                releaseGeneration = continuation
            }
            return expectedTexture
        })

        let first = Task {
            try await cache.texture(for: dataset, device: device, commandQueue: queue)
        }
        while releaseGeneration == nil {
            await Task.yield()
        }

        let second = Task {
            try await cache.texture(for: dataset, device: device, commandQueue: queue)
        }
        await Task.yield()

        XCTAssertEqual(creationCount, 1)
        releaseGeneration?.resume()

        let texture1 = try await first.value
        let texture2 = try await second.value
        XCTAssertTrue(texture1 === texture2, "Concurrent requests should share the pending texture task")
        XCTAssertEqual(creationCount, 1)
    }

    func testTextureIdentifierIsNilBeforeAnyRequest() {
        let cache = MPRVolumeTextureCache()
        XCTAssertNil(cache.textureIdentifier)
    }

    func testTextureIdentifierIsSetAfterSuccessfulRequest() async throws {
        let device = try requireMetalDevice()
        let cache = MPRVolumeTextureCache()
        let dataset = makeDataset()
        let queue = try requireCommandQueue(device: device)

        _ = try await cache.texture(for: dataset, device: device, commandQueue: queue)
        XCTAssertNotNil(cache.textureIdentifier)
    }
}

// MARK: - Helpers

@MainActor
private func makeController() throws -> VolumeViewportController {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("Metal not available")
    }
    return try VolumeViewportController()
}

private func requireMetalDevice() throws -> any MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal not available")
    }
    return device
}

private func requireCommandQueue(device: any MTLDevice) throws -> any MTLCommandQueue {
    guard let queue = device.makeCommandQueue() else {
        throw XCTSkip("Could not create command queue")
    }
    return queue
}

private func makeDataset(width: Int = 4, height: Int = 4, depth: Int = 4) -> VolumeDataset {
    let dimensions = VolumeDimensions(width: width, height: height, depth: depth)
    return VolumeDataset(
        data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
        dimensions: dimensions,
        spacing: VolumeSpacing(x: 1, y: 1, z: 1),
        pixelFormat: .int16Signed,
        intensityRange: (-1024)...3071
    )
}
