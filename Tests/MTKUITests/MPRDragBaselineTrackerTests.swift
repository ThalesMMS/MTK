//
//  MPRDragBaselineTrackerTests.swift
//  MTK
//
//  Validates that coalesced MPR drags keep per-gesture baselines isolated.
//

import CoreGraphics
import XCTest
@testable import MTKUI

@MainActor
final class MPRDragBaselineTrackerTests: XCTestCase {
    func testNewGestureDoesNotInheritPreviousGestureBaselineOnSameAxis() {
        var tracker = MPRDragBaselineTracker()
        let firstGesture = tracker.beginGesture(axis: .axial)
        XCTAssertEqual(tracker.apply(gestureID: firstGesture, translation: CGSize(width: 0, height: 200)),
                       CGSize(width: 0, height: 200))
        tracker.endGesture(axis: .axial)

        let secondGesture = tracker.beginGesture(axis: .axial)
        XCTAssertEqual(tracker.apply(gestureID: secondGesture, translation: CGSize(width: 0, height: 5)),
                       CGSize(width: 0, height: 5))
    }

    func testEndGestureClearsAppliedTranslationByDefault() {
        var tracker = MPRDragBaselineTracker()
        let gesture = tracker.beginGesture(axis: .axial)
        _ = tracker.apply(gestureID: gesture, translation: CGSize(width: 0, height: 150))

        tracker.endGesture(axis: .axial)

        XCTAssertEqual(tracker.apply(gestureID: gesture, translation: CGSize(width: 0, height: 200)),
                       CGSize(width: 0, height: 200))
    }

    func testEndedGestureCanApplyResidualAfterNextGestureStartsWithoutUsingNewBaseline() {
        var tracker = MPRDragBaselineTracker()
        let firstGesture = tracker.beginGesture(axis: .axial)
        _ = tracker.apply(gestureID: firstGesture, translation: CGSize(width: 0, height: 150))
        tracker.endGesture(axis: .axial, preserveAppliedTranslation: true)

        let secondGesture = tracker.beginGesture(axis: .axial)
        _ = tracker.apply(gestureID: secondGesture, translation: CGSize(width: 0, height: 5))

        XCTAssertEqual(tracker.apply(gestureID: firstGesture, translation: CGSize(width: 0, height: 200)),
                       CGSize(width: 0, height: 50))
        tracker.clear(gestureID: firstGesture)

        XCTAssertEqual(tracker.apply(gestureID: secondGesture, translation: CGSize(width: 0, height: 8)),
                       CGSize(width: 0, height: 3))
    }

    func testClearingEndedGestureDoesNotRemoveActiveGestureOnSameAxis() {
        var tracker = MPRDragBaselineTracker()
        let firstGesture = tracker.beginGesture(axis: .axial)
        _ = tracker.apply(gestureID: firstGesture, translation: CGSize(width: 0, height: 200))
        tracker.endGesture(axis: .axial)

        let secondGesture = tracker.beginGesture(axis: .axial)
        _ = tracker.apply(gestureID: secondGesture, translation: CGSize(width: 0, height: 5))
        tracker.clear(gestureID: firstGesture)

        XCTAssertEqual(tracker.activeGestureID(for: .axial), secondGesture)
        XCTAssertEqual(tracker.apply(gestureID: secondGesture, translation: CGSize(width: 0, height: 12)),
                       CGSize(width: 0, height: 7))
    }
}
