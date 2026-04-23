import CoreGraphics
import XCTest

@_spi(Testing) @testable import MTKCore

final class MTKRenderingEngineLifecycleTests: MTKRenderingEngineTestCase {
    func test_createViewport_returnsUniqueIDs() async throws {
        let first = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        let second = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: CGSize(width: 32, height: 32))
        )
        let third = try await engine.createViewport(
            ViewportDescriptor(type: .projection(mode: .mip),
                               initialSize: CGSize(width: 32, height: 32))
        )

        XCTAssertEqual(Set([first, second, third]).count, 3)
    }

    func test_destroyViewport_removesFromRegistry() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 32, height: 32))
        )
        try await engine.setVolume(testDataset, for: viewport)

        await engine.destroyViewport(viewport)

        do {
            _ = try await engine.render(viewport)
            XCTFail("Expected rendering a destroyed viewport to throw")
        } catch MTKRenderingEngine.EngineError.viewportNotFound(let missingViewport) {
            XCTAssertEqual(missingViewport, viewport)
        }
    }

    func test_resizeViewport_updatesState() async throws {
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 16, height: 16))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let resizedSize = CGSize(width: 48, height: 32)
        try await engine.resize(viewport, to: resizedSize)
        let frame = try await engine.render(viewport)

        XCTAssertEqual(frame.metadata.viewportSize, resizedSize)
        XCTAssertEqual(frame.texture.width, Int(resizedSize.width))
        XCTAssertEqual(frame.texture.height, Int(resizedSize.height))
    }
}
