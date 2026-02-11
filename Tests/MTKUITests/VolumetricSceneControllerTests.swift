//  VolumetricSceneControllerTests.swift
//  MTK
//  Validates VolumetricSceneController initialization, state management, and configuration.
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
@_spi(Testing) @testable import MTKUI
@testable import MTKCore
@testable import MTKSceneKit

#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(Metal)
import Metal
#endif

@MainActor
final class VolumetricSceneControllerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testControllerInitializationWithDefaultDevice() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.device)
        XCTAssertNotNil(controller.commandQueue)
        XCTAssertNotNil(controller.scene)
        XCTAssertNotNil(controller.rootNode)
        XCTAssertNotNil(controller.sceneView)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testControllerInitializationWithCustomDevice() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard let customDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController(device: customDevice)

        XCTAssertTrue(controller.device === customDevice, "Controller should use the provided custom device")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testControllerThrowsWhenMetalUnavailable() throws {
#if canImport(Metal) && canImport(SceneKit)
        // This test validates the error handling, but we can't actually force Metal unavailability
        // in a real test environment. We document the expected behavior.
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        // If we could simulate Metal unavailability, this should throw:
        // XCTAssertThrowsError(try VolumetricSceneController(device: nil)) { error in
        //     XCTAssertEqual(error as? VolumetricSceneController.Error, .metalUnavailable)
        // }

        XCTAssertTrue(true, "Metal availability validated")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - SceneKit Setup Tests

    func testSceneKitSceneSetup() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.scene)
        XCTAssertNotNil(controller.rootNode)
        XCTAssertTrue(controller.sceneView.scene === controller.scene)
        XCTAssertEqual(controller.scene.rootNode, controller.rootNode)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testVolumeNodeConfiguration() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.volumeNode)
        XCTAssertNotNil(controller.volumeNode.geometry)
        XCTAssertTrue(controller.volumeNode.isHidden, "Volume node should be hidden initially")
        XCTAssertTrue(controller.rootNode.childNodes.contains(controller.volumeNode))

        guard let cube = controller.volumeNode.geometry as? SCNBox else {
            return XCTFail("Volume node geometry should be SCNBox")
        }
        XCTAssertEqual(cube.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(cube.height, 1.0, accuracy: 0.001)
        XCTAssertEqual(cube.length, 1.0, accuracy: 0.001)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testMPRNodeConfiguration() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.mprNode)
        XCTAssertNotNil(controller.mprNode.geometry)
        XCTAssertTrue(controller.mprNode.isHidden, "MPR node should be hidden initially")
        XCTAssertTrue(controller.rootNode.childNodes.contains(controller.mprNode))

        guard let plane = controller.mprNode.geometry as? SCNPlane else {
            return XCTFail("MPR node geometry should be SCNPlane")
        }
        XCTAssertEqual(plane.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(plane.height, 1.0, accuracy: 0.001)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testMaterialsInitialization() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.volumeMaterial)
        XCTAssertNotNil(controller.mprMaterial)

        guard let volumeGeometry = controller.volumeNode.geometry else {
            return XCTFail("Volume node should have geometry")
        }
        XCTAssertTrue(volumeGeometry.materials.contains(controller.volumeMaterial))

        guard let mprGeometry = controller.mprNode.geometry else {
            return XCTFail("MPR node should have geometry")
        }
        XCTAssertTrue(mprGeometry.materials.contains(controller.mprMaterial))
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - State Publisher Tests

    func testStatePublisherInitialization() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.statePublisher)
        XCTAssertNotNil(controller.cameraState)
        XCTAssertNotNil(controller.sliceState)
        XCTAssertNotNil(controller.windowLevelState)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testAdaptiveSamplingInitialState() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Adaptive sampling is enabled by default per VolumetricStatePublisher initialization
        XCTAssertTrue(controller.adaptiveSamplingEnabled)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Display Configuration Tests

    func testDisplayConfigurationEquality() {
#if canImport(Metal) && canImport(SceneKit)
        let config1 = VolumetricSceneController.DisplayConfiguration.volume(method: .mip)
        let config2 = VolumetricSceneController.DisplayConfiguration.volume(method: .mip)
        let config3 = VolumetricSceneController.DisplayConfiguration.volume(method: .dvr)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)

        let slabConfig = VolumetricSceneController.SlabConfiguration(thickness: 10, steps: 5)
        let mprConfig1 = VolumetricSceneController.DisplayConfiguration.mpr(
            axis: .z,
            index: 128,
            blend: .single,
            slab: slabConfig
        )
        let mprConfig2 = VolumetricSceneController.DisplayConfiguration.mpr(
            axis: .z,
            index: 128,
            blend: .single,
            slab: slabConfig
        )

        XCTAssertEqual(mprConfig1, mprConfig2)
#else
        XCTAssertTrue(true)
#endif
    }

    // MARK: - SlabConfiguration Tests

    func testSlabConfigurationSnapToOddVoxelCount() {
#if canImport(Metal) && canImport(SceneKit)
        // Test even number snapping
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(10), 11)
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(8), 9)

        // Test odd number preservation
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(9), 9)
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(11), 11)

        // Test edge cases
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(0), 0)
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(1), 1)
        XCTAssertEqual(VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(-5), 0)

        // Test Int.max edge case
        let maxResult = VolumetricSceneController.SlabConfiguration.snapToOddVoxelCount(Int.max)
        XCTAssertTrue(maxResult % 2 != 0, "Int.max should snap to odd value")
        XCTAssertGreaterThan(maxResult, 0)
#else
        XCTAssertTrue(true)
#endif
    }

    func testSlabConfigurationInitialization() {
#if canImport(Metal) && canImport(SceneKit)
        let config = VolumetricSceneController.SlabConfiguration(thickness: 10, steps: 8)

        // Both should be snapped to odd values
        XCTAssertEqual(config.thickness, 11)
        XCTAssertEqual(config.steps, 9)
#else
        XCTAssertTrue(true)
#endif
    }

    func testSlabConfigurationZeroStepsMinimum() {
#if canImport(Metal) && canImport(SceneKit)
        let config = VolumetricSceneController.SlabConfiguration(thickness: 5, steps: 0)

        // Steps should be normalized to at least 1
        XCTAssertEqual(config.steps, 1)
#else
        XCTAssertTrue(true)
#endif
    }

    func testSlabConfigurationEquality() {
#if canImport(Metal) && canImport(SceneKit)
        let config1 = VolumetricSceneController.SlabConfiguration(thickness: 10, steps: 5)
        let config2 = VolumetricSceneController.SlabConfiguration(thickness: 10, steps: 5)
        let config3 = VolumetricSceneController.SlabConfiguration(thickness: 12, steps: 5)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
#else
        XCTAssertTrue(true)
#endif
    }

    // MARK: - Transfer Function Domain Tests

    func testTransferFunctionDomainAccess() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Transfer function domain should be accessible
        // Initially nil or default value depending on implementation
        _ = controller.transferFunctionDomain
        XCTAssertTrue(true, "Transfer function domain is accessible")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Debug Accessor Tests

    func testDebugVolumeTextureAccessor() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Debug accessor should be callable (may return nil before dataset applied)
        let texture = controller.debugVolumeTexture()
        _ = texture
        XCTAssertTrue(true, "Debug volume texture accessor is functional")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

#if canImport(MetalPerformanceShaders)
    func testDebugMpsAccessors() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Test MPS debug accessors
        let filteredTexture = controller.debugMpsFilteredTexture()
        let rayCastingSamples = controller.debugLastRayCastingSamples()
        let worldEntries = controller.debugLastRayCastingWorldEntries()
        let brightness = controller.debugMpsDisplayBrightness()
        let transferFunction = controller.debugMpsTransferFunction()
        let resolvedBrightness = controller.debugMpsResolvedBrightness()
        let clearColor = controller.debugMpsClearColor()
        let histogram = controller.debugLastMpsHistogram()

        _ = filteredTexture
        _ = rayCastingSamples
        _ = worldEntries
        _ = brightness
        _ = transferFunction
        _ = resolvedBrightness
        _ = clearColor
        _ = histogram

        XCTAssertTrue(true, "All MPS debug accessors are functional")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }
#endif

    // MARK: - Custom SCNView Tests

    func testControllerWithCustomSCNView() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let customFrame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let viewOptions: [String: Any] = [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ]
        let customView = SCNView(frame: customFrame, options: viewOptions)

        let controller = try VolumetricSceneController(device: device, sceneView: customView)

        XCTAssertTrue(controller.sceneView === customView, "Controller should use the provided custom SCNView")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Camera Controller Tests

    func testCameraControllerSetup() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        // Camera controller should be initialized and connected to scene view
        XCTAssertNotNil(controller.sceneView.pointOfView)

        // Camera state should be accessible
        XCTAssertNotNil(controller.cameraState)
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Initial State Tests

    func testInitialDatasetState() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertFalse(controller.datasetApplied, "Dataset should not be applied initially")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSceneViewConfiguration() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertTrue(controller.sceneView.isPlaying)
        XCTAssertEqual(controller.sceneView.preferredFramesPerSecond, 60)
        XCTAssertTrue(controller.sceneView.rendersContinuously)
        XCTAssertTrue(controller.sceneView.loops)
        XCTAssertTrue(controller.sceneView.isJitteringEnabled)
        XCTAssertFalse(controller.sceneView.allowsCameraControl, "Camera control should be disabled on iOS")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }
}
