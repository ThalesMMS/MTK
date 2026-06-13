//
//  ViewerInteractionTests.swift
//  MTKUITests
//
//  Interaction-model coverage for issue #1213: capability defaults,
//  command bridging, and scroll/zoom normalization — all GPU-free.
//

import SwiftUI
import XCTest
@testable import MTKUI

final class ViewerInteractionCapabilitiesTests: XCTestCase {

    func test_presets_matchPlatformExpectations() {
        XCTAssertTrue(ViewerInteractionCapabilities.touchOnly.hasTouch)
        XCTAssertFalse(ViewerInteractionCapabilities.touchOnly.hasPointer)
        XCTAssertFalse(ViewerInteractionCapabilities.touchOnly.supportsModifierKeys)

        XCTAssertTrue(ViewerInteractionCapabilities.tabletWithPointer.hasTouch)
        XCTAssertTrue(ViewerInteractionCapabilities.tabletWithPointer.hasPointer)
        XCTAssertTrue(ViewerInteractionCapabilities.tabletWithPointer.hasHardwareKeyboard)

        XCTAssertFalse(ViewerInteractionCapabilities.desktop.hasTouch)
        XCTAssertTrue(ViewerInteractionCapabilities.desktop.hasPointer)
        XCTAssertTrue(ViewerInteractionCapabilities.desktop.hasScrollWheel)
    }

    func test_platformDefault_isTouchFirstOniOS_desktopOnMac() {
#if os(macOS)
        XCTAssertEqual(ViewerInteractionCapabilities.platformDefault, .desktop)
#else
        XCTAssertEqual(ViewerInteractionCapabilities.platformDefault, .touchOnly)
#endif
    }
}

final class ViewerScrollNormalizationTests: XCTestCase {

    func test_preciseScroll_accumulatesUntilStepThreshold() {
        var accumulator = ViewerScrollSliceAccumulator(pointsPerStep: 24)

        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 10, isPrecise: true)), 0)
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 10, isPrecise: true)), 0)
        // 30 points accumulated → one step, 6 points residual.
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 10, isPrecise: true)), 1)
        // 6 + 20 = 26 → another step.
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 20, isPrecise: true)), 1)
    }

    func test_preciseScroll_negativeDirectionAndReset() {
        var accumulator = ViewerScrollSliceAccumulator(pointsPerStep: 24)

        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: -50, isPrecise: true)), -2)
        accumulator.reset()
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 20, isPrecise: true)), 0)
    }

    func test_wheelTicks_mapOneLineToOneStep_withoutResidual() {
        var accumulator = ViewerScrollSliceAccumulator(pointsPerStep: 24)

        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 1, isPrecise: false)), 1)
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 3, isPrecise: false)), 3)
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: -2, isPrecise: false)), -2)
    }

    func test_invertedDirection_flipsSteps() {
        var accumulator = ViewerScrollSliceAccumulator(pointsPerStep: 24, invertsDirection: true)

        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 48, isPrecise: true)), -2)
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: -1, isPrecise: false)), 1)
    }

    func test_zoomFactor_isMultiplicativeAndDirectional() {
        let zoomIn = ViewerScrollZoomNormalizer.zoomFactor(
            for: ViewerScrollEvent(delta: 100, isPrecise: true, hasZoomModifier: true)
        )
        let zoomOut = ViewerScrollZoomNormalizer.zoomFactor(
            for: ViewerScrollEvent(delta: -100, isPrecise: true, hasZoomModifier: true)
        )
        XCTAssertGreaterThan(zoomIn, 1)
        XCTAssertLessThan(zoomOut, 1)
        XCTAssertEqual(zoomIn * zoomOut, 1, accuracy: 0.0001)

        // A wheel tick should produce a comparable (non-trivial) zoom change.
        let wheelZoom = ViewerScrollZoomNormalizer.zoomFactor(
            for: ViewerScrollEvent(delta: 1, isPrecise: false, hasZoomModifier: true)
        )
        XCTAssertGreaterThan(wheelZoom, 1.02)
    }

    func test_zeroDelta_isNeutral() {
        var accumulator = ViewerScrollSliceAccumulator()
        XCTAssertEqual(accumulator.consume(ViewerScrollEvent(delta: 0, isPrecise: true)), 0)
        XCTAssertEqual(
            ViewerScrollZoomNormalizer.zoomFactor(for: ViewerScrollEvent(delta: 0, isPrecise: true)),
            1
        )
    }
}

final class ViewerCommandBridgingTests: XCTestCase {

    @MainActor
    func test_keyboardAndContextMenuModifiers_buildWithoutGPU() {
        var dispatched: [ViewerCommandID] = []
        let view = Color.black
            .viewerKeyboardCommands { dispatched.append($0) }
            .viewerPaneContextMenu { dispatched.append($0) }
            .viewerHoverHighlight()
            .viewerInteractionCapabilities(.tabletWithPointer)

        let host = InteractionHostingController(rootView: AnyView(view))
        XCTAssertNotNil(host.view)
        XCTAssertTrue(dispatched.isEmpty, "no command fires without user input")
    }
}

#if os(iOS)
private typealias InteractionHostingController = UIHostingController<AnyView>
#else
private typealias InteractionHostingController = NSHostingController<AnyView>
#endif
