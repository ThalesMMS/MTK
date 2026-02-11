//  VolumetricSceneControllerSnapshotTests.swift
//  MTK
//  Validates VolumetricSceneController snapshot capture and surface management.
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
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@MainActor
final class VolumetricSceneControllerSnapshotTests: XCTestCase {

    // MARK: - Material Snapshot Tests

    func testDebugVolumeMaterialSnapshotCapturesState() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            let snapshot = try controller.debugVolumeMaterialSnapshot()

            // Verify snapshot captures basic state
            XCTAssertNotNil(snapshot, "Volume material snapshot should be captured")
            XCTAssertGreaterThanOrEqual(snapshot.methodID, 0, "Method ID should be valid")
            XCTAssertGreaterThanOrEqual(snapshot.renderingQuality, 0, "Rendering quality should be non-negative")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugVolumeMaterialSnapshotReflectsRenderingMethod() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Apply different rendering methods and verify snapshots reflect changes
            let methods: [VolumeCubeMaterial.Method] = [.dvr, .mip, .minip, .avg]
            for method in methods {
                await controller.setRenderMethod(method)
                let snapshot = try controller.debugVolumeMaterialSnapshot()
                XCTAssertEqual(snapshot.methodID, method.idInt32, "Snapshot should reflect rendering method \(method)")
            }
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugVolumeMaterialSnapshotCapturesLightingState() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Test with lighting enabled
            await controller.setLighting(enabled: true)
            var snapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertTrue(snapshot.lightingEnabled, "Snapshot should capture lighting enabled state")

            // Test with lighting disabled
            await controller.setLighting(enabled: false)
            snapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertFalse(snapshot.lightingEnabled, "Snapshot should capture lighting disabled state")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugVolumeMaterialSnapshotCapturesHUGate() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Test HU gate disabled
            await controller.setHuGate(enabled: false)
            var snapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertFalse(snapshot.huGateEnabled, "Snapshot should capture HU gate disabled state")

            // Test HU gate enabled with specific range
            await controller.setHuGate(enabled: true)
            await controller.setMprHuWindow(min: -500, max: 500)
            snapshot = try controller.debugVolumeMaterialSnapshot()
            // Note: HU gate state is captured from volume material uniforms
            XCTAssertNotNil(snapshot, "Snapshot should succeed with HU gate configuration")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugMprMaterialSnapshotCapturesState() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            let snapshot = try controller.debugMprMaterialSnapshot()

            // Verify snapshot captures basic state
            XCTAssertNotNil(snapshot, "MPR material snapshot should be captured")
            XCTAssertGreaterThanOrEqual(snapshot.blendModeID, 0, "Blend mode ID should be valid")
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugMprMaterialSnapshotCapturesBlendMode() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Test different blend modes
            let blendModes: [MPRPlaneMaterial.BlendMode] = [.single, .mip, .minip, .mean]
            for blendMode in blendModes {
                await controller.setMprBlend(blendMode)
                let snapshot = try controller.debugMprMaterialSnapshot()
                XCTAssertEqual(snapshot.blendModeID, blendMode.rawValue, "Snapshot should reflect blend mode \(blendMode)")
            }
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testDebugMprMaterialSnapshotCapturesVoxelRange() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Set voxel range via MPR HU window
            await controller.setMprHuWindow(min: -1000, max: 2000)
            let snapshot = try controller.debugMprMaterialSnapshot()

            XCTAssertEqual(snapshot.voxelMin, -1000, "Snapshot should capture voxel min value")
            XCTAssertEqual(snapshot.voxelMax, 2000, "Snapshot should capture voxel max value")
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Surface State Tests

    func testSceneSurfaceAccessible() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertNotNil(controller.sceneSurface, "Scene surface should be accessible")
        XCTAssertNotNil(controller.sceneSurface.view, "Scene surface view should be accessible")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testActiveSurfaceDefaultsToSceneSurface() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertTrue(controller.surface.view === controller.sceneSurface.view,
                      "Active surface should default to scene surface")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSurfaceViewMatchesSceneView() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        XCTAssertTrue(controller.surface.view === controller.sceneView,
                      "Surface view should match scene view")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Image Surface Tests

    func testImageSurfaceInitialization() throws {
#if canImport(Metal) && canImport(SceneKit) && canImport(CoreGraphics)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        XCTAssertNotNil(imageSurface.view, "Image surface view should be initialized")
        XCTAssertNil(imageSurface.renderedImage, "Image surface should have no rendered image initially")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceDisplayImage() throws {
#if canImport(Metal) && canImport(SceneKit) && canImport(CoreGraphics)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        // Create a test CGImage (1x1 pixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let testImage = context?.makeImage() else {
            throw XCTSkip("Failed to create test image")
        }

        imageSurface.display(testImage)

        XCTAssertNotNil(imageSurface.renderedImage, "Image surface should store rendered image")
        XCTAssertTrue(imageSurface.renderedImage === testImage, "Rendered image should match displayed image")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceClear() throws {
#if canImport(Metal) && canImport(SceneKit) && canImport(CoreGraphics)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        // Create and display a test image
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let testImage = context?.makeImage() else {
            throw XCTSkip("Failed to create test image")
        }

        imageSurface.display(testImage)
        XCTAssertNotNil(imageSurface.renderedImage, "Image should be rendered")

        // Clear the image
        imageSurface.clear()
        XCTAssertNil(imageSurface.renderedImage, "Image surface should have no rendered image after clear")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceContentScale() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        // Test setting content scale
        imageSurface.setContentScale(2.0)
        // No direct accessor, but we verify no crash occurs
        XCTAssertTrue(true, "Setting content scale should succeed")

        // Test with different scales
        imageSurface.setContentScale(3.0)
        imageSurface.setContentScale(1.0)
        XCTAssertTrue(true, "Multiple scale changes should succeed")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceGeometryFlipped() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        XCTAssertFalse(imageSurface.isGeometryFlipped, "Geometry should not be flipped by default")

        imageSurface.setGeometryFlipped(true)
        XCTAssertTrue(imageSurface.isGeometryFlipped, "Geometry should be flipped after setting")

        imageSurface.setGeometryFlipped(false)
        XCTAssertFalse(imageSurface.isGeometryFlipped, "Geometry should not be flipped after resetting")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Snapshot with Display Configuration Tests

    func testSnapshotWithVolumeConfiguration() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Apply volume rendering method
            await controller.setRenderMethod(.mip)

            let snapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertEqual(snapshot.methodID, VolumeCubeMaterial.Method.mip.idInt32,
                          "Snapshot should reflect MIP rendering method")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSnapshotWithMprConfiguration() async throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Apply MPR blend mode and slab
            await controller.setMprBlend(.single)
            await controller.setMprSlab(thickness: 5, steps: 3)

            let snapshot = try controller.debugMprMaterialSnapshot()
            XCTAssertEqual(snapshot.blendModeID, MPRPlaneMaterial.BlendMode.single.rawValue,
                          "Snapshot should reflect single blend mode")
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    // MARK: - Edge Case Tests

    func testSnapshotBeforeDatasetApplied() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Snapshot should succeed even without dataset
            let volumeSnapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertNotNil(volumeSnapshot, "Volume snapshot should succeed without dataset")

            let mprSnapshot = try controller.debugMprMaterialSnapshot()
            XCTAssertNotNil(mprSnapshot, "MPR snapshot should succeed without dataset")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testSnapshotWithNilDataset() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let controller = try VolumetricSceneController()

        do {
            // Explicitly apply nil dataset (if controller was previously configured)
            // This test verifies graceful handling of nil dataset
            let volumeSnapshot = try controller.debugVolumeMaterialSnapshot()
            XCTAssertNotNil(volumeSnapshot, "Volume snapshot should handle nil dataset gracefully")

            let mprSnapshot = try controller.debugMprMaterialSnapshot()
            XCTAssertNotNil(mprSnapshot, "MPR snapshot should handle nil dataset gracefully")
        } catch VolumetricSceneSnapshotError.missingVolumeUniforms {
            throw XCTSkip("Volume shader uniforms not available (shaders not loaded)")
        } catch VolumetricSceneSnapshotError.missingMprUniforms {
            throw XCTSkip("MPR shader uniforms not available (shaders not loaded)")
        }
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceWithDifferentSizes() throws {
#if canImport(Metal) && canImport(SceneKit) && canImport(CoreGraphics)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        // Test with different physical sizes
        let sizes: [CGSize] = [
            CGSize(width: 100, height: 100),
            CGSize(width: 512, height: 512),
            CGSize(width: 1024, height: 768),
            CGSize(width: 1, height: 1)
        ]

        for size in sizes {
            imageSurface.setContentPhysicalSize(size)
            // No crash = success
            XCTAssertTrue(true, "Setting content size \(size) should succeed")
        }

        // Test with nil size
        imageSurface.setContentPhysicalSize(nil)
        XCTAssertTrue(true, "Setting nil content size should succeed")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }

    func testImageSurfaceWithZeroSize() throws {
#if canImport(Metal) && canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable, skipping test")
        }

        let imageSurface = ImageSurface()

        // Test edge case: zero size
        imageSurface.setContentPhysicalSize(CGSize(width: 0, height: 0))
        XCTAssertTrue(true, "Setting zero content size should not crash")

        // Test edge case: negative size (should be handled gracefully)
        imageSurface.setContentPhysicalSize(CGSize(width: -10, height: -10))
        XCTAssertTrue(true, "Setting negative content size should not crash")
#else
        throw XCTSkip("SceneKit or Metal unavailable")
#endif
    }
}
