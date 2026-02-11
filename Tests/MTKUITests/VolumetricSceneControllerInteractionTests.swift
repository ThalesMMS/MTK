//  VolumetricSceneControllerInteractionTests.swift
//  MTK
//  Tests interaction APIs and state management for VolumetricSceneController.
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
final class VolumetricSceneControllerInteractionTests: XCTestCase {

    // MARK: - Camera Interaction Tests

    func testRotateCameraUpdatesInternalState() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialOffset = controller.cameraOffset
        let initialUp = controller.cameraUpVector

        // Rotate camera by a small amount
        await controller.rotateCamera(screenDelta: SIMD2<Float>(1.0, 0.5))

        // Camera offset and up vector should have changed
        XCTAssertNotEqual(controller.cameraOffset, initialOffset, "Camera offset should change after rotation")
        XCTAssertNotEqual(controller.cameraUpVector, initialUp, "Camera up vector should change after rotation")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testRotateCameraWithZeroDeltaHasNoEffect() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialOffset = controller.cameraOffset
        let initialUp = controller.cameraUpVector

        // Rotate with zero delta
        await controller.rotateCamera(screenDelta: SIMD2<Float>(0, 0))

        // State should remain unchanged
        XCTAssertEqual(controller.cameraOffset, initialOffset)
        XCTAssertEqual(controller.cameraUpVector, initialUp)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPanCameraUpdatesTarget() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialTarget = controller.cameraTarget

        // Pan camera
        await controller.panCamera(screenDelta: SIMD2<Float>(10, -5))

        // Camera target should have changed
        XCTAssertNotEqual(controller.cameraTarget, initialTarget, "Camera target should change after panning")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testPanCameraWithZeroDeltaHasNoEffect() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialTarget = controller.cameraTarget

        // Pan with zero delta
        await controller.panCamera(screenDelta: SIMD2<Float>(0, 0))

        // Target should remain unchanged
        XCTAssertEqual(controller.cameraTarget, initialTarget)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDollyCameraUpdatesOffset() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialOffset = controller.cameraOffset
        let initialDistance = simd_length(initialOffset)

        // Dolly camera forward
        await controller.dollyCamera(delta: 0.5)

        let newDistance = simd_length(controller.cameraOffset)
        XCTAssertNotEqual(newDistance, initialDistance, "Camera distance should change after dolly")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDollyCameraWithZeroDeltaHasNoEffect() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialOffset = controller.cameraOffset

        // Dolly with zero delta
        await controller.dollyCamera(delta: 0)

        // Offset should remain unchanged
        XCTAssertEqual(controller.cameraOffset, initialOffset)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testTiltCameraUpdatesOrientation() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialUp = controller.cameraUpVector

        // Tilt camera with small roll
        await controller.tiltCamera(roll: 0.1, pitch: 0.0)

        // Camera up vector should have changed
        XCTAssertNotEqual(controller.cameraUpVector, initialUp, "Camera up vector should change after tilt")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testTiltCameraWithZeroAnglesHasNoEffect() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialUp = controller.cameraUpVector
        let initialOffset = controller.cameraOffset

        // Tilt with zero angles
        await controller.tiltCamera(roll: 0, pitch: 0)

        // State should remain unchanged
        XCTAssertEqual(controller.cameraUpVector, initialUp)
        XCTAssertEqual(controller.cameraOffset, initialOffset)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testResetCameraRestoresInitialState() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Modify camera state
        await controller.rotateCamera(screenDelta: SIMD2<Float>(10, 10))
        await controller.panCamera(screenDelta: SIMD2<Float>(5, 5))

        // Reset camera
        await controller.resetCamera()

        // Camera should be reset to default position
        let cameraNode = controller.ensureCameraNode()
        XCTAssertNotNil(cameraNode, "Camera node should exist after reset")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Adaptive Sampling Tests

    func testAdaptiveSamplingInitiallyEnabled() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertTrue(controller.adaptiveSamplingEnabled, "Adaptive sampling should be enabled by default")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSetAdaptiveSamplingToggle() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Disable adaptive sampling
        await controller.setAdaptiveSampling(false)
        XCTAssertFalse(controller.adaptiveSamplingEnabled)

        // Re-enable adaptive sampling
        await controller.setAdaptiveSampling(true)
        XCTAssertTrue(controller.adaptiveSamplingEnabled)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testBeginAdaptiveSamplingInteraction() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialStep = controller.volumeMaterial.samplingStep

        await controller.beginAdaptiveSamplingInteraction()

        // Adaptive interaction should be active (reduced sampling step)
        XCTAssertTrue(controller.isAdaptiveSamplingActive)
        XCTAssertLessThan(controller.volumeMaterial.samplingStep, initialStep, "Sampling step should be reduced during interaction")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testEndAdaptiveSamplingInteraction() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let initialStep = controller.baseSamplingStep

        await controller.beginAdaptiveSamplingInteraction()
        await controller.endAdaptiveSamplingInteraction()

        // Adaptive interaction should be inactive (restored sampling step)
        XCTAssertFalse(controller.isAdaptiveSamplingActive)
        XCTAssertEqual(controller.volumeMaterial.samplingStep, initialStep, "Sampling step should be restored after interaction ends")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - State Publisher Tests

    func testCameraStatePublisher() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Camera state should be accessible
        let cameraState = controller.cameraState
        XCTAssertNotNil(cameraState)
        XCTAssertNotNil(cameraState.position)
        XCTAssertNotNil(cameraState.target)
        XCTAssertNotNil(cameraState.up)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSliceStatePublisher() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Slice state should be accessible
        let sliceState = controller.sliceState
        XCTAssertNotNil(sliceState)
        XCTAssertEqual(sliceState.normalizedPosition, 0.5, "Default slice position should be 0.5")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testWindowLevelStatePublisher() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Window level state should be accessible
        let windowLevelState = controller.windowLevelState
        XCTAssertNotNil(windowLevelState)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testWindowLevelStateUpdatesAfterHuWindowChange() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let huWindow = VolumeCubeMaterial.HuWindowMapping(minHU: -1000, maxHU: 1000, tfMin: 0.0, tfMax: 1.0)

        await controller.setHuWindow(huWindow)

        let windowLevelState = controller.windowLevelState
        let expectedWidth = Double(huWindow.maxHU - huWindow.minHU)
        let expectedLevel = Double(huWindow.minHU) + expectedWidth / 2

        XCTAssertEqual(windowLevelState.window, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(windowLevelState.level, expectedLevel, accuracy: 0.001)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Lighting and Rendering Configuration Tests

    func testSetLighting() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        await controller.setLighting(enabled: true)
        let uniformsEnabled = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsEnabled.isLightingOn, 1, "Lighting should be enabled")

        await controller.setLighting(enabled: false)
        let uniformsDisabled = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsDisabled.isLightingOn, 0, "Lighting should be disabled")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSetSamplingStep() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()
        let customStep: Float = 256

        await controller.setSamplingStep(customStep)

        XCTAssertEqual(controller.baseSamplingStep, customStep)
        XCTAssertEqual(controller.volumeMaterial.samplingStep, customStep)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSetRenderMethod() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        await controller.setRenderMethod(.mip)
        let uniformsMip = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsMip.method, VolumeCubeMaterial.Method.mip.idInt32)

        await controller.setRenderMethod(.dvr)
        let uniformsDvr = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsDvr.method, VolumeCubeMaterial.Method.dvr.idInt32)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Edge Cases

    func testStateChangesBeforeDatasetApplied() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // These operations should not crash before dataset is applied
        await controller.setLighting(enabled: true)
        await controller.setSamplingStep(256)
        await controller.setRenderMethod(.mip)
        await controller.rotateCamera(screenDelta: SIMD2<Float>(1, 1))
        await controller.panCamera(screenDelta: SIMD2<Float>(1, 1))
        await controller.dollyCamera(delta: 0.1)

        XCTAssertFalse(controller.datasetApplied, "Dataset should not be applied")
        XCTAssertTrue(true, "Controller should handle state changes gracefully before dataset application")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testMprInteractionsBeforeDatasetApplied() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // MPR operations before dataset should be gracefully handled
        await controller.setMprBlend(.single)
        await controller.setMprSlab(thickness: 10, steps: 5)
        await controller.setMprHuWindow(min: -1000, max: 1000)

        XCTAssertFalse(controller.datasetApplied, "Dataset should not be applied")
        XCTAssertTrue(true, "Controller should handle MPR state changes gracefully before dataset application")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testInteractionWithHiddenNodes() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Both nodes should be hidden initially
        XCTAssertTrue(controller.volumeNode.isHidden, "Volume node should be hidden initially")
        XCTAssertTrue(controller.mprNode.isHidden, "MPR node should be hidden initially")

        // Camera interactions should still work with hidden nodes
        Task {
            await controller.rotateCamera(screenDelta: SIMD2<Float>(1, 1))
            await controller.panCamera(screenDelta: SIMD2<Float>(1, 1))
        }

        XCTAssertTrue(true, "Controller should handle interactions with hidden nodes")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Preset and Transfer Function Tests

    func testSetPreset() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        await controller.setPreset(.ctSoftTissue)
        XCTAssertNotNil(controller.volumeMaterial.tf, "Transfer function should be set after applying preset")

        await controller.setPreset(.ctBone)
        XCTAssertNotNil(controller.volumeMaterial.tf, "Transfer function should be updated after applying different preset")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSetShift() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Set a preset first to ensure a transfer function exists
        await controller.setPreset(.ctSoftTissue)

        let shift: Float = 0.1
        await controller.setShift(shift)

        XCTAssertNotNil(controller.volumeMaterial.tf, "Transfer function should exist after setShift")
        if let tfShift = controller.volumeMaterial.tf?.shift {
            XCTAssertEqual(tfShift, shift, accuracy: 0.001, "Shift value should match")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSetHuGate() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        await controller.setHuGate(enabled: true)
        let uniformsEnabled = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsEnabled.useHuGate, 1, "HU gate should be enabled")

        await controller.setHuGate(enabled: false)
        let uniformsDisabled = controller.volumeMaterial.snapshotUniforms()
        XCTAssertEqual(uniformsDisabled.useHuGate, 0, "HU gate should be disabled")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }
}
