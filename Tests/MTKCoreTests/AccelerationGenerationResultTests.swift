import Metal
import OSLog
import XCTest

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

@testable import MTKCore

// MARK: - UnavailabilityReason Equatable

final class UnavailabilityReasonEquatableTests: XCTestCase {
#if canImport(MetalPerformanceShaders)
    func testMpsUnsupportedOnDeviceCaseEqualsItself() {
        let reason: MPSEmptySpaceAccelerator.UnavailabilityReason = .mpsUnsupportedOnDevice
        XCTAssertEqual(reason, .mpsUnsupportedOnDevice)
    }

    func testLibraryUnavailableCaseEqualsItself() {
        let reason: MPSEmptySpaceAccelerator.UnavailabilityReason = .libraryUnavailable
        XCTAssertEqual(reason, .libraryUnavailable)
    }

    func testCommandQueueUnavailableCaseEqualsItself() {
        let reason: MPSEmptySpaceAccelerator.UnavailabilityReason = .commandQueueUnavailable
        XCTAssertEqual(reason, .commandQueueUnavailable)
    }

    func testAcceleratorInitializationFailedCaseEqualsItself() {
        let reason: MPSEmptySpaceAccelerator.UnavailabilityReason = .acceleratorInitializationFailed
        XCTAssertEqual(reason, .acceleratorInitializationFailed)
    }

    func testDifferentReasonCasesAreNotEqual() {
        XCTAssertNotEqual(
            MPSEmptySpaceAccelerator.UnavailabilityReason.mpsUnsupportedOnDevice,
            .libraryUnavailable
        )
        XCTAssertNotEqual(
            MPSEmptySpaceAccelerator.UnavailabilityReason.libraryUnavailable,
            .acceleratorInitializationFailed
        )
        XCTAssertNotEqual(
            MPSEmptySpaceAccelerator.UnavailabilityReason.mpsUnsupportedOnDevice,
            .acceleratorInitializationFailed
        )
    }
#else
    func testUnavailabilityReasonEquatableIsNotApplicable() throws {
        throw XCTSkip("MetalPerformanceShaders not importable on this platform; UnavailabilityReason is MPS-only")
    }
#endif
}

// MARK: - GenerationResult pattern matching

final class GenerationResultPatternMatchingTests: XCTestCase {
#if canImport(MetalPerformanceShaders)
    func testSuccessResultCanBePatternMatched() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not supported; skipping .success path test")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let result = MPSEmptySpaceAccelerator.generateTexture(
            device: device,
            commandQueue: queue,
            dataset: dataset,
            logger: Logger(subsystem: "MTKCoreTests", category: "GenerationResultTests")
        )

        switch result {
        case .success(let texture):
            XCTAssertGreaterThan(texture.width, 0)
            XCTAssertGreaterThan(texture.height, 0)
            XCTAssertGreaterThan(texture.depth, 0)
        case .unavailable(let reason):
            XCTAssertTrue(
                reason == .libraryUnavailable || reason == .acceleratorInitializationFailed,
                "Expected only resource-related unavailability on an MPS-capable device, got \(reason)"
            )
        case .failed(let error):
            XCTFail("Unexpected .failed result on MPS-capable device: \(error)")
        }
    }

    func testUnavailableResultCarriesReason() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard !MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS is supported on this device; .unavailable test requires a non-MPS device")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let result = MPSEmptySpaceAccelerator.generateTexture(
            device: device,
            commandQueue: queue,
            dataset: dataset,
            logger: Logger(subsystem: "MTKCoreTests", category: "GenerationResultTests")
        )

        guard case .unavailable(let reason) = result else {
            XCTFail("Expected .unavailable on non-MPS device, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(reason, .mpsUnsupportedOnDevice)
    }

    func testFailedResultCanBePatternMatched() {
        // Manufacture a .failed result by wrapping an error manually, to ensure
        // the case is pattern-matchable without requiring an actual GPU failure.
        struct TestError: Error {}
        let result: MPSEmptySpaceAccelerator.GenerationResult = .failed(TestError())

        if case .failed = result {
            // Success: pattern match works
        } else {
            XCTFail("Expected .failed result to match .failed pattern")
        }
    }

    func testSuccessResultDoesNotMatchUnavailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard MPSSupportsMTLDevice(device) else {
            throw XCTSkip("MPS not available; can't test .success ≠ .unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }

        let dataset = makeDataset(width: 4, height: 4, depth: 4)
        let result = MPSEmptySpaceAccelerator.generateTexture(
            device: device,
            commandQueue: queue,
            dataset: dataset,
            logger: Logger(subsystem: "MTKCoreTests", category: "GenerationResultTests")
        )

        switch result {
        case .success:
            break
        case .unavailable(let reason):
            XCTAssertTrue(
                reason == .libraryUnavailable || reason == .acceleratorInitializationFailed,
                "Expected only resource-related unavailability on an MPS-capable device, got \(reason)"
            )
        case .failed(let error):
            XCTFail("Unexpected .failed result on MPS-capable device: \(error)")
        }
    }
#else
    func testGenerationResultPatternMatchingIsNotApplicable() throws {
        throw XCTSkip("MetalPerformanceShaders not importable on this platform")
    }
#endif

    private func makeDataset(width: Int, height: Int, depth: Int) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: width, height: height, depth: depth)
        let values = [UInt16](repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: 0...4095
        )
    }
}

// MARK: - MetalRaycaster.AccelerationStructureGenerationResult

final class MetalRaycasterAccelerationResultTests: XCTestCase {

    func testPrepareAccelerationStructureReturnsMPSResultType() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("MetalRaycaster unavailable: \(error)")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let result = raycaster.prepareAccelerationStructure(dataset: dataset)

        // The result must be one of the three valid outcomes
        switch result {
        case .success(let texture):
            XCTAssertTrue(raycaster.isMetalPerformanceShadersAvailable,
                          ".success should only occur when MPS is available")
            XCTAssertGreaterThan(texture.width, 0, "Acceleration texture must have positive dimensions")
        case .unavailable(let reason):
            if raycaster.isMetalPerformanceShadersAvailable {
                XCTAssertTrue(
                    reason == .libraryUnavailable || reason == .acceleratorInitializationFailed,
                    "When MPS is available, unavailable results should reflect library resolution or accelerator initialization"
                )
            } else {
                XCTAssertEqual(
                    reason,
                    .mpsUnsupportedOnDevice,
                    "When MPS is unavailable, the result should report .mpsUnsupportedOnDevice"
                )
            }
        case .failed(let error):
            XCTFail("Unexpected .failed result from prepareAccelerationStructure: \(error)")
        }
    }

    func testAccelerationStructureResultIsConsistentWithMPSAvailabilityFlag() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("MetalRaycaster unavailable: \(error)")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let result = raycaster.prepareAccelerationStructure(dataset: dataset)
        let mpsAvailable = raycaster.isMetalPerformanceShadersAvailable

        if mpsAvailable {
            if case .unavailable(let reason) = result, reason == .mpsUnsupportedOnDevice {
                XCTFail(".isMetalPerformanceShadersAvailable is true but result is .unavailable(.mpsUnsupportedOnDevice)")
            }
        } else {
            // When MPS is unavailable the result must not be .success
            if case .success = result {
                XCTFail("prepareAccelerationStructure returned .success but isMetalPerformanceShadersAvailable is false")
            }
        }
    }

    func testPrepareWithIncludeAccelerationFalseGivesNilTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("MetalRaycaster unavailable: \(error)")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let resources = try raycaster.prepare(dataset: dataset, includeAccelerationStructure: false)
        XCTAssertNil(resources.accelerationTexture,
                     "accelerationTexture should be nil when includeAccelerationStructure is false")
        XCTAssertNil(resources.accelerationGenerationResult,
                     "accelerationGenerationResult should be nil when includeAccelerationStructure is false")
    }

    func testPrepareWithIncludeAccelerationTruePreservesGenerationResult() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let raycaster: MetalRaycaster
        do {
            raycaster = try MetalRaycaster(device: device)
        } catch {
            throw XCTSkip("MetalRaycaster unavailable: \(error)")
        }

        let dataset = makeDataset(width: 8, height: 8, depth: 8)
        let resources = try raycaster.prepare(dataset: dataset, includeAccelerationStructure: true)
        guard let result = resources.accelerationGenerationResult else {
            XCTFail("Expected an explicit accelerationGenerationResult when acceleration is requested")
            return
        }

        switch result {
        case .success:
            XCTAssertNotNil(resources.accelerationTexture,
                            "accelerationTexture should be populated only for .success")
        case .unavailable, .failed:
            XCTAssertNil(resources.accelerationTexture,
                         "accelerationTexture should stay nil for non-success acceleration results")
        }
    }

    private func makeDataset(width: Int, height: Int, depth: Int) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: width, height: height, depth: depth)
        let values = [UInt16](repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: 0...4095
        )
    }
}
