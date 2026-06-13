//
//  ViewerLayoutClassTests.swift
//  MTKUITests
//
//  Layout-class resolution coverage for issue #1210: representative
//  iPhone/iPad/macOS dimensions must map to distinct classes, and the
//  compact-phone chrome boundary must match the historical behavior.
//

import XCTest
@testable import MTKUI

final class ViewerLayoutClassTests: XCTestCase {

    private func resolve(
        width: CGFloat = 0,
        height: CGFloat = 0,
        hCompact: Bool? = nil,
        vCompact: Bool? = nil,
        desktop: Bool = false
    ) -> ViewerLayoutClass {
        ViewerLayoutClassResolver.resolve(ViewerLayoutContext(
            size: CGSize(width: width, height: height),
            horizontalSizeClassIsCompact: hCompact,
            verticalSizeClassIsCompact: vCompact,
            prefersDesktopIdioms: desktop
        ))
    }

    func test_macOS_resolvesDesktop_regardlessOfSize() {
        XCTAssertEqual(resolve(width: 400, height: 300, desktop: true), .desktop)
        XCTAssertEqual(resolve(width: 1920, height: 1080, desktop: true), .desktop)
        XCTAssertEqual(resolve(desktop: true), .desktop)
    }

    func test_iPhonePortrait_resolvesCompactPhone() {
        XCTAssertEqual(resolve(width: 390, height: 844, hCompact: true, vCompact: false), .compactPhone)
        // Width unknown (environment-only resolution) keeps the historical boundary.
        XCTAssertEqual(resolve(hCompact: true, vCompact: false), .compactPhone)
    }

    func test_iPadNarrowSplitView_resolvesCompactPhone() {
        XCTAssertEqual(resolve(width: 320, height: 1024, hCompact: true, vCompact: false), .compactPhone)
        XCTAssertEqual(resolve(width: 375, height: 1024, hCompact: true, vCompact: false), .compactPhone)
    }

    func test_iPhoneLandscape_resolvesCompactTablet() {
        // Vertically compact windows (phone landscape) never stack the
        // compact-phone chrome.
        XCTAssertEqual(resolve(width: 844, height: 390, hCompact: true, vCompact: true), .compactTablet)
        XCTAssertEqual(resolve(width: 932, height: 430, hCompact: false, vCompact: true), .compactTablet)
    }

    func test_iPadFullScreen_resolvesTablet() {
        XCTAssertEqual(resolve(width: 1024, height: 768, hCompact: false, vCompact: false), .tablet)
        XCTAssertEqual(resolve(width: 1366, height: 1024, hCompact: false, vCompact: false), .tablet)
        // Regular size classes without size information stay tablet.
        XCTAssertEqual(resolve(hCompact: false, vCompact: false), .tablet)
    }

    func test_narrowRegularWindow_resolvesCompactTablet() {
        // Stage Manager / split-view regular-width windows below the
        // tablet breakpoint.
        XCTAssertEqual(resolve(width: 678, height: 768, hCompact: false, vCompact: false), .compactTablet)
        XCTAssertEqual(resolve(width: 699, height: 800, hCompact: false, vCompact: false), .compactTablet)
        XCTAssertEqual(resolve(width: 700, height: 800, hCompact: false, vCompact: false), .tablet)
    }

    func test_unknownSizeClasses_useWidthBreakpoints() {
        XCTAssertEqual(resolve(width: 400, height: 800), .compactPhone)
        XCTAssertEqual(resolve(width: 600, height: 800), .compactTablet)
        XCTAssertEqual(resolve(width: 900, height: 800), .tablet)
        // Nothing known at all: prefer the regular-capable class.
        XCTAssertEqual(resolve(), .tablet)
    }

    func test_resolver_breakpointsAreOrdered() {
        XCTAssertLessThan(
            ViewerLayoutClassResolver.phoneWidthBreakpoint,
            ViewerLayoutClassResolver.tabletWidthBreakpoint
        )
    }
}
