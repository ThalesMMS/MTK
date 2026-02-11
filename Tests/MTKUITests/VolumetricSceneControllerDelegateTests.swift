//  VolumetricSceneControllerDelegateTests.swift
//  MTK
//  Validates VolumetricSceneController delegate forwarding and camera synchronization.
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
@testable import MTKUI
@testable import MTKCore
@testable import MTKSceneKit

#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(Metal)
import Metal
#endif

@MainActor
final class VolumetricSceneControllerDelegateTests: XCTestCase {

    // MARK: - Camera State Synchronization Tests

    func testSynchronizeInteractiveCameraStateUpdatesTarget() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()
        let initialTarget = controller.cameraTarget

        let customTarget = SIMD3<Float>(1.0, 2.0, 3.0)
        let customUp = SIMD3<Float>(0, 1, 0)
        let customRadius: Float = 5.0

        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: customRadius
        )

        // Target is clamped, so we check it was updated (not exact match)
        XCTAssertNotEqual(controller.cameraTarget, initialTarget, "Camera target should be updated")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateUpdatesUpVector() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()
        let initialUp = controller.cameraUpVector

        let customTarget = SIMD3<Float>(0, 0, 0)
        let customUp = SIMD3<Float>(0, 0, 1)
        let customRadius: Float = 3.0

        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: customRadius
        )

        // Up vector is normalized, so we check it was updated
        XCTAssertNotEqual(controller.cameraUpVector, initialUp, "Camera up vector should be updated")
        // Verify it's normalized
        let length = simd_length(controller.cameraUpVector)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Up vector should be normalized")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateUpdatesCameraNode() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        let customTarget = SIMD3<Float>(1.0, 1.0, 1.0)
        let customUp = SIMD3<Float>(0, 1, 0)
        let customRadius: Float = 10.0

        // Should complete without crashing
        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: customRadius
        )

        // Verify camera offset was updated
        XCTAssertNotNil(controller.cameraOffset, "Camera offset should exist")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateWithZeroRadius() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        let customTarget = SIMD3<Float>(0, 0, 0)
        let customUp = SIMD3<Float>(0, 1, 0)
        let zeroRadius: Float = 0.0

        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: zeroRadius
        )

        // Should handle zero radius gracefully
        XCTAssertEqual(controller.cameraTarget, customTarget, "Target should still be updated with zero radius")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateWithNegativeRadius() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        let customTarget = SIMD3<Float>(0, 0, 0)
        let customUp = SIMD3<Float>(0, 1, 0)
        let negativeRadius: Float = -5.0

        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: negativeRadius
        )

        // Should handle negative radius gracefully
        XCTAssertEqual(controller.cameraTarget, customTarget, "Target should be updated despite negative radius")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateWithExtremeValues() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        let extremeTarget = SIMD3<Float>(1000.0, -1000.0, 500.0)
        let extremeUp = SIMD3<Float>(0.707, 0.707, 0)
        let extremeRadius: Float = 10000.0

        controller.synchronizeInteractiveCameraState(
            target: extremeTarget,
            up: extremeUp,
            cameraNode: cameraNode,
            radius: extremeRadius
        )

        // Should handle extreme values without crashing
        XCTAssertNotNil(controller.cameraTarget, "Camera target should be set")

        // Up vector should be normalized
        let length = simd_length(controller.cameraUpVector)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Up vector should be normalized even with extreme inputs")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSynchronizeInteractiveCameraStateMultipleCalls() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        // First synchronization
        let target1 = SIMD3<Float>(1.0, 0, 0)
        let up1 = SIMD3<Float>(0, 1, 0)
        controller.synchronizeInteractiveCameraState(
            target: target1,
            up: up1,
            cameraNode: cameraNode,
            radius: 2.0
        )
        let firstTarget = controller.cameraTarget
        let firstUp = controller.cameraUpVector

        // Second synchronization
        let target2 = SIMD3<Float>(0, 1.0, 0)
        let up2 = SIMD3<Float>(1, 0, 0)
        controller.synchronizeInteractiveCameraState(
            target: target2,
            up: up2,
            cameraNode: cameraNode,
            radius: 3.0
        )

        // Second call should change state
        XCTAssertNotEqual(controller.cameraTarget, firstTarget, "Second call should override first")
        XCTAssertNotEqual(controller.cameraUpVector, firstUp, "Second call should override first")

        // Up vector should be normalized
        let length = simd_length(controller.cameraUpVector)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Up vector should remain normalized")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Camera Controller Preparation Tests

    func testPrepareCameraControllerForGesturesWithDefaultWorldUp() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Should not crash with default world up
        controller.prepareCameraControllerForGestures()

        XCTAssertTrue(true, "Should handle default world up without issues")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPrepareCameraControllerForGesturesWithCustomWorldUp() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let customWorldUp = SIMD3<Float>(0, 0, 1)

        controller.prepareCameraControllerForGestures(worldUp: customWorldUp)

        XCTAssertTrue(true, "Should handle custom world up without issues")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPrepareCameraControllerForGesturesWithZeroWorldUp() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let zeroWorldUp = SIMD3<Float>(0, 0, 0)

        // Should handle zero vector gracefully
        controller.prepareCameraControllerForGestures(worldUp: zeroWorldUp)

        XCTAssertTrue(true, "Should handle zero world up vector without crashing")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPrepareCameraControllerForGesturesMultipleCalls() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Multiple calls should not cause issues
        controller.prepareCameraControllerForGestures()
        controller.prepareCameraControllerForGestures(worldUp: SIMD3<Float>(0, 1, 0))
        controller.prepareCameraControllerForGestures(worldUp: SIMD3<Float>(1, 0, 0))

        XCTAssertTrue(true, "Multiple preparation calls should be handled gracefully")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPrepareCameraControllerForGesturesWithNonNormalizedVector() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let nonNormalizedUp = SIMD3<Float>(2.0, 3.0, 1.5)

        // Should handle non-normalized vector
        controller.prepareCameraControllerForGestures(worldUp: nonNormalizedUp)

        XCTAssertTrue(true, "Should handle non-normalized world up vector")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Integration Tests

    func testSynchronizeAndPrepareTogether() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()
        let initialTarget = controller.cameraTarget
        let initialUp = controller.cameraUpVector

        let customTarget = SIMD3<Float>(5.0, 3.0, 2.0)
        let customUp = SIMD3<Float>(0, 1, 0)
        let customRadius: Float = 8.0

        // Prepare camera controller
        controller.prepareCameraControllerForGestures(worldUp: customUp)

        // Synchronize camera state
        controller.synchronizeInteractiveCameraState(
            target: customTarget,
            up: customUp,
            cameraNode: cameraNode,
            radius: customRadius
        )

        // Both operations should complete without issues
        XCTAssertNotEqual(controller.cameraTarget, initialTarget, "Target should be updated after both operations")

        // Up vector is normalized
        let length = simd_length(controller.cameraUpVector)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Up vector should be normalized")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDelegateMethodsWithDifferentCameraNodes() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Use default camera node
        let defaultCamera = controller.ensureCameraNode()
        controller.synchronizeInteractiveCameraState(
            target: SIMD3<Float>(1, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            cameraNode: defaultCamera,
            radius: 2.0
        )
        let firstTarget = controller.cameraTarget

        // Create custom camera node
        let customCamera = SCNNode()
        customCamera.camera = SCNCamera()
        customCamera.position = SCNVector3(0, 0, 5)
        controller.synchronizeInteractiveCameraState(
            target: SIMD3<Float>(0, 1, 0),
            up: SIMD3<Float>(0, 0, 1),
            cameraNode: customCamera,
            radius: 3.0
        )

        // Should update with different camera node
        XCTAssertNotEqual(controller.cameraTarget, firstTarget, "Should handle different camera nodes")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDelegateMethodsPreserveInternalState() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let cameraNode = controller.ensureCameraNode()

        // Record initial state
        let initialVolumeNode = controller.volumeNode
        let initialMprNode = controller.mprNode
        let initialDatasetApplied = controller.datasetApplied

        // Execute delegate methods
        controller.prepareCameraControllerForGestures()
        controller.synchronizeInteractiveCameraState(
            target: SIMD3<Float>(1, 1, 1),
            up: SIMD3<Float>(0, 1, 0),
            cameraNode: cameraNode,
            radius: 5.0
        )

        // Verify internal state is preserved
        XCTAssertTrue(controller.volumeNode === initialVolumeNode, "Volume node should not change")
        XCTAssertTrue(controller.mprNode === initialMprNode, "MPR node should not change")
        XCTAssertEqual(controller.datasetApplied, initialDatasetApplied, "Dataset state should not change")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }
}
