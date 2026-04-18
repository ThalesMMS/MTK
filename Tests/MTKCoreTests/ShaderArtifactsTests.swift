import XCTest
@testable import MTKCore

final class ShaderArtifactsTests: XCTestCase {
    func testBundleContainsCompiledMetallib() throws {
#if canImport(Metal)
        guard let url = Bundle.module.url(forResource: "MTK", withExtension: "metallib") else {
            XCTFail("Bundle.module is missing required MTK.metallib")
            return
        }
        let size = (try? Data(contentsOf: url).count) ?? 0
        XCTAssertGreaterThan(size, 0, "Required bundled MTK.metallib should not be empty")
#else
        throw XCTSkip("Metal unavailable on this platform")
#endif
    }
}
