//
//  MetalVolumeRenderingAdapterTypesTests.swift
//  MTK
//
//  Unit tests for MetalVolumeRenderingAdapter value types and defaults.
//

import CoreGraphics
import Foundation
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

// MARK: - RenderingError Equatable (new in PR)

final class RenderingErrorEquatableTests: XCTestCase {
    private typealias RenderingError = MetalVolumeRenderingAdapter.RenderingError

    // Each simple case equals itself.
    func testEachSimpleCaseEqualsItself() {
        let simpleCases: [RenderingError] = [
            .datasetTextureUnavailable,
            .transferTextureUnavailable,
            .commandEncodingFailed,
            .outputTextureUnavailable,
            .cgImageCreationFailed,
        ]
        for error in simpleCases {
            XCTAssertEqual(error, error, "\(error) should equal itself")
        }
    }

    // commandBufferExecutionFailed with same description equals itself.
    func testCommandBufferExecutionFailedEqualsSameDescription() {
        let description = "MTLCommandBufferStatus.error: GPU timeout"
        let lhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: description)
        let rhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: description)
        XCTAssertEqual(lhs, rhs)
    }

    // commandBufferExecutionFailed with different descriptions are not equal.
    func testCommandBufferExecutionFailedNotEqualDifferentDescription() {
        let lhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: "error A")
        let rhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: "error B")
        XCTAssertNotEqual(lhs, rhs)
    }

    // Distinct simple cases are not equal.
    func testDistinctSimpleCasesAreNotEqual() {
        XCTAssertNotEqual(RenderingError.datasetTextureUnavailable, .transferTextureUnavailable)
        XCTAssertNotEqual(RenderingError.commandEncodingFailed, .outputTextureUnavailable)
        XCTAssertNotEqual(RenderingError.datasetTextureUnavailable, .commandEncodingFailed)
    }

    // Simple case does not equal commandBufferExecutionFailed.
    func testSimpleCaseNotEqualToCommandBufferExecutionFailed() {
        let failed = RenderingError.commandBufferExecutionFailed(underlyingDescription: "oops")
        XCTAssertNotEqual(RenderingError.datasetTextureUnavailable, failed)
        XCTAssertNotEqual(RenderingError.outputTextureUnavailable, failed)
    }

    // RenderingError can be cast from the Error protocol.
    func testCanBeCastFromSwiftError() {
        let error: Error = RenderingError.commandEncodingFailed
        XCTAssertEqual(error as? RenderingError, .commandEncodingFailed)
    }

    // commandBufferExecutionFailed with empty description equals same empty description.
    func testCommandBufferExecutionFailedWithEmptyDescriptionEquality() {
        let lhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: "")
        let rhs = RenderingError.commandBufferExecutionFailed(underlyingDescription: "")
        XCTAssertEqual(lhs, rhs)
    }
}

// MARK: - RenderingError LocalizedError

final class RenderingErrorLocalizedErrorTests: XCTestCase {
    private typealias RenderingError = MetalVolumeRenderingAdapter.RenderingError

    func testAllSimpleCasesHaveNonEmptyErrorDescription() {
        let simpleCases: [RenderingError] = [
            .datasetTextureUnavailable,
            .transferTextureUnavailable,
            .commandEncodingFailed,
            .outputTextureUnavailable,
            .cgImageCreationFailed,
        ]
        for error in simpleCases {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "\(error) should have errorDescription")
            XCTAssertFalse(desc?.isEmpty ?? true, "\(error) errorDescription should not be empty")
        }
    }

    func testCommandBufferExecutionFailedHasNonEmptyErrorDescription() {
        let error = RenderingError.commandBufferExecutionFailed(underlyingDescription: "test error")
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc?.isEmpty ?? true)
    }

    func testAllSimpleCasesHaveNonEmptyFailureReason() {
        let simpleCases: [RenderingError] = [
            .datasetTextureUnavailable,
            .transferTextureUnavailable,
            .commandEncodingFailed,
            .outputTextureUnavailable,
            .cgImageCreationFailed,
        ]
        for error in simpleCases {
            let reason = error.failureReason
            XCTAssertNotNil(reason, "\(error) should have failureReason")
            XCTAssertFalse(reason?.isEmpty ?? true, "\(error) failureReason should not be empty")
        }
    }

    func testCommandBufferExecutionFailedFailureReasonContainsDescription() {
        let underlyingDescription = "MTLCommandBufferStatus.error: custom reason"
        let error = RenderingError.commandBufferExecutionFailed(underlyingDescription: underlyingDescription)
        let reason = error.failureReason ?? ""
        XCTAssertTrue(reason.contains(underlyingDescription),
                      "failureReason should contain the underlying description")
    }

    func testErrorDescriptionsMatchExpectedValues() {
        XCTAssertEqual(RenderingError.datasetTextureUnavailable.errorDescription, "Dataset texture unavailable")
        XCTAssertEqual(RenderingError.transferTextureUnavailable.errorDescription, "Transfer function texture unavailable")
        XCTAssertEqual(RenderingError.commandEncodingFailed.errorDescription, "Metal command encoding failed")
        XCTAssertEqual(RenderingError.outputTextureUnavailable.errorDescription, "Output texture unavailable")
        XCTAssertEqual(RenderingError.cgImageCreationFailed.errorDescription, "CGImage creation failed")
        XCTAssertEqual(RenderingError.commandBufferExecutionFailed(underlyingDescription: "x").errorDescription,
                       "Metal command buffer execution failed")
    }
}

// MARK: - InitializationError LocalizedError (moved to +Types.swift)

final class InitializationErrorLocalizedErrorTests: XCTestCase {
    private typealias InitializationError = MetalVolumeRenderingAdapter.InitializationError

    func testAllCasesHaveNonEmptyErrorDescription() {
        let allCases: [InitializationError] = [
            .metalDeviceUnavailable,
            .commandQueueCreationFailed,
            .commandQueueDeviceMismatch,
            .shaderLibraryUnavailable,
            .shaderLibraryDeviceMismatch,
            .computeFunctionNotFound,
            .pipelineCreationFailed,
            .cameraBufferAllocationFailed,
        ]
        for error in allCases {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "\(error) should have errorDescription")
            XCTAssertFalse(desc?.isEmpty ?? true, "\(error) errorDescription should not be empty")
        }
    }

    func testAllCasesHaveNonEmptyFailureReason() {
        let allCases: [InitializationError] = [
            .metalDeviceUnavailable,
            .commandQueueCreationFailed,
            .commandQueueDeviceMismatch,
            .shaderLibraryUnavailable,
            .shaderLibraryDeviceMismatch,
            .computeFunctionNotFound,
            .pipelineCreationFailed,
            .cameraBufferAllocationFailed,
        ]
        for error in allCases {
            let reason = error.failureReason
            XCTAssertNotNil(reason, "\(error) should have failureReason")
            XCTAssertFalse(reason?.isEmpty ?? true, "\(error) failureReason should not be empty")
        }
    }

    func testErrorDescriptionsMatchExpectedValues() {
        XCTAssertEqual(InitializationError.metalDeviceUnavailable.errorDescription, "Metal device unavailable")
        XCTAssertEqual(InitializationError.commandQueueCreationFailed.errorDescription, "Metal command queue creation failed")
        XCTAssertEqual(InitializationError.commandQueueDeviceMismatch.errorDescription, "Metal command queue device mismatch")
        XCTAssertEqual(InitializationError.shaderLibraryUnavailable.errorDescription, "Metal shader library unavailable")
        XCTAssertEqual(InitializationError.shaderLibraryDeviceMismatch.errorDescription, "Metal shader library device mismatch")
        XCTAssertEqual(InitializationError.computeFunctionNotFound.errorDescription, "Metal volume compute function not found")
        XCTAssertEqual(InitializationError.pipelineCreationFailed.errorDescription, "Metal volume compute pipeline creation failed")
        XCTAssertEqual(InitializationError.cameraBufferAllocationFailed.errorDescription, "Metal camera buffer allocation failed")
    }

    func testEquatableConformance() {
        XCTAssertEqual(InitializationError.metalDeviceUnavailable, .metalDeviceUnavailable)
        XCTAssertNotEqual(InitializationError.metalDeviceUnavailable, .commandQueueCreationFailed)
        XCTAssertNotEqual(InitializationError.shaderLibraryUnavailable, .shaderLibraryDeviceMismatch)
    }

    func testCanBeCastFromSwiftError() {
        let error: Error = InitializationError.computeFunctionNotFound
        XCTAssertEqual(error as? InitializationError, .computeFunctionNotFound)
    }
}

// MARK: - ExtendedRenderingState Defaults (moved to +Types.swift)

final class ExtendedRenderingStateDefaultsTests: XCTestCase {
    func testDefaultValues() {
        let state = ExtendedRenderingState()

        XCTAssertNil(state.huWindow, "huWindow should default to nil")
        XCTAssertTrue(state.lightingEnabled, "lightingEnabled should default to true")
        XCTAssertEqual(state.samplingStep, 1.0 / 512.0, accuracy: 1e-7,
                       "samplingStep should default to 1/512")
        XCTAssertEqual(state.shift, 0, "shift should default to 0")
        XCTAssertNil(state.densityGate, "densityGate should default to nil")
        XCTAssertNil(state.huGate, "huGate should default to nil")
        XCTAssertFalse(state.adaptiveEnabled, "adaptiveEnabled should default to false")
        XCTAssertEqual(state.adaptiveThreshold, 0, "adaptiveThreshold should default to 0")
        XCTAssertEqual(state.jitterAmount, 0, "jitterAmount should default to 0")
        XCTAssertEqual(state.earlyTerminationThreshold, 0.95, accuracy: 1e-6,
                       "earlyTerminationThreshold should default to 0.95")
        XCTAssertEqual(state.channelIntensities, SIMD4<Float>(repeating: 1),
                       "channelIntensities should default to (1, 1, 1, 1)")
        XCTAssertTrue(state.toneCurvePoints.isEmpty, "toneCurvePoints should default to empty")
        XCTAssertTrue(state.toneCurvePresetKeys.isEmpty, "toneCurvePresetKeys should default to empty")
        XCTAssertTrue(state.toneCurveGains.isEmpty, "toneCurveGains should default to empty")
        XCTAssertEqual(state.clipBounds, ClipBoundsSnapshot.default, "clipBounds should default to .default")
        XCTAssertEqual(state.clipPlanePreset, 0, "clipPlanePreset should default to 0 (none)")
        XCTAssertEqual(state.clipPlaneOffset, 0, "clipPlaneOffset should default to 0")
    }
}

// MARK: - Overrides Defaults (moved to +Types.swift with updated docs)

final class OverridesDefaultsTests: XCTestCase {
    func testDefaultValues() {
        let overrides = MetalVolumeRenderingAdapter.Overrides()

        XCTAssertNil(overrides.compositing, "compositing should default to nil (no override)")
        XCTAssertNil(overrides.samplingDistance, "samplingDistance should default to nil (no override)")
        XCTAssertNil(overrides.window, "window should default to nil (no override)")
        XCTAssertTrue(overrides.lightingEnabled, "lightingEnabled should default to true")
    }

    func testLightingCanBeDisabledViaOverride() {
        var overrides = MetalVolumeRenderingAdapter.Overrides()
        overrides.lightingEnabled = false
        XCTAssertFalse(overrides.lightingEnabled)
    }

    func testWindowOverrideCanBeSet() {
        var overrides = MetalVolumeRenderingAdapter.Overrides()
        overrides.window = -1024...3071
        XCTAssertEqual(overrides.window, -1024...3071)
    }
}

// MARK: - DatasetIdentity content fingerprint

final class DatasetIdentityTests: XCTestCase {
    func testDatasetIdentityChangesWhenSharedDataMutatesInPlace() {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let byteCount = dimensions.voxelCount * VolumePixelFormat.int16Unsigned.bytesPerVoxel
        guard let storage = NSMutableData(length: byteCount) else {
            XCTFail("Expected shared test storage allocation to succeed")
            return
        }

        let pointer = storage.mutableBytes.assumingMemoryBound(to: UInt16.self)
        for index in 0..<dimensions.voxelCount {
            pointer[index] = UInt16(index)
        }

        let data = Data(bytesNoCopy: storage.mutableBytes,
                        count: byteCount,
                        deallocator: .none)
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        let initialIdentity = MetalVolumeRenderingAdapter.DatasetIdentity(dataset: dataset)
        pointer[0] &+= 1
        let mutatedIdentity = MetalVolumeRenderingAdapter.DatasetIdentity(dataset: dataset)

        XCTAssertNotEqual(initialIdentity, mutatedIdentity)
    }
}

// MARK: - RenderSnapshot (moved to +Types.swift)

final class RenderSnapshotTests: XCTestCase {
    func testRenderSnapshotStoresCorrectValues() {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            recommendedWindow: 0...4095
        )
        let metadata = VolumeRenderFrame.Metadata(
            viewportSize: CGSize(width: 64, height: 64),
            samplingDistance: 0.002,
            compositing: .frontToBack,
            quality: .interactive,
            pixelFormat: .bgra8Unorm
        )
        let window: ClosedRange<Int32> = -500...1500
        let snapshot = MetalVolumeRenderingAdapter.RenderSnapshot(
            dataset: dataset,
            metadata: metadata,
            window: window
        )

        XCTAssertEqual(snapshot.window, window)
        XCTAssertEqual(snapshot.metadata.compositing, .frontToBack)
        XCTAssertEqual(snapshot.metadata.samplingDistance, 0.002, accuracy: 1e-6)
    }
}
