//  GestureStateTests.swift
//  MTK
//  Validates gesture state bookkeeping for volumetric interactions.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
@testable import MTKUI

@MainActor
final class GestureStateTests: XCTestCase {
    func testStateRecordsLastEvent() {
#if canImport(SwiftUI)
        let state = VolumeGestureState()
        let event = VolumeGestureEvent.translate(axis: .volume, delta: CGSize(width: 10, height: -4))
        state.ingest(event)
        XCTAssertEqual(state.lastEvent, event)
#else
        XCTAssertTrue(true)
#endif
    }

    func testContextUpdatesWindowLevel() {
#if canImport(SwiftUI)
        let state = VolumeGestureState()
        let context = state.makeContext()
        let expectation = expectation(description: "window level update")
        context.onWindowLevel(WindowLevelShift(window: 200, level: 20))
        DispatchQueue.main.async {
            XCTAssertEqual(state.windowLevelShift.level, 20)
            XCTAssertEqual(state.windowLevelShift.window, 200)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.1)
#else
        XCTAssertTrue(true)
#endif
    }
}
