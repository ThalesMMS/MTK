import XCTest
@testable import MTKCore

final class RenderRouteResolverTests: MTKRenderingEngineTestCase {
    func testValidateRequirements_throwsWhenTransferTextureMissing() throws {
        // Arrange
        let graph = ViewportRenderGraph()
        let resolver = RenderRouteResolver()

        let viewportID = ViewportID()
        // Use a non-nil handle to bypass the earlier `missingResourceHandle` validation.
        let resourceHandle = VolumeResourceHandle(
            metadata: .init(
                resourceType: .volume,
                debugLabel: nil,
                estimatedBytes: 1,
                pixelFormat: .r16Sint,
                storageMode: .private,
                dimensions: .init(width: 1, height: 1, depth: 1)
            )
        )
        let node = try resolver.resolveNode(
            viewportID: viewportID,
            viewportType: .volume3D,
            resourceHandle: resourceHandle,
            using: graph
        )

        // Act / Assert
        XCTAssertThrowsError(
            try resolver.validateRequirements(
                for: node,
                datasetAvailable: true,
                volumeTextureAvailable: true,
                surfaceAvailable: true,
                transferTextureAvailable: false,
                using: graph
            )
        ) { error in
            guard case RenderGraphError.invalidViewportConfiguration(let errorViewportID, let reason) = error else {
                return XCTFail("Expected missing transfer texture validation failure, got \(error)")
            }
            XCTAssertEqual(errorViewportID, viewportID)
            XCTAssertEqual(reason, "Route volume3D.frontToBack requires a ready transfer texture.")
        }
    }
}
