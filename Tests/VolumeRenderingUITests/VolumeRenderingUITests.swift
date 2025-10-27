import XCTest
@testable import VolumeRenderingUI

final class VolumeRenderingUITests: XCTestCase {
    func testPlaceholderViewBody() {
#if canImport(SwiftUI)
        let view = VolumeRenderingPlaceholderView()
        _ = view.body
        XCTAssertTrue(true)
#else
        XCTAssertTrue(true)
#endif
    }
}
