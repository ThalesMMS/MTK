import Metal
import XCTest

@testable import MTKCore

final class MetalDispatchTests: XCTestCase {
    func testThreadgroupsRoundUpEachDimension() {
        let groups = MetalDispatch.threadgroups(
            for: MTLSize(width: 17, height: 33, depth: 5),
            threadsPerThreadgroup: MTLSize(width: 8, height: 16, depth: 2)
        )

        XCTAssertEqual(groups.width, 3)
        XCTAssertEqual(groups.height, 3)
        XCTAssertEqual(groups.depth, 3)
    }

    func testThreadgroupsUseAtLeastOneThreadPerDimension() {
        let groups = MetalDispatch.threadgroups(
            for: MTLSize(width: 4, height: 4, depth: 4),
            threadsPerThreadgroup: MTLSize(width: 0, height: 0, depth: 0)
        )

        XCTAssertEqual(groups.width, 4)
        XCTAssertEqual(groups.height, 4)
        XCTAssertEqual(groups.depth, 4)
    }
}
