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

    func testAThreadgroupLargerThanTheGridShrinksToIt() {
        // A 2x2x1 volume used to be dispatched with the pipeline's 32x32x1 threadgroup:
        // 1020 of the 1024 threads existed only to take the out-of-range early exit.
        let clamped = MetalDispatch.clamped(
            threadsPerThreadgroup: MTLSize(width: 32, height: 32, depth: 1),
            to: MTLSize(width: 2, height: 2, depth: 1)
        )

        XCTAssertEqual(clamped.width, 2)
        XCTAssertEqual(clamped.height, 2)
        XCTAssertEqual(clamped.depth, 1)
    }

    func testAThreadgroupThatFitsTheGridIsLeftAlone() {
        let clamped = MetalDispatch.clamped(
            threadsPerThreadgroup: MTLSize(width: 32, height: 32, depth: 1),
            to: MTLSize(width: 512, height: 512, depth: 300)
        )

        XCTAssertEqual(clamped.width, 32)
        XCTAssertEqual(clamped.height, 32)
        XCTAssertEqual(clamped.depth, 1)
    }

    func testEachDimensionIsClampedOnItsOwn() {
        let clamped = MetalDispatch.clamped(
            threadsPerThreadgroup: MTLSize(width: 32, height: 32, depth: 4),
            to: MTLSize(width: 10, height: 512, depth: 1)
        )

        XCTAssertEqual(clamped.width, 10)
        XCTAssertEqual(clamped.height, 32)
        XCTAssertEqual(clamped.depth, 1)
    }

    func testClampingNeverProducesAnEmptyThreadgroup() {
        let clamped = MetalDispatch.clamped(
            threadsPerThreadgroup: MTLSize(width: 0, height: 32, depth: 1),
            to: MTLSize(width: 8, height: 0, depth: 0)
        )

        XCTAssertEqual(clamped.width, 1)
        XCTAssertEqual(clamped.height, 1)
        XCTAssertEqual(clamped.depth, 1)
    }

    func testClampingLeavesTheThreadgroupCountUnchanged() {
        // Clamping must not change how much of the grid is covered — only how many
        // threads are launched to cover it.
        let grids = [MTLSize(width: 2, height: 2, depth: 1),
                     MTLSize(width: 17, height: 33, depth: 5),
                     MTLSize(width: 512, height: 512, depth: 300),
                     MTLSize(width: 1, height: 1, depth: 1)]
        let requested = MTLSize(width: 32, height: 32, depth: 1)

        for grid in grids {
            let before = MetalDispatch.threadgroups(for: grid, threadsPerThreadgroup: requested)
            let clamped = MetalDispatch.clamped(threadsPerThreadgroup: requested, to: grid)
            let after = MetalDispatch.threadgroups(for: grid, threadsPerThreadgroup: clamped)

            XCTAssertEqual(before.width, after.width, "grid \(grid)")
            XCTAssertEqual(before.height, after.height, "grid \(grid)")
            XCTAssertEqual(before.depth, after.depth, "grid \(grid)")
        }
    }
}
