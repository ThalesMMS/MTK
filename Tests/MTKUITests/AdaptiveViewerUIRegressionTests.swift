//
//  AdaptiveViewerUIRegressionTests.swift
//  MTKUITests
//
//  Regression surface for iPadOS/macOS viewer UI adaptation (issue #1215):
//  the preview fixture matrix is the tested matrix, so tablet/desktop
//  adaptation cannot silently collapse back to compact-vs-generic behavior.
//  All tests are GPU-free.
//

import CoreGraphics
import XCTest
@testable import MTKUI

final class AdaptiveViewerUIRegressionTests: XCTestCase {

    func test_previewMatrix_resolvesTheExpectedLayoutClasses() {
        for fixture in ViewerPreviewWindows.matrix {
            XCTAssertEqual(
                ViewerLayoutClassResolver.resolve(fixture.context),
                fixture.expected,
                "fixture \(fixture.name) resolved unexpectedly"
            )
        }
    }

    func test_adaptationDoesNotCollapseToTwoClasses() {
        // The historical failure mode is compact-phone vs generic-regular.
        // The representative windows must keep resolving to at least three
        // distinct classes, including a large-screen one.
        let resolved = Set(ViewerPreviewWindows.matrix.map {
            ViewerLayoutClassResolver.resolve($0.context)
        })
        XCTAssertGreaterThanOrEqual(resolved.count, 3, "adaptive layout collapsed: \(resolved)")
        XCTAssertTrue(resolved.contains(.tablet) || resolved.contains(.desktop))
    }

    func test_chromePresentation_differsBetweenTabletAndNarrowWindows() {
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .tablet), .sideDock)
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .compactTablet), .bottomDock)
        XCTAssertNotEqual(
            TabletChromeDockPresentation.presentation(for: .tablet),
            TabletChromeDockPresentation.presentation(for: .compactTablet),
            "tablet and narrow windows must present the dock differently"
        )
    }

    func test_largeScreenLayoutRecommendations_trackTheFixtureClasses() {
        for fixture in ViewerPreviewWindows.matrix {
            let layouts = MPRScreenLayout.recommendedLayouts(for: fixture.expected)
            XCTAssertFalse(layouts.isEmpty)
            switch fixture.expected {
            case .tablet, .desktop:
                XCTAssertTrue(
                    layouts.contains(.primaryLeft),
                    "\(fixture.name) should surface large-screen MPR presets"
                )
            case .compactPhone, .compactTablet:
                XCTAssertEqual(layouts, MPRScreenLayout.compactLayouts)
            }
        }
    }

    func test_mprGrid_fillsFixtureWindows_withoutOverlap() {
        // Pane-sizing regression: every layout must tile each fixture
        // window — panes and dividers fully cover the area with no overlap.
        for fixture in ViewerPreviewWindows.matrix {
            for screenLayout in MPRScreenLayout.allCases {
                let layout = MPRViewportGridLayoutCalculator.layout(
                    for: screenLayout,
                    totalWidth: fixture.size.width,
                    totalHeight: fixture.size.height,
                    verticalSplit: 0.5,
                    horizontalSplit: 0.5,
                    fullscreenSlot: nil
                )
                let paneArea = [layout.rect1, layout.rect2, layout.rect3]
                    .map { $0.width * $0.height }
                    .reduce(0, +)
                let dividerArea = layout.dividers.map { divider -> CGFloat in
                    switch divider {
                    case let .horizontal(rect), let .vertical(rect):
                        return rect.width * rect.height
                    }
                }.reduce(0, +)
                let total = fixture.size.width * fixture.size.height

                XCTAssertEqual(
                    paneArea + dividerArea, total,
                    accuracy: total * 0.02,
                    "\(screenLayout) does not tile \(fixture.name)"
                )
            }
        }
    }
}
