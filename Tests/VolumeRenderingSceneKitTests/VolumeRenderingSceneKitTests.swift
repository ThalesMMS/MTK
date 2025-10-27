import XCTest
#if canImport(SceneKit)
import SceneKit
import Metal
#endif
@testable import VolumeRenderingSceneKit

final class VolumeRenderingSceneKitTests: XCTestCase {
    func testFactoryCreatesVolumeNodeWhenMetalAvailable() throws {
#if canImport(SceneKit)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on test host")
        }
        let result = VolumeRenderingSceneKitFactory.makeVolumeNode(device: device)
        XCTAssertNotNil(result.node.geometry)
        XCTAssertTrue(result.node.geometry is SCNBox)
#else
        XCTAssertTrue(true)
#endif
    }
}
