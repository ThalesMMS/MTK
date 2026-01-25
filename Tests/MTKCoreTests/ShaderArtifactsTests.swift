import XCTest
@testable import MTKCore

final class ShaderArtifactsTests: XCTestCase {
    func testBundleContainsCompiledMetallib() throws {
#if canImport(Metal)
        guard let url = Bundle.module.url(forResource: "VolumeRendering", withExtension: "metallib") else {
            throw XCTSkip("MTK.metallib not bundled in this configuration")
        }
        let size = (try? Data(contentsOf: url).count) ?? 0
        XCTAssertGreaterThan(size, 0, "Bundled MTK.metallib should not be empty")
#else
        throw XCTSkip("Metal unavailable on this platform")
#endif
    }
}
