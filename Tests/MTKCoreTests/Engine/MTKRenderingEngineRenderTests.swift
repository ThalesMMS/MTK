import CoreGraphics
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

final class MTKRenderingEngineRenderTests: MTKRenderingEngineTestCase {
    func test_renderVolume3D_returnsValidTexture() async throws {
        let viewportSize = CGSize(width: 40, height: 24)
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: viewportSize)
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)

        XCTAssertEqual(frame.viewportID, viewport)
        XCTAssertEqual(frame.texture.textureType, .type2D)
        XCTAssertEqual(frame.texture.width, Int(viewportSize.width))
        XCTAssertEqual(frame.texture.height, Int(viewportSize.height))
        XCTAssertEqual(frame.metadata.viewportSize, viewportSize)
        XCTAssertNotNil(frame.outputTextureLease)
        XCTAssertFalse(frame.outputTextureLease?.isReleased ?? true)

        frame.outputTextureLease?.release()
        let poolInUseCount = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(poolInUseCount, 0)
    }

    func test_renderMPR_returnsValidTexture() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)

        XCTAssertEqual(frame.viewportID, viewport)
        XCTAssertEqual(frame.texture.textureType, .type2D)
        XCTAssertEqual(frame.texture.width, 32)
        XCTAssertEqual(frame.texture.height, 32)
        XCTAssertNotNil(frame.mprFrame)
        XCTAssertNil(frame.outputTextureLease)
    }

    func test_renderProjectionModes_returnValidTextureAndExplicitRoute() async throws {
        let expected: [(ViewportType, VolumeRenderRequest.Compositing)] = [
            (.projection(mode: .mip), .maximumIntensity),
            (.projection(mode: .aip), .averageIntensity),
            (.projection(mode: .minip), .minimumIntensity)
        ]

        for (viewportType, compositing) in expected {
            let viewport = try await engine.createViewport(
                ViewportDescriptor(type: viewportType,
                                   initialSize: CGSize(width: 28, height: 20))
            )
            try await engine.setVolume(testDataset, for: viewport)

            let frame = try await engine.render(viewport)

            XCTAssertEqual(frame.route.viewportType, viewportType)
            XCTAssertEqual(frame.route.compositing, compositing)
            XCTAssertEqual(frame.route.passPipeline.map(\.kind), [.volumeRaycast, .presentation])
            XCTAssertEqual(frame.metadata.renderGraphRoute, frame.route.profilingName)
            XCTAssertEqual(frame.texture.width, 28)
            XCTAssertEqual(frame.texture.height, 20)
            XCTAssertNotNil(frame.outputTextureLease)
            frame.outputTextureLease?.release()
            await engine.destroyViewport(viewport)
        }
    }

    func test_renderVolumeRouteFailsBeforeDispatchWhenTransferTextureIsNotReady() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .projection(mode: .mip),
                               initialSize: CGSize(width: 28, height: 20))
        )
        try await engine.setVolume(testDataset, for: viewport)
        try await engine.configure(viewport,
                                   transferFunction: VolumeTransferFunction(opacityPoints: [],
                                                                           colourPoints: []))

        do {
            _ = try await engine.render(viewport)
            XCTFail("Expected invalid viewport configuration for missing transfer texture readiness")
        } catch RenderGraphError.invalidViewportConfiguration(let viewportID, let reason) {
            XCTAssertEqual(viewportID, viewport)
            XCTAssertTrue(reason.contains("transfer texture"))
        } catch {
            XCTFail("Expected RenderGraphError.invalidViewportConfiguration, got \(error)")
        }
    }

    func test_renderedFrameFailsPresentationValidationWhenSurfaceIsMissing() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .projection(mode: .mip),
                               initialSize: CGSize(width: 20, height: 20))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        defer { frame.outputTextureLease?.release() }
        let graph = ViewportRenderGraph()

        XCTAssertThrowsError(try graph.validatePresentationSurface(for: frame, surfaceExists: false)) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingPresentationSurface(viewport))
        }
    }

    func test_renderMPR_usesClinicalPlaneFactoryGeometry() async throws {
        let dataset = VolumeDataset(
            data: Data(repeating: 0, count: 4 * 5 * 6 * MemoryLayout<Int16>.size),
            dimensions: VolumeDimensions(width: 4, height: 5, depth: 6),
            spacing: VolumeSpacing(x: 1, y: 2, z: 3),
            pixelFormat: .int16Signed,
            orientation: VolumeOrientation(
                row: SIMD3<Float>(0, 1, 0),
                column: SIMD3<Float>(-1, 0, 0),
                origin: SIMD3<Float>(100, 200, 300)
            )
        )
        let viewportSize = CGSize(width: 32, height: 24)
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: viewportSize)
        )
        try await engine.setVolume(dataset, for: viewport)
        try await engine.configure(viewport,
                                   slicePosition: 0.5,
                                   window: nil)

        let frame = try await engine.render(viewport)
        let expectedPlane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                              axis: .z,
                                                              slicePosition: 0.5)
            .sizedForOutput(viewportSize)

        XCTAssertEqual(frame.mprFrame?.planeGeometry, expectedPlane)
    }

    func test_renderMPR_reusesFrameWhenOnlyWindowChanges() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let first = try await engine.render(viewport)
        let firstTextureID = ObjectIdentifier(first.texture as AnyObject)

        try await engine.configure(viewport,
                                   slicePosition: 0.5,
                                   window: -500...600)
        let second = try await engine.render(viewport)

        XCTAssertEqual(ObjectIdentifier(second.texture as AnyObject), firstTextureID)
        XCTAssertNotNil(second.mprFrame)
    }

    func test_renderMPR_invalidatesFrameWhenSliceChanges() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let first = try await engine.render(viewport)
        let firstTextureID = ObjectIdentifier(first.texture as AnyObject)

        try await engine.configure(viewport,
                                   slicePosition: 0.8,
                                   window: nil)
        let second = try await engine.render(viewport)

        XCTAssertNotEqual(ObjectIdentifier(second.texture as AnyObject), firstTextureID)
        XCTAssertNotNil(second.mprFrame)
    }

    func test_renderMPR_invalidatesFrameWhenSlabConfigurationChanges() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let first = try await engine.render(viewport)
        let firstTextureID = ObjectIdentifier(first.texture as AnyObject)

        try await engine.configure(viewport,
                                   slabThickness: 3,
                                   slabSteps: 1)
        let second = try await engine.render(viewport)
        let secondTextureID = ObjectIdentifier(second.texture as AnyObject)
        XCTAssertNotEqual(secondTextureID, firstTextureID)

        try await engine.configure(viewport,
                                   slabThickness: 3,
                                   slabSteps: 5)
        let third = try await engine.render(viewport)

        XCTAssertNotEqual(ObjectIdentifier(third.texture as AnyObject), secondTextureID)
        XCTAssertNotNil(third.mprFrame)
    }

    func test_renderMPR_invalidatesFrameWhenBlendChanges() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let first = try await engine.render(viewport)
        let firstTextureID = ObjectIdentifier(first.texture as AnyObject)

        try await engine.configure(viewport,
                                   slabThickness: 1,
                                   slabSteps: 1,
                                   blend: .maximum)
        let second = try await engine.render(viewport)

        XCTAssertNotEqual(ObjectIdentifier(second.texture as AnyObject), firstTextureID)
        XCTAssertNotNil(second.mprFrame)
    }

    func test_renderMPRScrollProducesTextureFrames() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        var previousGeometry: MPRPlaneGeometry?
        for slicePosition in stride(from: Float(0.1), through: Float(0.9), by: Float(0.2)) {
            try await engine.configure(viewport,
                                       slicePosition: slicePosition,
                                       window: nil)
            let frame = try await engine.render(viewport)
            XCTAssertEqual(frame.texture.width, 32)
            XCTAssertEqual(frame.texture.height, 32)
            let geometry = try XCTUnwrap(frame.mprFrame?.planeGeometry)
            if let previousGeometry {
                XCTAssertNotEqual(geometry, previousGeometry)
            }
            previousGeometry = geometry
        }
    }

    func test_renderWithoutVolume_throws() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 16, height: 16))
        )

        do {
            _ = try await engine.render(viewport)
            XCTFail("Expected render without a volume to throw")
        } catch MTKRenderingEngine.EngineError.volumeNotSet(let missingViewport) {
            XCTAssertEqual(missingViewport, viewport)
        }
    }
}
