import XCTest
@testable import MTKCore

final class FrameMetadataBuilderTests: MTKRenderingEngineTestCase {
    func testMakeMetadata_populatesTimingFieldsAndRouteName() async throws {
        // Arrange
        let builder = FrameMetadataBuilder()

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }

        let viewportID = ViewportID()
        let route = RenderRoute(
            viewportType: .volume3D,
            compositing: .frontToBack,
            passPipeline: []
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 8,
            height: 8,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let inputs = FrameMetadataBuilder.Inputs(
            viewportID: viewportID,
            viewportSize: CGSize(width: 8, height: 8),
            route: route,
            texture: texture,
            mprFrame: nil,
            outputTextureLease: nil,
            renderDuration: 1.0,
            raycastDuration: 2.0,
            uploadDuration: 3.0,
            presentDuration: 4.0
        )

        // Act
        let metadata = builder.makeMetadata(from: inputs)

        // Assert
        XCTAssertEqual(metadata.viewportSize, CGSize(width: 8, height: 8))
        XCTAssertEqual(metadata.renderTime, 1.0)
        XCTAssertEqual(metadata.raycastTime, 2.0)
        XCTAssertEqual(metadata.uploadTime, 3.0)
        XCTAssertEqual(metadata.presentTime, 4.0)
        XCTAssertEqual(metadata.renderGraphRoute, route.profilingName)
    }
}
