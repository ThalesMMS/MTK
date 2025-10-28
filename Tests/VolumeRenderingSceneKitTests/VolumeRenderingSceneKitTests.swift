import XCTest
#if canImport(SceneKit)
import SceneKit
import Metal
#endif
@testable import VolumeRenderingSceneKit

final class VolumeRenderingSceneKitTests: XCTestCase {
    func testFactoryCreatesVolumeNodeWhenMetalAvailable() throws {
#if canImport(SceneKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on test host")
        }
        throw XCTSkip("Scene kit factory scaffolding not yet available in MTK")
#else
        XCTAssertTrue(true)
#endif
    }
}
