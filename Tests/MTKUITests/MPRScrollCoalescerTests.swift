//  MPRScrollCoalescerTests.swift
//  MTK
//  Validates that fast scroll bursts coalesce into fewer applies without
//  losing steps.

import XCTest
@testable import MTKUI

@MainActor
final class MPRScrollCoalescerTests: XCTestCase {
    func testSingleAddDeliversSteps() async {
        var delivered: [Int] = []
        let coalescer = MPRScrollCoalescer { steps in
            delivered.append(steps)
        }

        coalescer.add(steps: 3)
        await drain(coalescer)

        XCTAssertEqual(delivered, [3])
    }

    func testBurstCoalescesWithoutLosingSteps() async {
        var delivered: [Int] = []
        let coalescer = MPRScrollCoalescer { steps in
            delivered.append(steps)
            // Simulate a slow render so the burst banks up behind it.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let eventCount = 50
        for _ in 0..<eventCount {
            coalescer.add(steps: 1)
        }
        await drain(coalescer)

        XCTAssertEqual(delivered.reduce(0, +), eventCount, "no step may be dropped")
        XCTAssertLessThan(delivered.count, eventCount, "burst must coalesce into fewer applies")
    }

    func testOppositeStepsCancelOut() async {
        var delivered: [Int] = []
        let coalescer = MPRScrollCoalescer { steps in
            delivered.append(steps)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        coalescer.add(steps: 1)
        coalescer.add(steps: 4)
        coalescer.add(steps: -4)
        await drain(coalescer)

        XCTAssertEqual(delivered.reduce(0, +), 1)
    }

    func testZeroStepsAreIgnored() async {
        var delivered: [Int] = []
        let coalescer = MPRScrollCoalescer { steps in
            delivered.append(steps)
        }

        coalescer.add(steps: 0)
        await drain(coalescer)

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertFalse(coalescer.isDrainingForTesting)
    }

    func testCancelDropsPendingSteps() async {
        var delivered: [Int] = []
        let coalescer = MPRScrollCoalescer { steps in
            delivered.append(steps)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        coalescer.add(steps: 1)
        coalescer.add(steps: 10)
        coalescer.cancel()
        XCTAssertEqual(coalescer.pendingStepsForTesting, 0)

        coalescer.add(steps: 2)
        await drain(coalescer)

        XCTAssertEqual(delivered.last, 2)
        XCTAssertEqual(coalescer.pendingStepsForTesting, 0)
    }

    private func drain(_ coalescer: MPRScrollCoalescer) async {
        for _ in 0..<1000 {
            guard coalescer.isDrainingForTesting || coalescer.pendingStepsForTesting != 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("coalescer did not drain in time")
    }
}
