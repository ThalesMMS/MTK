//
//  HistogramCoverageTests.swift
//  MTK
//
//  The check that keeps a histogram which counted nothing from reading as a result.
//

@_spi(Testing) import MTKCore
import XCTest

final class HistogramCoverageTests: XCTestCase {
    func testAZeroedHistogramIsAShortfall() {
        let zeroed = [[UInt32]](repeating: [UInt32](repeating: 0, count: 64), count: 1)

        let shortfall = HistogramCoverage.shortfall(in: zeroed, expectedVoxelCount: 4)

        XCTAssertEqual(shortfall, HistogramCoverage.Shortfall(channel: 0, counted: 0, expected: 4))
    }

    func testACompleteHistogramIsNotAShortfall() {
        var histogram = [UInt32](repeating: 0, count: 64)
        histogram[0] = 1
        histogram[32] = 1
        histogram[63] = 2

        XCTAssertNil(HistogramCoverage.shortfall(in: [histogram], expectedVoxelCount: 4))
    }

    func testTheFirstShortChannelIsReported() {
        var complete = [UInt32](repeating: 0, count: 8)
        complete[0] = 4
        let empty = [UInt32](repeating: 0, count: 8)

        let shortfall = HistogramCoverage.shortfall(in: [complete, empty, empty],
                                                    expectedVoxelCount: 4)

        XCTAssertEqual(shortfall?.channel, 1)
        XCTAssertEqual(shortfall?.counted, 0)
    }

    func testCountsAboveTheVoxelCountAreAlsoAShortfall() {
        // Double-counting is as much a coverage defect as counting nothing.
        var histogram = [UInt32](repeating: 0, count: 8)
        histogram[3] = 9

        XCTAssertEqual(HistogramCoverage.shortfall(in: [histogram], expectedVoxelCount: 4)?.counted, 9)
    }

    func testAVolumeThatOverflowsThe32BitCountersIsNotChecked() {
        // Past UInt32.max the kernel's counters wrap, so a total that disagrees says
        // nothing about whether the dispatch covered the grid.
        let zeroed = [[UInt32]](repeating: [0], count: 1)

        XCTAssertNil(HistogramCoverage.shortfall(in: zeroed,
                                                 expectedVoxelCount: Int(UInt32.max) + 1))
    }

    func testAnEmptyGridIsNotChecked() {
        XCTAssertNil(HistogramCoverage.shortfall(in: [[0, 0]], expectedVoxelCount: 0))
    }

    func testTotalShortfallSumsEveryRow() {
        let bins: [[UInt32]] = [[1, 0], [0, 2], [1, 0]]

        XCTAssertNil(HistogramCoverage.totalShortfall(in: bins, expectedVoxelCount: 4))
        XCTAssertEqual(HistogramCoverage.totalShortfall(in: bins, expectedVoxelCount: 5)?.counted, 4)
    }

    func testVoxelCountTreatsA2DTextureAsOneSliceDeep() {
        XCTAssertEqual(HistogramCoverage.voxelCount(width: 2, height: 2, depth: 0), 4)
        XCTAssertEqual(HistogramCoverage.voxelCount(width: 4, height: 4, depth: 3), 48)
    }
}
